package actod

import "base:intrinsics"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

ACTOR_REGISTRY_SIZE :: 1024
MAX_NODES :: 256
NAME_BUCKET_COUNT :: 4096
NAME_BUCKET_TOMBSTONE :: 0xFFFFFFFF

global_registry: PID_Map(rawptr, PID)

@(private)
PID_Map :: struct($T: typeid, $HT: typeid) {
	items:        []PID_Entry(T, HT),
	capacity:     u32,
	num_items:    u32,
	next_unused:  u64,
	unused_items: []u32,
	num_unused:   u32,
	name_buckets: [NAME_BUCKET_COUNT]u32,
	allocator:    mem.Allocator,
	arena:        vmem.Arena,
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
init_pid_map :: proc(m: ^PID_Map($T, $HT), initial_capacity: int, allocator := context.allocator) {
	capacity := next_power_of_two(initial_capacity)

	arena_err := vmem.arena_init_static(&m.arena)
	assert(arena_err == nil, "Failed to initialize virtual memory arena for PID_Map")
	m.allocator = vmem.arena_allocator(&m.arena)

	m.items = make([]PID_Entry(T, HT), capacity, m.allocator)
	m.unused_items = make([]u32, capacity, m.allocator)
	m.capacity = u32(capacity)
	m.num_items = 0
	m.next_unused = 0
	m.num_unused = 0

	for i in 0 ..< NAME_BUCKET_COUNT {
		m.name_buckets[i] = 0
	}
}

@(private)
try_grow_registry :: proc(m: ^PID_Map($T, $HT), loc := #caller_location) -> bool {
	if !SYSTEM_CONFIG.allow_registry_growth {
		log.errorf(
			"actor registry is full (capacity=%d) and allow_registry_growth is disabled. Raise actor_registry_size in make_node_config() or enable growth",
			m.capacity,
			location = loc,
		)
		return false
	}

	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)

	if m.num_items < m.capacity {
		return true
	}

	old_capacity := m.capacity
	new_capacity := m.capacity * 2

	log.infof("Growing actor registry: %d → %d", old_capacity, new_capacity)

	new_items := make([]PID_Entry(T, HT), new_capacity, m.allocator)
	new_unused := make([]u32, new_capacity, m.allocator)

	copy(new_items, m.items)
	copy(new_unused, m.unused_items)

	m.items = new_items
	m.unused_items = new_unused
	sync.atomic_store(&m.capacity, new_capacity)

	log.infof("Registry growth complete: new capacity=%d", new_capacity)
	return true
}

@(private)
freelist_pop :: proc(m: ^PID_Map($T, $HT)) -> (u32, bool) {
	for {
		head := sync.atomic_load_explicit(&m.next_unused, .Acquire)
		idx := u32(head)
		if idx == 0 {
			return 0, false
		}
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
			if !try_grow_registry(m, loc) {
				return {}, false
			}
			continue
		}

		_, ok := sync.atomic_compare_exchange_strong_explicit(
			&m.num_items,
			current_items,
			current_items + 1,
			.Acq_Rel,
			.Acquire,
		)
		if ok {
			entry := &m.items[current_items]
			new_handle := Handle {
				idx        = current_items,
				gen        = 1,
				actor_type = actor_type,
			}
			new_pid := pack_pid(new_handle)
			new_seq := u32(1 << 1) | 1

			entry.data = data
			entry.name_hash = name_hash
			sync.atomic_store_explicit(&entry.pid, new_pid, .Release)
			sync.atomic_store_explicit(&entry.sequence, new_seq, .Release)

			register_name_bucket(m, name_hash, current_items)

			return new_pid, true
		}
	}
}

@(private)
register_name_bucket :: proc(m: ^PID_Map($T, $HT), name_hash: u64, idx: u32) {
	bucket := name_hash % NAME_BUCKET_COUNT
	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) % NAME_BUCKET_COUNT
		stored := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)

		if stored == 0 || stored == NAME_BUCKET_TOMBSTONE {
			_, ok := sync.atomic_compare_exchange_strong_explicit(
				&m.name_buckets[probe],
				stored,
				idx,
				.Acq_Rel,
				.Acquire,
			)
			if ok {
				return
			}
		}
	}
}

