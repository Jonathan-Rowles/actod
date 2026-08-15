package actod

import "base:builtin"
import "base:intrinsics"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

ACTOR_REGISTRY_SIZE :: 1024
REGISTRY_MAX_CAPACITY :: 1 << 20
MAX_NODES :: 256
NAME_BUCKET_COUNT :: 2 * REGISTRY_MAX_CAPACITY
NAME_BUCKET_MASK :: u64(NAME_BUCKET_COUNT - 1)
GOSSIP_AHEAD_LIMIT :: 64
NAME_BUCKET_TOMBSTONE :: 0xFFFFFFFF

@(private)
PID_Map :: struct($T: typeid, $HT: typeid) {
	items:        []PID_Entry(T, HT),
	capacity:     u32,
	num_items:    u32,
	next_unused:  u64,
	unused_items: []u32,
	num_unused:   u32,
	name_buckets: []u32,
	items_backing:  []byte,
	unused_backing: []byte,
	name_buckets_backing: []byte,
	mutex:        sync.Mutex,
}

@(private)
PID_Entry :: struct($T: typeid, $HT: typeid) #align (CACHE_LINE_SIZE) {
	sequence:    u32,
	home_worker: i32,
	pid:         HT,
	name_hash:   u64,
	remote_name: string,
	data:        T,
	_pad:        [CACHE_LINE_SIZE - size_of(u32) - size_of(
		i32,
	) - size_of(HT) - size_of(u64) - size_of(string) - size_of(T)]byte,
}

@(private)
pid_map_init :: proc(m: ^PID_Map($T, $HT), initial_capacity: int) {
	capacity := next_power_of_two(initial_capacity)
	assert(capacity <= REGISTRY_MAX_CAPACITY, "registry capacity exceeds REGISTRY_MAX_CAPACITY")

	items_backing, items_err := vmem.reserve(REGISTRY_MAX_CAPACITY * size_of(PID_Entry(T, HT)))
	assert(items_err == nil, "Failed to reserve address space for PID_Map items")
	unused_backing, unused_err := vmem.reserve(REGISTRY_MAX_CAPACITY * size_of(u32))
	assert(unused_err == nil, "Failed to reserve address space for the PID_Map freelist")
	buckets_backing, buckets_err := vmem.reserve(NAME_BUCKET_COUNT * size_of(u32))
	assert(buckets_err == nil, "Failed to reserve address space for the PID_Map name buckets")

	items_commit := vmem.commit(raw_data(items_backing), uint(capacity) * size_of(PID_Entry(T, HT)))
	assert(items_commit == nil, "Failed to commit PID_Map items")
	unused_commit := vmem.commit(raw_data(unused_backing), uint(capacity) * size_of(u32))
	assert(unused_commit == nil, "Failed to commit the PID_Map freelist")
	buckets_commit := vmem.commit(raw_data(buckets_backing), NAME_BUCKET_COUNT * size_of(u32))
	assert(buckets_commit == nil, "Failed to commit the PID_Map name buckets")

	m.items_backing = items_backing
	m.unused_backing = unused_backing
	m.name_buckets_backing = buckets_backing
	m.items = mem.slice_data_cast([]PID_Entry(T, HT), items_backing)
	m.unused_items = mem.slice_data_cast([]u32, unused_backing)
	m.name_buckets = mem.slice_data_cast([]u32, buckets_backing)
	m.capacity = u32(capacity)
	m.num_items = 0
	m.next_unused = 0
	m.num_unused = 0
}

@(private)
try_grow_registry :: proc(m: ^PID_Map($T, $HT), loc := #caller_location) -> bool {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)

	if m.num_items < m.capacity do return true

	old_capacity := m.capacity
	if old_capacity >= REGISTRY_MAX_CAPACITY {
		log.errorf(
			"actor registry is at its maximum capacity (%d)",
			old_capacity,
			location = loc,
		)
		return false
	}
	new_capacity := old_capacity * 2

	log.infof("Growing actor registry: %d → %d", old_capacity, new_capacity)

	items_err := vmem.commit(
		raw_data(m.items_backing),
		uint(new_capacity) * size_of(PID_Entry(T, HT)),
	)
	unused_err := vmem.commit(raw_data(m.unused_backing), uint(new_capacity) * size_of(u32))
	if items_err != nil || unused_err != nil {
		log.errorf(
			"actor registry growth could not commit memory: %v / %v",
			items_err,
			unused_err,
			location = loc,
		)
		return false
	}

	sync.atomic_store(&m.capacity, new_capacity)

	log.infof("Registry growth complete: new capacity=%d", new_capacity)
	return true
}

