package actod

import "../pkgs/coro"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:sync"

SLAB_SLOT_NONE :: u32(0xFFFF_FFFF)
SLAB_COMMIT_CHUNK :: 8 * mem.Megabyte
DEFAULT_ACTOR_SLAB_SLOTS :: #config(ACTOD_ACTOR_SLAB_SLOTS, 16384)

@(private = "file")
slab_guard_size :: proc() -> uint {
	return uint(mem.PAGE_SIZE)
}

@(private = "file")
slab_reserve :: proc(size: uint) -> ([]byte, bool) {
	data, err := vmem.reserve(size + slab_guard_size())
	if err != nil do return nil, false
	slab_disable_transparent_hugepages(raw_data(data), size)
	return data[:size], true
}

@(private = "file")
slab_release :: proc(data: []byte) {
	if len(data) > 0 do vmem.release(raw_data(data), uint(len(data)) + slab_guard_size())
}

Slot_Slab :: struct #align (CACHE_LINE_SIZE) {
	free_head:     u64,
	_pad_head:     [CACHE_LINE_SIZE - size_of(u64)]byte,
	cursor:        u64,
	_pad_cursor:   [CACHE_LINE_SIZE - size_of(u64)]byte,
	in_use:        i64,
	_pad_in_use:   [CACHE_LINE_SIZE - size_of(i64)]byte,
	memory:        []byte,
	slot_next:     []u32,
	slot_purged:   []u32,
	slot_size:     uint,
	slot_count:    u64,
	committed:     uint,
	commit_mutex:  sync.Mutex,
	enabled:       bool,
	warned:        bool,
}

SLAB_KEEP_WARM :: #config(ACTOD_SLAB_KEEP_WARM, 64)

@(private = "file")
slab_spare_slots :: proc(slab: ^Slot_Slab) -> i64 {
	taken := i64(sync.atomic_load_explicit(&slab.cursor, .Relaxed))
	if taken > i64(slab.slot_count) do taken = i64(slab.slot_count)
	return taken - sync.atomic_load_explicit(&slab.in_use, .Relaxed)
}

slot_slab_init :: proc(slab: ^Slot_Slab, slot_size: uint, slot_count: u64) -> bool {
	if slot_size == 0 || slot_count == 0 do return false

	aligned_slot := mem.align_forward_uint(slot_size, uint(mem.PAGE_SIZE))
	total := aligned_slot * uint(slot_count)
	if total / aligned_slot != uint(slot_count) do return false

	memory, ok := slab_reserve(total)
	if !ok do return false

	slot_next, alloc_err := make([]u32, slot_count, actor_system_allocator)
	if alloc_err != nil {
		slab_release(memory)
		return false
	}

	slot_purged, purged_err := make([]u32, slot_count, actor_system_allocator)
	if purged_err != nil {
		delete(slot_next, actor_system_allocator)
		slab_release(memory)
		return false
	}

	slab.memory = memory
	slab.slot_next = slot_next
	slab.slot_purged = slot_purged
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
	if !slab.enabled do return
	slab_release(slab.memory)
	delete(slab.slot_next, actor_system_allocator)
	delete(slab.slot_purged, actor_system_allocator)
	slab^ = {}
}

@(private = "file")
slab_pack_head :: proc(index: u32, generation: u32) -> u64 {
	return (u64(generation) << 32) | u64(index)
}

@(private = "file")
slab_ensure_committed :: proc(slab: ^Slot_Slab, slot_index: u64) -> bool {
	required := uint(slot_index + 1) * slab.slot_size
	if sync.atomic_load_explicit(&slab.committed, .Acquire) >= required do return true

	sync.mutex_lock(&slab.commit_mutex)
	defer sync.mutex_unlock(&slab.commit_mutex)

	if slab.committed >= required do return true

	target := mem.align_forward_uint(required, SLAB_COMMIT_CHUNK)
	if target > len(slab.memory) do target = len(slab.memory)
	if vmem.commit(raw_data(slab.memory), target) != nil do return false
	sync.atomic_store_explicit(&slab.committed, target, .Release)
	return true
}