@(private)
deregister_name_bucket :: proc(m: ^PID_Map($T, $HT), name_hash: u64, idx: u32) {
	bucket := name_hash % NAME_BUCKET_COUNT
	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) % NAME_BUCKET_COUNT
		stored_idx := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)

		if stored_idx == 0 {
			break
		}

		if stored_idx == NAME_BUCKET_TOMBSTONE {
			continue
		}

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
	bucket := name_hash % NAME_BUCKET_COUNT

	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) % NAME_BUCKET_COUNT
		idx := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)

		if idx == 0 {
			return {}, false
		}

		if idx == NAME_BUCKET_TOMBSTONE {
			continue
		}

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
	bucket := name_hash % NAME_BUCKET_COUNT
	for i in 0 ..< NAME_BUCKET_COUNT {
		probe := (bucket + u64(i)) % NAME_BUCKET_COUNT
		idx := sync.atomic_load_explicit(&m.name_buckets[probe], .Acquire)
		if idx == 0 {
			return 0, false
		}
		if idx == NAME_BUCKET_TOMBSTONE {
			continue
		}
		entry := &m.items[idx]
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) != 0 && entry.name_hash == name_hash {
			return idx, true
		}
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
				if !try_grow_registry(m) {
					return false, false
				}
				continue
			}

			_, ok := sync.atomic_compare_exchange_strong_explicit(
				&m.num_items,
				current_items,
				current_items + 1,
				.Acq_Rel,
				.Acquire,
			)
			if ok {
				idx = current_items
				got_slot = true
				break
			}
		}
	}

	entry := &m.items[idx]

	if entry.remote_name != "" {
		delete(entry.remote_name, actor_system_allocator)
	}

	entry.name_hash = name_hash
	entry.data = T{}
	entry.remote_name = strings.clone(name, actor_system_allocator)

	sync.atomic_store_explicit(&entry.pid, remote_pid, .Release)
	sync.atomic_store_explicit(&entry.sequence, 1, .Release)

	register_name_bucket(m, name_hash, idx)

	// if another thread inserted the same name concurrently,
	// the canonical entry is whichever find_by_name_hash resolves first.
	// If that's not us, roll back.
	if canonical_idx, found := find_by_name_hash(m, name_hash); found && canonical_idx != idx {
		deregister_name_bucket(m, name_hash, idx)
		sync.atomic_store_explicit(&entry.sequence, 0, .Release)

		freelist_push(m, idx)

		// Update canonical entry's PID if stale
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

remove_remote :: proc(m: ^PID_Map($T, $HT), remote_pid: HT) -> bool {
	num_items := sync.atomic_load_explicit(&m.num_items, .Acquire)
	for idx in 1 ..< num_items {
		entry := &m.items[idx]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 {
			continue
		}

		stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if stored_pid != remote_pid {
			continue
		}

		new_seq := seq & ~u32(1)
		_, ok := sync.atomic_compare_exchange_strong_explicit(
			&entry.sequence,
			seq,
			new_seq,
			.Acq_Rel,
			.Acquire,
		)
		if !ok {
			continue
		}

		deregister_name_bucket(m, entry.name_hash, idx)

		// remote_name is intentionally NOT freed here.
		// A concurrent reader may still hold a pointer to it.
		// The stale string is freed when the slot is reused in add_remote.
		freelist_push(m, idx)
		return true
	}

	return false
}

handle_node_disconnect :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id == current_node_id {
		return
	}

	num_items := sync.atomic_load_explicit(&global_registry.num_items, .Acquire)
	removed: int

	for i in 1 ..< num_items {
		entry := &global_registry.items[i]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 {
			continue
		}

		pid := sync.atomic_load_explicit(&entry.pid, .Acquire)

		if get_node_id(pid) == node_id {
			if remove_remote(&global_registry, pid) {
				removed += 1
			}
		}
	}
}