@(private)
freelist_pop :: proc(m: ^PID_Map($T, $HT)) -> (u32, bool) {
	for {
		head := sync.atomic_load_explicit(&m.next_unused, .Acquire)
		idx := u32(head)
		if idx == 0 do return 0, false
		next := sync.atomic_load_explicit(&m.unused_items[idx], .Acquire)
		new_head := ((head >> 32) + 1) << 32 | u64(next)
		if _, ok := sync.atomic_compare_exchange_strong_explicit(
			&m.next_unused,
			head,
			new_head,
			.Acq_Rel,
			.Acquire,
		); ok {
			sync.atomic_sub_explicit(&m.num_unused, 1, .Acq_Rel)
			return idx, true
		}
	}
}

@(private)
freelist_push :: proc(m: ^PID_Map($T, $HT), idx: u32) {
	for {
		head := sync.atomic_load_explicit(&m.next_unused, .Acquire)
		sync.atomic_store_explicit(&m.unused_items[idx], u32(head), .Release)
		new_head := ((head >> 32) + 1) << 32 | u64(idx)
		if _, ok := sync.atomic_compare_exchange_strong_explicit(
			&m.next_unused,
			head,
			new_head,
			.Acq_Rel,
			.Acquire,
		); ok {
			sync.atomic_add_explicit(&m.num_unused, 1, .Acq_Rel)
			return
		}
	}
}

@(private)
acquire_entry_slot :: proc(m: ^PID_Map($T, $HT), loc := #caller_location) -> (u32, bool) {
	for {
		current_items := sync.atomic_load_explicit(&m.num_items, .Acquire)

		if current_items == 0 {
			_, ok := sync.atomic_compare_exchange_strong_explicit(
				&m.num_items,
				0,
				1,
				.Acq_Rel,
				.Acquire,
			)
			if ok {
				sync.atomic_store_explicit(&m.items[0].sequence, 0, .Release)
				m.items[0].data = T{}
				sync.atomic_store_explicit(&m.items[0].pid, HT{}, .Release)
				current_items = 1
			} else {
				current_items = sync.atomic_load_explicit(&m.num_items, .Acquire)
			}
		}

		if current_items >= m.capacity {
			if !try_grow_registry(m, loc) do return 0, false
			continue
		}

		_, ok := sync.atomic_compare_exchange_strong_explicit(
			&m.num_items,
			current_items,
			current_items + 1,
			.Acq_Rel,
			.Acquire,
		)
		if ok do return current_items, true
	}
}

@(private)
add :: proc(
	m: ^PID_Map($T, $HT),
	data: T,
	name: string = "",
	actor_type: Actor_Type = 0,
	loc := #caller_location,
) -> (
	HT,
	bool,
) #optional_ok {
	name_hash := fnv1a_hash(name)

	if idx, ok := freelist_pop(m); ok {
		entry := &m.items[idx]

		if entry.remote_name != "" {
			delete(entry.remote_name, actor_system_allocator)
			entry.remote_name = ""
		}

		old_seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		gen := ((old_seq >> 1) + 1) & 0xFFFF
		new_seq := (gen << 1) | 1

		new_handle := Handle {
			idx        = idx,
			gen        = u16(gen),
			actor_type = actor_type,
		}
		new_pid := pack_pid(new_handle)

		entry.data = data
		entry.name_hash = name_hash
		sync.atomic_store_explicit(&entry.pid, new_pid, .Release)

		sync.atomic_store_explicit(&entry.sequence, new_seq, .Release)

		register_name_bucket(m, name_hash, idx)

		return new_pid, true
	}

	idx, claimed := acquire_entry_slot(m, loc)
	if !claimed do return {}, false

	entry := &m.items[idx]
	new_handle := Handle {
		idx        = idx,
		gen        = 1,
		actor_type = actor_type,
	}
	new_pid := pack_pid(new_handle)
	new_seq := u32(1 << 1) | 1

	entry.data = data
	entry.name_hash = name_hash
	sync.atomic_store_explicit(&entry.pid, new_pid, .Release)
	sync.atomic_store_explicit(&entry.sequence, new_seq, .Release)

	register_name_bucket(m, name_hash, idx)

	return new_pid, true
}

