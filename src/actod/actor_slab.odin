package actod

import "../pkgs/coro"
import "core:mem"
import vmem "core:mem/virtual"
import "core:sync"

SLAB_SLOT_NONE :: u32(0xFFFF_FFFF)
SLAB_COMMIT_CHUNK :: 8 * mem.Megabyte
DEFAULT_ACTOR_SLAB_SLOTS :: #config(ACTOD_ACTOR_SLAB_SLOTS, 16384)

Slot_Slab :: struct #align (CACHE_LINE_SIZE) {
	free_head:     u64,
	_pad_head:     [CACHE_LINE_SIZE - size_of(u64)]byte,
	cursor:        u64,
	_pad_cursor:   [CACHE_LINE_SIZE - size_of(u64)]byte,
	in_use:        i64,
	_pad_in_use:   [CACHE_LINE_SIZE - size_of(i64)]byte,
	memory:        []byte,
	slot_next:     []u32,
	slot_size:     uint,
	slot_count:    u64,
	committed:     uint,
	commit_mutex:  sync.Mutex,
	enabled:       bool,
}

slot_slab_init :: proc(slab: ^Slot_Slab, slot_size: uint, slot_count: u64) -> bool {
	if slot_size == 0 || slot_count == 0 {
		return false
	}

	aligned_slot := uint(align_forward_uint(slot_size, uint(mem.PAGE_SIZE)))
	total := aligned_slot * uint(slot_count)
	if total / aligned_slot != uint(slot_count) {
		return false
	}

	memory, ok := slab_reserve(total)
	if !ok {
		return false
	}

	slot_next, alloc_err := make([]u32, slot_count, actor_system_allocator)
	if alloc_err != nil {
		slab_release(memory)
		return false
	}

	slab.memory = memory
	slab.slot_next = slot_next
	slab.slot_size = aligned_slot
	slab.slot_count = slot_count
	slab.free_head = u64(SLAB_SLOT_NONE)
	slab.cursor = 0
	slab.in_use = 0
	slab.committed = 0
	slab.enabled = true
	return true
}

slot_slab_destroy :: proc(slab: ^Slot_Slab) {
	if !slab.enabled {
		return
	}
	slab_release(slab.memory)
	delete(slab.slot_next, actor_system_allocator)
	slab^ = {}
}

@(private = "file")
align_forward_uint :: proc(value: uint, alignment: uint) -> uint {
	return (value + alignment - 1) & ~(alignment - 1)
}

@(private = "file")
slab_pack_head :: proc(index: u32, generation: u32) -> u64 {
	return (u64(generation) << 32) | u64(index)
}

@(private = "file")
slab_ensure_committed :: proc(slab: ^Slot_Slab, slot_index: u64) -> bool {
	when !SLAB_COMMIT_ON_DEMAND {
		return true
	} else {
		required := uint(slot_index + 1) * slab.slot_size
		if sync.atomic_load_explicit(&slab.committed, .Acquire) >= required {
			return true
		}

		sync.mutex_lock(&slab.commit_mutex)
		defer sync.mutex_unlock(&slab.commit_mutex)

		if slab.committed >= required {
			return true
		}

		target := align_forward_uint(required, SLAB_COMMIT_CHUNK)
		if target > len(slab.memory) {
			target = len(slab.memory)
		}
		if !slab_commit(raw_data(slab.memory), target) {
			return false
		}
		sync.atomic_store_explicit(&slab.committed, target, .Release)
		return true
	}
}

slot_slab_take :: proc(slab: ^Slot_Slab) -> (index: u32, ok: bool) {
	if !slab.enabled {
		return 0, false
	}

	for {
		head := sync.atomic_load_explicit(&slab.free_head, .Acquire)
		free_index := u32(head)
		if free_index == SLAB_SLOT_NONE {
			break
		}

		next := sync.atomic_load_explicit(&slab.slot_next[free_index], .Acquire)
		new_head := slab_pack_head(next, u32(head >> 32) + 1)
		if _, swapped := sync.atomic_compare_exchange_weak_explicit(
			&slab.free_head,
			head,
			new_head,
			.Acq_Rel,
			.Acquire,
		); swapped {
			sync.atomic_add(&slab.in_use, 1)
			return free_index, true
		}
	}

	claimed := sync.atomic_add(&slab.cursor, 1)
	if claimed >= slab.slot_count {
		return 0, false
	}
	if !slab_ensure_committed(slab, claimed) {
		return 0, false
	}

	sync.atomic_add(&slab.in_use, 1)
	return u32(claimed), true
}