slot_slab_take :: proc(slab: ^Slot_Slab) -> (index: u32, ok: bool) {
	if !slab.enabled do return 0, false

	for {
		head := sync.atomic_load_explicit(&slab.free_head, .Acquire)
		free_index := u32(head)
		if free_index == SLAB_SLOT_NONE do break

		next := sync.atomic_load_explicit(&slab.slot_next[free_index], .Acquire)
		new_head := slab_pack_head(next, u32(head >> 32) + 1)
		if _, swapped := sync.atomic_compare_exchange_weak_explicit(
			&slab.free_head,
			head,
			new_head,
			.Acq_Rel,
			.Acquire,
		); swapped {
			purged := sync.atomic_exchange_explicit(&slab.slot_purged[free_index], 0, .Acq_Rel)
			if purged > 0 {
				slot := slot_slab_slot(slab, free_index)
				if vmem.commit(raw_data(slot), uint(purged)) != nil {
					sync.atomic_store_explicit(&slab.slot_purged[free_index], purged, .Release)
					slab_push_free(slab, free_index)
					return 0, false
				}
			}
			sync.atomic_add(&slab.in_use, 1)
			return free_index, true
		}
	}

	claimed := sync.atomic_add(&slab.cursor, 1)
	if claimed >= slab.slot_count do return 0, false
	if !slab_ensure_committed(slab, claimed) do return 0, false

	sync.atomic_add(&slab.in_use, 1)
	return u32(claimed), true
}

@(private = "file")
slab_push_free :: proc(slab: ^Slot_Slab, index: u32) {
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
			return
		}
	}
}

slot_slab_give :: proc(slab: ^Slot_Slab, index: u32, touched: uint) {
	if !slab.enabled || u64(index) >= slab.slot_count do return

	purge := mem.align_forward_uint(min(touched, slab.slot_size), uint(mem.PAGE_SIZE))
	if purge > 0 && slab_spare_slots(slab) >= SLAB_KEEP_WARM {
		sync.atomic_store_explicit(&slab.slot_purged[index], u32(purge), .Release)
		vmem.decommit(raw_data(slot_slab_slot(slab, index)), purge)
	}

	slab_push_free(slab, index)
	sync.atomic_sub(&slab.in_use, 1)
}

slot_slab_slot :: proc(slab: ^Slot_Slab, index: u32) -> []byte {
	offset := uintptr(index) * uintptr(slab.slot_size)
	return slab.memory[offset:][:slab.slot_size]
}

slot_slab_in_use :: proc(slab: ^Slot_Slab) -> i64 {
	return sync.atomic_load(&slab.in_use)
}

@(private)
warn_slab_exhausted :: proc(what: string, slab: ^Slot_Slab) {
	if _, first := sync.atomic_compare_exchange_strong(&slab.warned, false, true); !first do return
	log.warnf(
		"the %s slab is full at %d slots of %d KB, so every actor from here on gets its own mapping instead. Those actors work normally, but spawn and teardown cost syscalls again and each one costs about 2 VMAs, so a large node can reach vm.max_map_count and fail to spawn. Raise it with actor_slab_slots in make_node_config() or -define:ACTOD_ACTOR_SLAB_SLOTS=N, budgeting %d KB of address space per slot",
		what,
		slab.slot_count,
		slab.slot_size / 1024,
		slab.slot_size / 1024,
	)
}

Actor_Arena :: struct {
	primary:       vmem.Arena,
	overflow:      vmem.Arena,
	spill_reserve: uint,
}

@(private = "file")
actor_arena_open_spill :: proc(arena: ^Actor_Arena) -> bool {
	if arena.overflow.curr_block != nil do return true
	if arena.spill_reserve == 0 do return false
	return vmem.arena_init_static(&arena.overflow, arena.spill_reserve, ARENA_COMMIT_SIZE) == nil
}