@(private)
register_name_bucket :: proc(m: ^PID_Map($T, $HT), name_hash: u64, idx: u32) {
	bucket := name_hash & NAME_BUCKET_MASK
	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) & NAME_BUCKET_MASK
		stored := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)

		if stored == 0 || stored == NAME_BUCKET_TOMBSTONE {
			_, ok := sync.atomic_compare_exchange_strong_explicit(
				&m.name_buckets[probe],
				stored,
				idx,
				.Acq_Rel,
				.Acquire,
			)
			if ok do return
		}
	}
	log.errorf(
		"name bucket table exhausted (%d slots), entry %d is not findable by name",
		NAME_BUCKET_COUNT,
		idx,
	)
}

@(private)
deregister_name_bucket :: proc(m: ^PID_Map($T, $HT), name_hash: u64, idx: u32) {
	bucket := name_hash & NAME_BUCKET_MASK
	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) & NAME_BUCKET_MASK
		stored_idx := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)

		if stored_idx == 0 do break

		if stored_idx == NAME_BUCKET_TOMBSTONE do continue

		if stored_idx == idx {
			sync.atomic_compare_exchange_strong_explicit(
				&m.name_buckets[probe],
				idx,
				NAME_BUCKET_TOMBSTONE,
				.Acq_Rel,
				.Acquire,
			)
			break
		}
	}
}

get_by_name :: proc(m: ^PID_Map($T, $HT), name: string) -> (HT, bool) {
	name_hash := fnv1a_hash(name)
	bucket := name_hash & NAME_BUCKET_MASK

	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) & NAME_BUCKET_MASK
		idx := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)

		if idx == 0 {
			return {}, false
		}

		if idx == NAME_BUCKET_TOMBSTONE do continue

		entry := &m.items[idx]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) != 0 && entry.name_hash == name_hash {
			return sync.atomic_load_explicit(&entry.pid, .Acquire), true
		}
	}

	return {}, false
}

@(private)
find_by_name_hash :: proc(m: ^PID_Map($T, $HT), name_hash: u64) -> (u32, bool) {
	bucket := name_hash & NAME_BUCKET_MASK
	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) & NAME_BUCKET_MASK
		idx := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)
		if idx == 0 do return 0, false
		if idx == NAME_BUCKET_TOMBSTONE do continue
		entry := &m.items[idx]
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) != 0 && entry.name_hash == name_hash do return idx, true
	}
	return 0, false
}

add_remote :: proc(m: ^PID_Map($T, $HT), remote_pid: HT, name: string) -> (bool, bool) {
	name_hash := fnv1a_hash(name)

	if existing_idx, found := find_by_name_hash(m, name_hash); found {
		entry := &m.items[existing_idx]
		stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if stored_pid != remote_pid {
			sync.atomic_compare_exchange_strong_explicit(
				&entry.pid,
				stored_pid,
				remote_pid,
				.Acq_Rel,
				.Acquire,
			)
		}
		return true, false
	}

	idx: u32
	got_slot := false

	if reused_idx, ok := freelist_pop(m); ok {
		idx = reused_idx
		got_slot = true
	}

	if !got_slot {
		claimed, ok := acquire_entry_slot(m)
		if !ok do return false, false
		idx = claimed
	}

	entry := &m.items[idx]

	if entry.remote_name != "" do delete(entry.remote_name, actor_system_allocator)

	entry.name_hash = name_hash
	entry.data = T{}
	entry.remote_name = strings.clone(name, actor_system_allocator)

	sync.atomic_store_explicit(&entry.pid, remote_pid, .Release)
	sync.atomic_store_explicit(&entry.sequence, 1, .Release)

	register_name_bucket(m, name_hash, idx)

	if canonical_idx, found := find_by_name_hash(m, name_hash); found && canonical_idx != idx {
		deregister_name_bucket(m, name_hash, idx)
		sync.atomic_store_explicit(&entry.sequence, 0, .Release)

		freelist_push(m, idx)

		canonical_entry := &m.items[canonical_idx]
		stored_pid := sync.atomic_load_explicit(&canonical_entry.pid, .Acquire)
		if stored_pid != remote_pid {
			sync.atomic_compare_exchange_strong_explicit(
				&canonical_entry.pid,
				stored_pid,
				remote_pid,
				.Acq_Rel,
				.Acquire,
			)
		}

		return true, false
	}

	return true, true
}