pid_map_rename :: proc(m: ^PID_Map($T, $HT), pid: HT, new_name: string) -> bool {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Acquire) {
		return false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
	if (seq & 1) == 0 {
		return false
	}

	old_hash := entry.name_hash
	new_hash := fnv1a_hash(new_name)

	deregister_name_bucket(m, old_hash, handle.idx)

	entry.name_hash = new_hash

	register_name_bucket(m, new_hash, handle.idx)

	return true
}

get :: proc(m: ^PID_Map($T, $HT), pid: HT) -> (T, bool) #optional_ok {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Acquire) {
		return nil, false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

	if (seq & 1) == 0 {
		return nil, false
	}

	gen := u16(seq >> 1)
	if gen != handle.gen {
		return nil, false
	}

	stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
	if stored_pid != pid {
		return nil, false
	}

	return entry.data, true
}

@(private)
get_relaxed :: #force_inline proc(m: ^PID_Map($T, $HT), pid: HT) -> (T, bool) #optional_ok {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Relaxed) {
		return nil, false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Relaxed)

	if (seq & 1) == 0 {
		return nil, false
	}

	gen := u16(seq >> 1)
	if gen != handle.gen {
		return nil, false
	}

	stored_pid := sync.atomic_load_explicit(&entry.pid, .Relaxed)
	if stored_pid != pid {
		return nil, false
	}

	return entry.data, true
}

@(private)
get_relaxed_loc :: #force_inline proc(m: ^PID_Map($T, $HT), pid: HT) -> (T, i32, bool) {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Relaxed) {
		return nil, 0, false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Relaxed)

	if (seq & 1) == 0 {
		return nil, 0, false
	}

	gen := u16(seq >> 1)
	if gen != handle.gen {
		return nil, 0, false
	}

	stored_pid := sync.atomic_load_explicit(&entry.pid, .Relaxed)
	if stored_pid != pid {
		return nil, 0, false
	}

	home_worker := sync.atomic_load_explicit(&entry.home_worker, .Relaxed)
	return entry.data, home_worker, true
}

@(private)
set_entry_home_worker :: proc(m: ^PID_Map($T, $HT), pid: HT, worker_idx: int) {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Relaxed) {
		return
	}

	entry := &m.items[handle.idx]
	if sync.atomic_load_explicit(&entry.pid, .Relaxed) != pid {
		return
	}

	sync.atomic_store_explicit(&entry.home_worker, i32(worker_idx) + 1, .Release)
}

@(private)
remove :: proc(m: ^PID_Map($T, $HT), pid: HT) {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Acquire) {
		return
	}

	entry := &m.items[handle.idx]

	for {
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		if (seq & 1) == 0 {
			return
		}

		gen := u16(seq >> 1)
		if gen != handle.gen {
			return
		}

		stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if stored_pid != pid {
			return
		}

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

	if total > 0 {
		result -= 1
	}

	if result < 0 {
		result = 0
	}

	return result
}

valid :: proc(m: ^PID_Map($T, $HT), pid: HT) -> bool {
	handle, _ := unpack_pid(pid)

	if handle.idx <= 0 || handle.idx >= sync.atomic_load_explicit(&m.num_items, .Acquire) {
		return false
	}

	entry := &m.items[handle.idx]

	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

	if (seq & 1) == 0 {
		return false
	}

	gen := u16(seq >> 1)
	if gen != handle.gen {
		return false
	}

	stored_pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
	return stored_pid == pid
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

	for i in 0 ..< len(m.items) {
		sync.atomic_store_explicit(&m.items[i].sequence, 0, .Release)
		m.items[i].data = T{}
		m.items[i].name_hash = 0
		sync.atomic_store_explicit(&m.items[i].pid, HT{}, .Release)
	}

	// Zero out the unused_items slice content
	if len(m.unused_items) > 0 {
		intrinsics.mem_zero(raw_data(m.unused_items), len(m.unused_items) * size_of(u32))
	}
	intrinsics.mem_zero(&m.name_buckets, size_of(m.name_buckets))
}