@(private = "file")
actor_arena_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size: int,
	alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	arena := cast(^Actor_Arena)allocator_data

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		data, err := vmem.arena_allocator_proc(
			&arena.primary,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)
		if err == nil do return data, nil
		if !actor_arena_open_spill(arena) do return nil, .Out_Of_Memory
		return vmem.arena_allocator_proc(
			&arena.overflow,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)

	case .Resize, .Resize_Non_Zeroed:
		data, err := vmem.arena_allocator_proc(
			&arena.primary,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)
		if err == nil do return data, nil
		if !actor_arena_open_spill(arena) do return nil, .Out_Of_Memory
		fresh_mode: mem.Allocator_Mode = mode == .Resize ? .Alloc : .Alloc_Non_Zeroed
		moved, moved_err := vmem.arena_allocator_proc(
			&arena.overflow,
			fresh_mode,
			size,
			alignment,
			nil,
			0,
			loc,
		)
		if moved_err != nil do return nil, moved_err
		if old_memory != nil && old_size > 0 {
			copy(moved, (cast([^]byte)old_memory)[:min(old_size, size)])
		}
		return moved, nil

	case .Free:
		return nil, .Mode_Not_Implemented

	case .Free_All:
		vmem.arena_free_all(&arena.primary, loc)
		if arena.overflow.curr_block != nil do vmem.arena_free_all(&arena.overflow, loc)
		return nil, nil

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {
				.Alloc,
				.Alloc_Non_Zeroed,
				.Free_All,
				.Resize,
				.Resize_Non_Zeroed,
				.Query_Features,
			}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}

actor_arena_allocator :: proc(arena: ^Actor_Arena) -> mem.Allocator {
	return mem.Allocator{actor_arena_proc, arena}
}

actor_arena_acquire :: proc(
	arena: ^Actor_Arena,
	slot_ref: ^u32,
	data_size: int,
	mailbox_size: int,
	opts: Actor_Config,
) -> bool {
	slot_ref^ = 0
	arena^ = {}
	reserve := actor_arena_reserve(data_size, mailbox_size, opts)
	arena.spill_reserve = reserve

	if NODE.actor_slab.enabled && uint(data_size) < NODE.actor_slab.slot_size {
		if index, took := slot_slab_take(&NODE.actor_slab); took {
			if vmem.arena_init_buffer(
				   &arena.primary,
				   slot_slab_slot(&NODE.actor_slab, index),
			   ) ==
			   nil {
				slot_ref^ = index + 1
				return true
			}
			slot_slab_give(&NODE.actor_slab, index, 0)
		} else {
			warn_slab_exhausted("actor arena", &NODE.actor_slab)
		}
	}

	return vmem.arena_init_static(&arena.primary, reserve, ARENA_COMMIT_SIZE) == nil
}

coro_header_bytes :: proc() -> uint {
	return coro.header_size()
}

coro_slot_size :: proc(stack_size: uint) -> uint {
	stack := stack_size
	if stack < coro.MIN_STACK_SIZE do stack = coro.MIN_STACK_SIZE
	return coro.region_size(coro.page_align(stack))
}

coro_acquire :: proc(
	desc: ^coro.Desc,
	slot_ref: ^u32,
	stack_size: uint,
) -> (
	^coro.Coro,
	coro.Result,
) {
	slot_ref^ = 0

	if NODE.coro_slab.enabled && coro_slot_size(stack_size) <= NODE.coro_slab.slot_size {
		if index, took := slot_slab_take(&NODE.coro_slab); took {
			co, res := coro.create_in(desc, slot_slab_slot(&NODE.coro_slab, index))
			if res == .Success {
				slot_ref^ = index + 1
				return co, res
			}
			slot_slab_give(&NODE.coro_slab, index, 0)
		} else {
			warn_slab_exhausted("coroutine stack", &NODE.coro_slab)
		}
	}

	return coro.create(desc)
}

coro_release :: proc(co: ^coro.Coro, slot_ref: ^u32, gone_for_good: bool) -> coro.Result {
	res := coro.destroy(co)
	if slot_ref^ != 0 {
		slot_slab_give(
			&NODE.coro_slab,
			slot_ref^ - 1,
			gone_for_good ? NODE.coro_slab.slot_size : 0,
		)
		slot_ref^ = 0
	}
	return res
}

actor_arena_release :: proc(arena: ^Actor_Arena, slot_ref: ^u32) {
	if arena.overflow.curr_block != nil do vmem.arena_destroy(&arena.overflow)

	if slot_ref^ == 0 {
		vmem.arena_destroy(&arena.primary)
		arena^ = {}
		return
	}

	touched := uint(size_of(vmem.Memory_Block))
	if arena.primary.curr_block != nil do touched += arena.primary.curr_block.used

	vmem.arena_free_all(&arena.primary)
	arena^ = {}
	slot_slab_give(&NODE.actor_slab, slot_ref^ - 1, touched)
	slot_ref^ = 0
}