@(private)
remove_entry_at :: proc(m: ^PID_Map($T, $HT), idx: u32) -> bool {
	entry := &m.items[idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
	if (seq & 1) == 0 do return false

	new_seq := seq & ~u32(1)
	_, ok := sync.atomic_compare_exchange_strong_explicit(
		&entry.sequence,
		seq,
		new_seq,
		.Acq_Rel,
		.Acquire,
	)
	if !ok do return false

	deregister_name_bucket(m, entry.name_hash, idx)

	freelist_push(m, idx)
	return true
}

remove_remote :: proc(m: ^PID_Map($T, $HT), remote_pid: HT, name: string) -> bool {
	if idx, found := find_by_name_hash(m, fnv1a_hash(name)); found {
		entry := &m.items[idx]
		if sync.atomic_load_explicit(&entry.pid, .Acquire) == remote_pid {
			return remove_entry_at(m, idx)
		}
	}

	num_items := sync.atomic_load_explicit(&m.num_items, .Acquire)
	for idx in 1 ..< num_items {
		entry := &m.items[idx]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 do continue

		stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if stored_pid != remote_pid do continue

		if remove_entry_at(m, idx) do return true
	}

	return false
}

handle_node_disconnect :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id == NODE.node_id do return

	num_items := sync.atomic_load_explicit(&NODE.actor_registry.num_items, .Acquire)

	for i in 1 ..< num_items {
		entry := &NODE.actor_registry.items[i]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 do continue

		pid := sync.atomic_load_explicit(&entry.pid, .Acquire)

		if get_node_id(pid) == node_id do _ = remove_entry_at(&NODE.actor_registry, i)
	}
}

pid_map_rename :: proc(m: ^PID_Map($T, $HT), pid: HT, new_name: string) -> bool {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Acquire) {
		return false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
	if (seq & 1) == 0 do return false

	old_hash := entry.name_hash
	new_hash := fnv1a_hash(new_name)

	deregister_name_bucket(m, old_hash, handle.idx)

	entry.name_hash = new_hash

	register_name_bucket(m, new_hash, handle.idx)

	return true
}

@(private)
validate_entry :: #force_inline proc(
	m: ^PID_Map($T, $HT),
	pid: HT,
	$ORDER: sync.Atomic_Memory_Order,
) -> (
	^PID_Entry(T, HT),
	bool,
) {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, ORDER) {
		return nil, false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, ORDER)
	if (seq & 1) == 0 do return nil, false

	gen := u16(seq >> 1)
	if gen != handle.gen do return nil, false

	stored_pid := sync.atomic_load_explicit(&entry.pid, ORDER)
	if stored_pid != pid do return nil, false

	return entry, true
}

get :: proc(m: ^PID_Map($T, $HT), pid: HT) -> (T, bool) #optional_ok {
	entry, ok := validate_entry(m, pid, .Acquire)
	if !ok do return nil, false
	return entry.data, true
}

@(private)
get_relaxed :: #force_inline proc(m: ^PID_Map($T, $HT), pid: HT) -> (T, bool) #optional_ok {
	entry, ok := validate_entry(m, pid, .Relaxed)
	if !ok do return nil, false
	return entry.data, true
}

