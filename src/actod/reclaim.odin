package actod

import "../pkgs/coro"
import "core:log"
import "core:sync"

MAX_RECLAIM_SLOTS :: 256

Reclaim_Slot :: struct #align (CACHE_LINE_SIZE) {
	active_epoch: u64,
	pad:          [CACHE_LINE_SIZE - size_of(u64)]byte,
}

Retired_Actor :: struct {
	actor_ptr: rawptr,
	epoch:     u64,
}

Reclaim_State :: struct {
	epoch:                 u64,
	slots:                 [MAX_RECLAIM_SLOTS]Reclaim_Slot,
	slot_count:            int,
	overflow_active:       int,
	retire_mutex:          sync.Mutex,
	retire_list:           [dynamic]Retired_Actor,
	scan_lock:             sync.Mutex,
	bound_thread_slot1:    int,
	bound_thread_overflow: bool,
}

@(private)
reclaim_generation: u64

@(private, thread_local)
tls_reclaim_slot1: int

@(private, thread_local)
tls_reclaim_generation: u64

@(private, thread_local)
tls_reclaim_depth: int

@(private, thread_local)
tls_reclaim_overflow: bool

@(private = "file")
reclaim_claim_slot :: proc() -> int {
	generation := sync.atomic_load_explicit(&reclaim_generation, .Relaxed)
	if tls_reclaim_slot1 != 0 && tls_reclaim_generation == generation do return tls_reclaim_slot1 - 1

	idx := sync.atomic_add(&NODE.reclaim.slot_count, 1)
	if idx < MAX_RECLAIM_SLOTS {
		tls_reclaim_slot1 = idx + 1
		tls_reclaim_generation = generation
		return idx
	}

	return -1
}

reclaim_pin :: #force_inline proc() {
	if tls_reclaim_depth == 0 {
		idx := reclaim_claim_slot()
		if idx >= 0 {
			e := sync.atomic_load_explicit(&NODE.reclaim.epoch, .Acquire)
			sync.atomic_store_explicit(&NODE.reclaim.slots[idx].active_epoch, e, .Release)
			tls_reclaim_overflow = false
		} else {
			sync.atomic_add(&NODE.reclaim.overflow_active, 1)
			tls_reclaim_overflow = true
		}

		sync.atomic_thread_fence(.Seq_Cst)
	}

	tls_reclaim_depth += 1
}

reclaim_unpin :: #force_inline proc() {
	tls_reclaim_depth -= 1
	if tls_reclaim_depth == 0 {

		if tls_reclaim_overflow {
			sync.atomic_sub(&NODE.reclaim.overflow_active, 1)
		} else {
			sync.atomic_store_explicit(
				&NODE.reclaim.slots[tls_reclaim_slot1 - 1].active_epoch,
				0,
				.Release,
			)
		}

	}
}

reclaim_pin_unless_coroutine :: #force_inline proc() -> (pinned: bool) {
	if coro.running() != nil do return false
	reclaim_pin()
	return true
}

reclaim_pin_if_unpinned :: #force_inline proc() -> (pinned: bool) {
	if tls_reclaim_depth != 0 do return false
	reclaim_pin()
	return true
}

reclaim_unpin_all_levels :: #force_inline proc() -> (released_depth: int) {
	released_depth = tls_reclaim_depth
	if released_depth == 0 do return
	tls_reclaim_depth = 1
	reclaim_unpin()
	return
}

reclaim_repin_levels :: #force_inline proc(depth: int) {
	if depth == 0 do return
	reclaim_pin()
	tls_reclaim_depth = depth
}

reclaim_retire :: proc(actor_ptr: rawptr) {
	sync.atomic_thread_fence(.Seq_Cst)
	e := sync.atomic_load_explicit(&NODE.reclaim.epoch, .Acquire)

	sync.mutex_lock(&NODE.reclaim.retire_mutex)
	if NODE.reclaim.retire_list.allocator.procedure == nil {
		NODE.reclaim.retire_list.allocator = get_system_allocator()
	}

	append(&NODE.reclaim.retire_list, Retired_Actor{actor_ptr = actor_ptr, epoch = e})
	sync.mutex_unlock(&NODE.reclaim.retire_mutex)
}

reclaim_scan :: proc() {
	if !sync.mutex_try_lock(&NODE.reclaim.scan_lock) do return
	defer sync.mutex_unlock(&NODE.reclaim.scan_lock)

	sync.atomic_add(&NODE.reclaim.epoch, 1)

	min_active: u64 = 0
	have_active := false
	n := sync.atomic_load(&NODE.reclaim.slot_count)

	if n > MAX_RECLAIM_SLOTS do n = MAX_RECLAIM_SLOTS

	for i in 0 ..< n {
		e := sync.atomic_load_explicit(&NODE.reclaim.slots[i].active_epoch, .Acquire)
		if e != 0 && (!have_active || e < min_active) {
			min_active = e
			have_active = true
		}
	}

	overflow := sync.atomic_load(&NODE.reclaim.overflow_active) > 0

	sync.mutex_lock(&NODE.reclaim.retire_mutex)
	defer sync.mutex_unlock(&NODE.reclaim.retire_mutex)

	keep := 0
	for r in NODE.reclaim.retire_list {
		safe := !overflow && (!have_active || r.epoch < min_active)
		if safe {
			cleanup_actor_arena(r.actor_ptr)
			free(r.actor_ptr, actor_system_allocator)
		} else {
			NODE.reclaim.retire_list[keep] = r
			keep += 1
		}
	}

	resize(&NODE.reclaim.retire_list, keep)
}