destroy :: proc(m: ^PID_Map($T, $HT)) {
	clear(m)
	vmem.arena_destroy(&m.arena)
	m.items = nil
	m.unused_items = nil
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

	actor_ptr, active := get(&global_registry, pid)
	if !active || actor_ptr == nil do return nil, nil, false

	actor_ref, ok := get_actor_from_pointer(actor_ptr, system_operation)
	if !ok do return nil, nil, false

	if expected_states == {} do return actor_ref, actor_ptr, true

	current_state := sync.atomic_load(&actor_ref.state)
	if current_state in expected_states {
		return actor_ref, actor_ptr, true
	}

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

	it := make_iter(&global_registry)
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

	node_id, newly_registered := register_node_entry(name, address, transport, loc)

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

@(private)
register_node_entry :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
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
		return existing_id, false
	}

	for {
		node_id := sync.atomic_load(&global_next_node_id)
		if node_id >= MAX_NODES {
			log.errorf(
				"register_node('%s') failed: this node already knows the maximum of %d peers",
				name,
				MAX_NODES,
				location = loc,
			)
			return 0, false
		}
		if _, ok := sync.atomic_compare_exchange_strong(
			&global_next_node_id,
			node_id,
			node_id + 1,
		); ok {
			break
		}
	}
	node_id := sync.atomic_load(&global_next_node_id) - 1

	cloned_name := strings.clone(name, get_system_allocator())

	NODE.node_registry[node_id] = Node_Info {
		node_name = cloned_name,
		address   = address,
		transport = transport,
	}

	NODE.node_name_to_id[cloned_name] = node_id
	return node_id, true
}

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

// Rings are NODE-owned singletons: created once per node, adopted by
// connection actors, freed only in destroy_all_connection_rings at shutdown.
// Producers may therefore hold a ring pointer across connection churn.
get_or_create_node_ring :: proc(
	node_id: Node_ID,
	config: Connection_Ring_Config,
) -> ^Connection_Ring {
	if node_id == 0 || node_id >= MAX_NODES {
		return nil
	}

	ring := atomic_load_ring_ptr(&NODE.connection_rings[node_id])
	if ring != nil {
		return ring
	}

	new_pool := create_connection_pool(node_id, config, get_system_allocator())
	if new_pool == nil {
		return nil
	}

	new_ring := create_connection_ring(
		config,
		SYSTEM_CONFIG.network.enable_encryption,
		get_system_allocator(),
	)
	if new_ring == nil {
		free(new_pool, get_system_allocator())
		return nil
	}
	new_ring.node_id = node_id
	new_ring.pool = new_pool
	atomic_store_ring_ptr(&new_pool.rings[0], new_ring)
	sync.atomic_store_explicit(&new_pool.ring_count, u32(1), .Release)

	old, swapped := sync.atomic_compare_exchange_strong_explicit(
		cast(^u64)&NODE.connection_rings[node_id],
		u64(0),
		u64(uintptr(new_ring)),
		.Acq_Rel,
		.Acquire,
	)
	if !swapped {
		destroy_connection_ring(new_ring, get_system_allocator())
		free(new_pool, get_system_allocator())
		return cast(^Connection_Ring)rawptr(uintptr(old))
	}
	sync.atomic_store_explicit(
		cast(^u64)&NODE.connection_pools[node_id],
		u64(uintptr(new_pool)),
		.Release,
	)
	return new_ring
}

get_connection_pool :: #force_inline proc(node_id: Node_ID) -> ^Connection_Pool {
	if node_id == 0 || node_id >= MAX_NODES {
		return nil
	}
	return cast(^Connection_Pool)rawptr(
		uintptr(sync.atomic_load_explicit(cast(^u64)&NODE.connection_pools[node_id], .Acquire)),
	)
}