@(private)
get_relaxed_loc :: #force_inline proc(m: ^PID_Map($T, $HT), pid: HT) -> (T, i32, bool) {
	entry, ok := validate_entry(m, pid, .Relaxed)
	if !ok do return nil, 0, false
	home_worker := sync.atomic_load_explicit(&entry.home_worker, .Relaxed)
	return entry.data, home_worker, true
}

@(private)
set_entry_home_worker :: proc(m: ^PID_Map($T, $HT), pid: HT, worker_idx: int) {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Relaxed) do return

	entry := &m.items[handle.idx]
	if sync.atomic_load_explicit(&entry.pid, .Relaxed) != pid do return

	sync.atomic_store_explicit(&entry.home_worker, i32(worker_idx) + 1, .Release)
}

@(private)
remove :: proc(m: ^PID_Map($T, $HT), pid: HT) {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Acquire) do return

	entry := &m.items[handle.idx]

	for {
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		if (seq & 1) == 0 do return

		gen := u16(seq >> 1)
		if gen != handle.gen do return

		stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if stored_pid != pid do return

		new_seq := seq & ~u32(1)

		_, ok := sync.atomic_compare_exchange_strong_explicit(
			&entry.sequence,
			seq,
			new_seq,
			.Acq_Rel,
			.Acquire,
		)

		if ok {
			deregister_name_bucket(m, entry.name_hash, handle.idx)

			entry.data = T{}

			freelist_push(m, handle.idx)
			return
		}
	}
}

num_used :: proc(m: ^PID_Map($T, $HT)) -> int {
	total := sync.atomic_load_explicit(&m.num_items, .Acquire)
	unused := sync.atomic_load_explicit(&m.num_unused, .Acquire)

	result := int(total - unused)

	if total > 0 do result -= 1

	if result < 0 do result = 0

	return result
}

valid :: proc(m: ^PID_Map($T, $HT), pid: HT) -> bool {
	_, ok := validate_entry(m, pid, .Acquire)
	return ok
}

cap :: proc(m: ^PID_Map($T, $HT)) -> int {
	return int(sync.atomic_load(&m.capacity))
}

PID_Map_Iterator :: struct($T: typeid, $HT: typeid) {
	m:                  ^PID_Map(T, HT),
	index:              u32,
	snapshot_num_items: u32,
}

make_iter :: proc(m: ^PID_Map($T, $HT)) -> PID_Map_Iterator(T, HT) {
	return {
		m = m,
		index = 1,
		snapshot_num_items = sync.atomic_load_explicit(&m.num_items, .Acquire),
	}
}

iter :: proc(it: ^PID_Map_Iterator($T, $HT)) -> (val: T, pid: HT, cond: bool) {
	for it.index < it.snapshot_num_items {
		entry := &it.m.items[it.index]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) != 0 {
			stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
			it.index += 1
			return entry.data, stored_pid, true
		}

		it.index += 1
	}

	return {}, {}, false
}

clear :: proc(m: ^PID_Map($T, $HT)) {
	num_items := sync.atomic_load_explicit(&m.num_items, .Acquire)
	for i in 0 ..< num_items {
		entry := &m.items[i]
		if entry.remote_name != "" {
			delete(entry.remote_name, actor_system_allocator)
			entry.remote_name = ""
		}
	}

	sync.atomic_store_explicit(&m.num_items, 0, .Release)
	sync.atomic_store_explicit(&m.next_unused, 0, .Release)
	sync.atomic_store_explicit(&m.num_unused, 0, .Release)

	committed := sync.atomic_load_explicit(&m.capacity, .Acquire)
	for i in 0 ..< committed {
		sync.atomic_store_explicit(&m.items[i].sequence, 0, .Release)
		m.items[i].data = T{}
		m.items[i].name_hash = 0
		sync.atomic_store_explicit(&m.items[i].pid, HT{}, .Release)
	}

	if committed > 0 do intrinsics.mem_zero(raw_data(m.unused_items), int(committed) * size_of(u32))
	if m.name_buckets != nil {
		intrinsics.mem_zero(raw_data(m.name_buckets), len(m.name_buckets) * size_of(u32))
	}
}