reclaim_retired_count :: proc() -> int {
	sync.mutex_lock(&NODE.reclaim.retire_mutex)
	defer sync.mutex_unlock(&NODE.reclaim.retire_mutex)
	return len(NODE.reclaim.retire_list)
}

reclaim_reset :: proc() {
	sync.mutex_lock(&NODE.reclaim.retire_mutex)

	if len(NODE.reclaim.retire_list) > 0 {
		for r in NODE.reclaim.retire_list {
			cleanup_actor_arena(r.actor_ptr)
			free(r.actor_ptr, actor_system_allocator)
		}
		resize(&NODE.reclaim.retire_list, 0)
	}

	sync.mutex_unlock(&NODE.reclaim.retire_mutex)

	sync.atomic_store(&NODE.reclaim.slot_count, 0)
	sync.atomic_store(&NODE.reclaim.overflow_active, 0)
	sync.atomic_store(&NODE.reclaim.epoch, 1)

	for i in 0 ..< MAX_RECLAIM_SLOTS {
		sync.atomic_store(&NODE.reclaim.slots[i].active_epoch, 0)
	}
	NODE.reclaim.bound_thread_slot1 = 0
	NODE.reclaim.bound_thread_overflow = false

	sync.atomic_add(&reclaim_generation, 1)
}

reclaim_detach_bound_thread :: proc() {
	generation := sync.atomic_load_explicit(&reclaim_generation, .Relaxed)
	slot_is_current := tls_reclaim_slot1 != 0 && tls_reclaim_generation == generation
	NODE.reclaim.bound_thread_slot1 = slot_is_current ? tls_reclaim_slot1 : 0
	NODE.reclaim.bound_thread_overflow = tls_reclaim_depth > 0 && tls_reclaim_overflow
}

reclaim_attach_bound_thread :: proc() {
	tls_reclaim_slot1 = NODE.reclaim.bound_thread_slot1
	tls_reclaim_generation = sync.atomic_load_explicit(&reclaim_generation, .Relaxed)

	if tls_reclaim_depth == 0 {
		if NODE.reclaim.bound_thread_overflow {
			sync.atomic_sub(&NODE.reclaim.overflow_active, 1)
		} else if tls_reclaim_slot1 != 0 {
			sync.atomic_store_explicit(
				&NODE.reclaim.slots[tls_reclaim_slot1 - 1].active_epoch,
				0,
				.Release,
			)
		}
		NODE.reclaim.bound_thread_overflow = false
		return
	}

	if NODE.reclaim.bound_thread_overflow {
		tls_reclaim_overflow = true
		return
	}
	if tls_reclaim_slot1 != 0 &&
	   sync.atomic_load(&NODE.reclaim.slots[tls_reclaim_slot1 - 1].active_epoch) != 0 {
		tls_reclaim_overflow = false
		return
	}

	held_depth := tls_reclaim_depth
	tls_reclaim_depth = 0
	reclaim_repin_levels(held_depth)
}

report_pins_held_across_reset :: proc() {
	held := sync.atomic_load(&NODE.reclaim.overflow_active)
	n := min(sync.atomic_load(&NODE.reclaim.slot_count), MAX_RECLAIM_SLOTS)
	for i in 0 ..< n {
		if sync.atomic_load(&NODE.reclaim.slots[i].active_epoch) != 0 do held += 1
	}
	if held > 0 {
		log.errorf(
			"reclaim reset found %d pins still held, a thread pinned across a node restart will unpin a slot the next node has handed to another thread",
			held,
		)
	}
}

when ODIN_TEST {
	reclaim_pin_visible_to_scanner :: proc() -> bool {
		if tls_reclaim_depth == 0 do return false
		if tls_reclaim_overflow do return sync.atomic_load(&NODE.reclaim.overflow_active) > 0
		idx := tls_reclaim_slot1 - 1
		if idx < 0 || idx >= sync.atomic_load(&NODE.reclaim.slot_count) do return false
		return sync.atomic_load(&NODE.reclaim.slots[idx].active_epoch) != 0
	}

	reclaim_slot_of_this_thread :: proc() -> int {
		if tls_reclaim_depth == 0 || tls_reclaim_overflow do return -1
		return tls_reclaim_slot1 - 1
	}
}