find_pool_owner_by_join_token :: proc(token: u64) -> PID {
	if token == 0 {
		return 0
	}
	for i in 2 ..< MAX_NODES {
		pool := get_connection_pool(Node_ID(i))
		if pool == nil {
			continue
		}
		if sync.atomic_load_explicit(&pool.join_token, .Acquire) == token {
			return PID(sync.atomic_load_explicit(&pool.conn_pid, .Acquire))
		}
	}
	return 0
}

register_connection_ring :: proc(node_id: Node_ID, ring: ^Connection_Ring) {
	if node_id == 0 || node_id >= MAX_NODES || ring == nil {
		return
	}
	atomic_store_ring_ptr(&NODE.connection_rings[node_id], ring)
}

get_connection_ring :: #force_inline proc(node_id: Node_ID) -> ^Connection_Ring {
	if node_id == 0 || node_id >= MAX_NODES {
		return nil
	}
	ring := atomic_load_ring_ptr(&NODE.connection_rings[node_id])
	if ring != nil {
		pool := ring.pool
		if pool != nil && sync.atomic_load_explicit(&pool.ring_count, .Acquire) > 1 {
			return get_pool_ring_ready(pool)
		}
	}
	return ring
}

@(private)
destroy_ring_if_quiesced :: proc(ring: ^Connection_Ring, node_id: int) -> bool {
	sync.atomic_store(&ring.io_stop, 1)
	released := false
	for _ in 0 ..< 1000 {
		if sync.atomic_load_explicit(&ring.io_owner, .Acquire) == 0 {
			released = true
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	if !released || ring.io_thread != nil {
		log.errorf("Leaking connection ring for node %d: IO thread never cleaned up", node_id)
		return false
	}
	destroy_connection_ring(ring, get_system_allocator())
	return true
}

destroy_all_connection_rings :: proc() {
	for i in 1 ..< MAX_NODES {
		ring := atomic_load_ring_ptr(&NODE.connection_rings[i])
		pool := get_connection_pool(Node_ID(i))
		if ring == nil && pool == nil {
			continue
		}

		conn_pid := PID(sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[i], .Acquire))
		if conn_pid != 0 {
			log.errorf("Leaking connection ring for node %d: connection actor still alive", i)
			continue
		}

		leaked := false
		if pool != nil {
			count := sync.atomic_load(&pool.ring_count)
			for r: u32 = 1; r < count; r += 1 {
				pr := atomic_load_ring_ptr(&pool.rings[r])
				atomic_store_ring_ptr(&pool.rings[r], nil)
				if pr != nil && pr != ring && !destroy_ring_if_quiesced(pr, i) {
					leaked = true
				}
			}
			for p in 0 ..< pool.parked_count {
				if pool.parked[p] != nil && !destroy_ring_if_quiesced(pool.parked[p], i) {
					leaked = true
				}
				pool.parked[p] = nil
			}
			pool.parked_count = 0
			sync.atomic_store(&pool.ring_count, u32(0))
		}

		if ring != nil {
			atomic_store_ring_ptr(&NODE.connection_rings[i], nil)
			if !destroy_ring_if_quiesced(ring, i) {
				leaked = true
			}
		}

		if pool != nil && !leaked {
			sync.atomic_store_explicit(cast(^u64)&NODE.connection_pools[i], u64(0), .Release)
			free(pool, get_system_allocator())
		}
	}
}

get_node_by_name :: proc(name: string) -> (Node_ID, bool) {
	sync.rw_mutex_shared_lock(&NODE.node_registry_lock)
	defer sync.rw_mutex_shared_unlock(&NODE.node_registry_lock)
	if id, exists := NODE.node_name_to_id[name]; exists {
		return id, true
	}
	return 0, false
}

unregister_node :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id >= MAX_NODES {
		return
	}

	conn_pid := PID(
		sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[node_id], .Acquire),
	)

	if conn_pid != 0 {
		send_message(conn_pid, Terminate{})

		// TODO: be more deterministic
		time.sleep(10 * time.Millisecond)
	}
}