destroy :: proc(m: ^PID_Map($T, $HT)) {
	clear(m)
	if m.items_backing != nil do vmem.release(raw_data(m.items_backing), uint(len(m.items_backing)))
	if m.unused_backing != nil {
		vmem.release(raw_data(m.unused_backing), uint(len(m.unused_backing)))
	}
	if m.name_buckets_backing != nil {
		vmem.release(raw_data(m.name_buckets_backing), uint(len(m.name_buckets_backing)))
	}
	m.items_backing = nil
	m.unused_backing = nil
	m.name_buckets_backing = nil
	m.items = nil
	m.unused_items = nil
	m.name_buckets = nil
}

get_valid_actor :: proc(
	pid: PID,
	expected_states: Actor_State_Set = {},
	system_operation := false,
) -> (
	actor: ^Actor(int),
	ptr: rawptr,
	valid: bool,
) {
	if pid == 0 do return nil, nil, false

	actor_ptr, active := get(&NODE.actor_registry, pid)
	if !active || actor_ptr == nil do return nil, nil, false

	actor_ref, ok := get_actor_from_pointer(actor_ptr, system_operation)
	if !ok do return nil, nil, false

	if expected_states == {} do return actor_ref, actor_ptr, true

	current_state := sync.atomic_load(&actor_ref.state)
	if current_state in expected_states do return actor_ref, actor_ptr, true

	return nil, nil, false
}

collect_actors :: proc(
	expected_states: Actor_State_Set = {},
	allocator := context.allocator,
) -> [dynamic]struct {
		pid: PID,
		ptr: rawptr,
	} {
	actors := make([dynamic]struct {
			pid: PID,
			ptr: rawptr,
		}, allocator)

	it := make_iter(&NODE.actor_registry)
	for {
		_, pid, ok := iter(&it)
		if !ok do break
		if pid == 0 || pid == NODE.pid do continue

		_, ptr, valid := get_valid_actor(pid, expected_states)
		if valid {
			append(&actors, struct {
				pid: PID,
				ptr: rawptr,
			}{pid, ptr})
		}
	}

	return actors
}

@(require_results)
register_node :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
	connect: bool = false,
	loc := #caller_location,
) -> (
	Node_ID,
	bool,
) {
	context.logger = diagnostic_logger(context.logger)

	node_id, newly_registered := register_node_entry(name, address, transport, .Registered, loc)

	if newly_registered do announce_node_to_peers(name, address, node_id)

	if node_id != 0 {
		ring := get_connection_ring(node_id)
		if ring != nil && sync.atomic_load(&ring.state) == .Ready {
			body := [1]u8{CTRL_MSG_LIFECYCLE_STREAM}
			_ = ring_append_ctrl_retry(ring, body[:])
		}
	}

	if connect && node_id != 0 {
		if ensure_ring_for_node(node_id) == nil {
			log.warnf(
				"register_node('%s'): a connection to %v could not be started yet, it will be retried automatically",
				name,
				address,
				location = loc,
			)
		}
	}

	return node_id, newly_registered
}

register_discovered_node :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
	loc := #caller_location,
) -> (
	Node_ID,
	bool,
) {
	node_id, newly_registered := register_node_entry(name, address, transport, .Discovered, loc)
	if newly_registered do announce_node_to_peers(name, address, node_id)
	return node_id, newly_registered
}

@(private)
register_node_entry :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
	origin: Node_Origin,
	loc := #caller_location,
) -> (
	Node_ID,
	bool,
) {
	sync.rw_mutex_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_unlock(&NODE.node_registry_lock)

	if NODE.node_name_to_id == nil {
		NODE.node_name_to_id = make(map[string]Node_ID, get_system_allocator())
	}

	if existing_id, exists := NODE.node_name_to_id[name]; exists {
		log.warnf(
			"register_node('%s'): already registered as node %d, updating its address to %v and keeping the existing id",
			name,
			existing_id,
			address,
			location = loc,
		)
		NODE.node_registry[existing_id].address = address
		NODE.node_registry[existing_id].transport = transport
		if origin == .Registered do NODE.node_registry[existing_id].origin = .Registered
		return existing_id, false
	}

	node_id := sync.atomic_load(&NODE.next_node_id)
	if node_id >= MAX_NODES {
		log.errorf(
			"register_node('%s') failed: this node already knows the maximum of %d peers",
			name,
			MAX_NODES,
			location = loc,
		)
		return 0, false
	}
	sync.atomic_store(&NODE.next_node_id, node_id + 1)

	cloned_name := strings.clone(name, get_system_allocator())

	NODE.node_registry[node_id] = Node_Info {
		node_name = cloned_name,
		address   = address,
		transport = transport,
		origin    = origin,
	}

	NODE.node_name_to_id[cloned_name] = node_id
	return node_id, true
}

