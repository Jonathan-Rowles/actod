package actod

import "core:sync"

MAX_RECLAIM_SLOTS :: 256

Reclaim_Slot :: struct #align (CACHE_LINE_SIZE) {
	active_epoch: u64,
	pad:         [CACHE_LINE_SIZE - size_of(u64)]byte,
}

Retired_Actor :: struct {
	actor_ptr: rawptr,
	epoch:     u64,
}

Reclaim_State :: struct {
	epoch:           u64,
	slots:           [MAX_RECLAIM_SLOTS]Reclaim_Slot,
	slot_count:      int,
	overflow_active: int,
	retire_mutex:    sync.Mutex,
	retire_list:     [dynamic]Retired_Actor,
	scan_lock:       sync.Mutex,
}

@(private, thread_local)
tls_reclaim_slot1: int

@(private, thread_local)
tls_reclaim_depth: int

@(private, thread_local)
tls_reclaim_overflow: bool

@(private = "file")
reclaim_claim_slot :: proc() -> int {
	if tls_reclaim_slot1 != 0 {
		return tls_reclaim_slot1 - 1
	}

	idx := sync.atomic_add(&NODE.reclaim.slot_count, 1)
	if idx < MAX_RECLAIM_SLOTS {
		tls_reclaim_slot1 = idx + 1
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
	if !sync.mutex_try_lock(&NODE.reclaim.scan_lock) {
		return
	}
	defer sync.mutex_unlock(&NODE.reclaim.scan_lock)

	sync.atomic_add(&NODE.reclaim.epoch, 1)

	min_active: u64 = 0
	have_active := false
	n := sync.atomic_load(&NODE.reclaim.slot_count)

	if n > MAX_RECLAIM_SLOTS {
		n = MAX_RECLAIM_SLOTS
	}

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

reclaim_drain_all :: proc() {
	sync.mutex_lock(&NODE.reclaim.retire_mutex)
	defer sync.mutex_unlock(&NODE.reclaim.retire_mutex)

	for r in NODE.reclaim.retire_list {
		cleanup_actor_arena(r.actor_ptr)
		free(r.actor_ptr, actor_system_allocator)
	}

	resize(&NODE.reclaim.retire_list, 0)
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
}