slot_slab_give :: proc(slab: ^Slot_Slab, index: u32) {
	if !slab.enabled || u64(index) >= slab.slot_count {
		return
	}

	for {
		head := sync.atomic_load_explicit(&slab.free_head, .Acquire)
		sync.atomic_store_explicit(&slab.slot_next[index], u32(head), .Release)
		new_head := slab_pack_head(index, u32(head >> 32) + 1)
		if _, swapped := sync.atomic_compare_exchange_weak_explicit(
			&slab.free_head,
			head,
			new_head,
			.Acq_Rel,
			.Acquire,
		); swapped {
			sync.atomic_sub(&slab.in_use, 1)
			return
		}
	}
}

slot_slab_slot :: proc(slab: ^Slot_Slab, index: u32) -> []byte {
	offset := uintptr(index) * uintptr(slab.slot_size)
	return slab.memory[offset:][:slab.slot_size]
}

slot_slab_in_use :: proc(slab: ^Slot_Slab) -> i64 {
	return sync.atomic_load(&slab.in_use)
}

actor_arena_acquire :: proc(
	arena: ^vmem.Arena,
	slot_ref: ^u32,
	data_size: int,
	mailbox_size: int,
	opts: Actor_Config,
) -> bool {
	slot_ref^ = 0
	reserve := actor_arena_reserve(data_size, mailbox_size, opts)

	if NODE.actor_slab.enabled && reserve <= NODE.actor_slab.slot_size {
		if index, took := slot_slab_take(&NODE.actor_slab); took {
			if vmem.arena_init_buffer(arena, slot_slab_slot(&NODE.actor_slab, index)) == nil {
				slot_ref^ = index + 1
				return true
			}
			slot_slab_give(&NODE.actor_slab, index)
		}
	}

	return vmem.arena_init_static(arena, reserve, ARENA_COMMIT_SIZE) == nil
}

coro_slot_size :: proc(opts: Actor_Config) -> uint {
	stack := uint(opts.coro_stack_size)
	if stack < coro.MIN_STACK_SIZE {
		stack = coro.MIN_STACK_SIZE
	}
	return coro.region_size(coro.page_align(stack), coro.DEFAULT_STORAGE_SIZE)
}

coro_acquire :: proc(
	desc: ^coro.Desc,
	slot_ref: ^u32,
	opts: Actor_Config,
) -> (
	^coro.Coro,
	coro.Result,
) {
	slot_ref^ = 0

	if NODE.coro_slab.enabled && coro_slot_size(opts) <= NODE.coro_slab.slot_size {
		if index, took := slot_slab_take(&NODE.coro_slab); took {
			co, res := coro.create_in(desc, slot_slab_slot(&NODE.coro_slab, index))
			if res == .Success {
				slot_ref^ = index + 1
				return co, res
			}
			slot_slab_give(&NODE.coro_slab, index)
		}
	}

	return coro.create(desc)
}

coro_release :: proc(co: ^coro.Coro, slot_ref: ^u32) -> coro.Result {
	res := coro.destroy(co)
	if slot_ref^ != 0 {
		slot_slab_give(&NODE.coro_slab, slot_ref^ - 1)
		slot_ref^ = 0
	}
	return res
}

actor_arena_release :: proc(arena: ^vmem.Arena, slot_ref: ^u32) {
	if slot_ref^ == 0 {
		vmem.arena_destroy(arena)
		return
	}

	vmem.arena_free_all(arena)
	arena^ = {}
	slot_slab_give(&NODE.actor_slab, slot_ref^ - 1)
	slot_ref^ = 0
}