@(require_results)
get_node_info :: proc(node_id: Node_ID) -> (Node_Info, bool) {
	if node_id == 0 || node_id >= MAX_NODES {
		return {}, false
	}

	info := NODE.node_registry[node_id]
	if info.node_name == "" {
		return {}, false
	}

	return info, true
}

set_node_incarnation :: proc(node_id: Node_ID, incarnation: u64) {
	if node_id == 0 || node_id >= MAX_NODES do return
	sync.rw_mutex_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_unlock(&NODE.node_registry_lock)
	if NODE.node_registry[node_id].node_name != "" {
		NODE.node_registry[node_id].incarnation = incarnation
	}
}

gossip_seq_covered :: proc(node_id: Node_ID, seq: u64) -> bool {
	if node_id == 0 || node_id >= MAX_NODES || seq == 0 do return false
	sync.rw_mutex_shared_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_shared_unlock(&NODE.node_registry_lock)
	window := &NODE.node_registry[node_id].gossip
	if seq < window.next_seq do return true
	for applied in window.ahead {
		if applied == seq do return true
	}
	return false
}

gossip_seq_record :: proc(node_id: Node_ID, seq: u64) {
	if node_id == 0 || node_id >= MAX_NODES || seq == 0 do return
	sync.rw_mutex_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_unlock(&NODE.node_registry_lock)
	window := &NODE.node_registry[node_id].gossip
	if window.next_seq == 0 do window.next_seq = 1
	if seq < window.next_seq do return
	if seq == window.next_seq {
		window.next_seq += 1
	} else {
		for applied in window.ahead {
			if applied == seq do return
		}
		if window.ahead == nil do window.ahead = make([dynamic]u64, get_system_allocator())
		append(&window.ahead, seq)
	}
	drain_gossip_window(window)
	for len(window.ahead) > GOSSIP_AHEAD_LIMIT {
		lowest := window.ahead[0]
		for applied in window.ahead {
			if applied < lowest do lowest = applied
		}
		log.warnf(
			"gossip window for node %d skipped sequences %d to %d after dropped frames",
			node_id,
			window.next_seq,
			lowest - 1,
		)
		window.next_seq = lowest
		drain_gossip_window(window)
	}
}

@(private)
drain_gossip_window :: proc(window: ^Gossip_Window) {
	for {
		drained := false
		for applied, idx in window.ahead {
			if applied == window.next_seq {
				unordered_remove(&window.ahead, idx)
				window.next_seq += 1
				drained = true
				break
			}
		}
		if !drained do break
	}
}

gossip_seq_reset :: proc(node_id: Node_ID, frontier: u64) {
	if node_id == 0 || node_id >= MAX_NODES do return
	sync.rw_mutex_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_unlock(&NODE.node_registry_lock)
	window := &NODE.node_registry[node_id].gossip
	window.next_seq = frontier + 1
	builtin.clear(&window.ahead)
}

@(require_results)
get_node_by_name :: proc(name: string) -> (Node_ID, bool) {
	sync.rw_mutex_shared_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_shared_unlock(&NODE.node_registry_lock)
	if id, exists := NODE.node_name_to_id[name]; exists do return id, true
	return 0, false
}

unregister_node :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id >= MAX_NODES do return

	conn_pid := PID(
		sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[node_id], .Acquire),
	)

	if conn_pid != 0 {
		_ = send_message(conn_pid, Terminate{})

		runtime_sleep(10 * time.Millisecond)
	}
}
