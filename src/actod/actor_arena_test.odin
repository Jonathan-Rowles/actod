package actod

import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:sync"
import "core:testing"

ARENA_TEST_SLOT :: 64 * mem.Kilobyte

@(private = "file")
make_slot_arena :: proc(arena: ^Actor_Arena, slot: []byte) -> mem.Allocator {
	arena^ = {}
	_ = vmem.arena_init_buffer(&arena.primary, slot)
	arena.spill_reserve = 4 * mem.Megabyte
	return actor_arena_allocator(arena)
}

@(test)
test_actor_arena_keeps_small_allocations_in_its_slot :: proc(t: ^testing.T) {
	slot := make([]byte, ARENA_TEST_SLOT)
	defer delete(slot)

	arena: Actor_Arena
	allocator := make_slot_arena(&arena, slot)
	defer vmem.arena_destroy(&arena.overflow)

	data, err := mem.alloc_bytes(1024, allocator = allocator)
	testing.expect(t, err == nil, "a small allocation should succeed")
	testing.expect(
		t,
		arena.overflow.curr_block == nil,
		"a small allocation should not open the spill arena",
	)
	testing.expect(
		t,
		raw_data(data) >= raw_data(slot) &&
		raw_data(data) < raw_data(slot[len(slot):]),
		"a small allocation should come from the slot",
	)
}

@(test)
test_actor_arena_spills_past_its_slot :: proc(t: ^testing.T) {
	slot := make([]byte, ARENA_TEST_SLOT)
	defer delete(slot)

	arena: Actor_Arena
	allocator := make_slot_arena(&arena, slot)
	defer vmem.arena_destroy(&arena.overflow)

	small, small_err := mem.alloc_bytes(1024, allocator = allocator)
	testing.expect(t, small_err == nil, "the first allocation should succeed")
	small[0] = 0xAB
	small[len(small) - 1] = 0xCD

	big, big_err := mem.alloc_bytes(ARENA_TEST_SLOT * 4, allocator = allocator)
	testing.expect(
		t,
		big_err == nil,
		"an allocation larger than the slot should spill, not fail",
	)
	testing.expect(
		t,
		arena.overflow.curr_block != nil,
		"the spill arena should be open",
	)

	big[0] = 0x11
	big[len(big) - 1] = 0x22
	testing.expect(
		t,
		big[0] == 0x11 && big[len(big) - 1] == 0x22,
		"spilled memory should be writable",
	)
	testing.expect(
		t,
		small[0] == 0xAB && small[len(small) - 1] == 0xCD,
		"spilling must not disturb allocations already in the slot",
	)
}

@(test)
test_actor_arena_resize_across_the_slot_boundary_keeps_contents :: proc(
	t: ^testing.T,
) {
	slot := make([]byte, ARENA_TEST_SLOT)
	defer delete(slot)

	arena: Actor_Arena
	allocator := make_slot_arena(&arena, slot)
	defer vmem.arena_destroy(&arena.overflow)

	data, err := mem.alloc_bytes(2048, allocator = allocator)
	testing.expect(t, err == nil, "the initial allocation should succeed")
	for i in 0 ..< len(data) {
		data[i] = u8(i)
	}

	grown, grow_err := mem.resize_bytes(
		data,
		ARENA_TEST_SLOT * 4,
		allocator = allocator,
	)
	testing.expect(
		t,
		grow_err == nil,
		"growing past the slot should spill, not fail",
	)
	testing.expect(
		t,
		len(grown) == ARENA_TEST_SLOT * 4,
		"the grown allocation should have the requested size",
	)

	intact := true
	for i in 0 ..< 2048 {
		if grown[i] != u8(i) {
			intact = false
			break
		}
	}
	testing.expect(
		t,
		intact,
		"growing across the slot boundary should copy the old contents",
	)
}

@(test)
test_actor_arena_free_all_resets_both_tiers :: proc(t: ^testing.T) {
	slot := make([]byte, ARENA_TEST_SLOT)
	defer delete(slot)

	arena: Actor_Arena
	allocator := make_slot_arena(&arena, slot)
	defer vmem.arena_destroy(&arena.overflow)

	_, _ = mem.alloc_bytes(1024, allocator = allocator)
	_, _ = mem.alloc_bytes(ARENA_TEST_SLOT * 4, allocator = allocator)
	testing.expect(
		t,
		arena.overflow.curr_block != nil,
		"the spill arena should be open before free_all",
	)

	free_all(allocator)

	testing.expect(
		t,
		arena.primary.total_used == 0,
		"free_all should reset the slot",
	)
	testing.expect(
		t,
		arena.overflow.total_used == 0,
		"free_all should reset the spill arena",
	)

	again, err := mem.alloc_bytes(1024, allocator = allocator)
	testing.expect(
		t,
		err == nil,
		"the arena should be reusable after free_all",
	)
	testing.expect(
		t,
		raw_data(again) >= raw_data(slot) &&
		raw_data(again) < raw_data(slot[len(slot):]),
		"after free_all the slot should be used again before spilling",
	)
}

@(test)
test_get_children_returns_nil_when_the_caller_arena_is_exhausted :: proc(
	t: ^testing.T,
) {
	sync.lock(&global_registry_swap_mutex)
	defer sync.unlock(&global_registry_swap_mutex)
	saved_registry := NODE.actor_registry
	defer NODE.actor_registry = saved_registry
	test_registry := make_test_registry()
	defer free(test_registry)
	NODE.actor_registry = test_registry^
	if sync.atomic_load(&NODE.reclaim.epoch) == 0 do sync.atomic_store(&NODE.reclaim.epoch, 1)

	parent: Actor
	parent.state = .RUNNING
	parent.children = make([dynamic]Supervised_Child)
	defer delete(parent.children)
	parent_pid, added := add(
		&NODE.actor_registry,
		rawptr(&parent),
		"exhausted-parent",
	)
	testing.expect(t, added, "the parent should register")
	parent.pid = parent_pid
	append(
		&parent.children,
		Supervised_Child{pid = pack_pid(Handle{idx = 91, gen = 1})},
	)
	append(
		&parent.children,
		Supervised_Child{pid = pack_pid(Handle{idx = 92, gen = 1})},
	)

	slot := make([]byte, ARENA_TEST_SLOT)
	defer delete(slot)
	arena: Actor_Arena
	_ = vmem.arena_init_buffer(&arena.primary, slot)
	exhausted_arena := actor_arena_allocator(&arena)
	for chunk := mem.Kilobyte; chunk > 0; chunk /= 2 {
		for {
			_, err := mem.alloc_bytes(chunk, 1, exhausted_arena)
			if err == .Out_Of_Memory do break
		}
	}

	context.allocator = exhausted_arena
	children := get_children(parent_pid)
	testing.expect(
		t,
		children == nil,
		"get_children should return nil when the arena cannot hold the copy",
	)
}

@(test)
test_rename_keeps_the_old_name_when_the_arena_is_exhausted :: proc(
	t: ^testing.T,
) {
	slot := make([]byte, ARENA_TEST_SLOT)
	defer delete(slot)
	arena: Actor_Arena
	_ = vmem.arena_init_buffer(&arena.primary, slot)
	exhausted_arena := actor_arena_allocator(&arena)

	actor: Actor
	actor.pid = pack_pid(Handle{idx = 93, gen = 1})
	actor.allocator = exhausted_arena
	actor.name = "before-rename"
	actor.published_name = &actor.name
	published_before := actor.published_name

	for chunk := mem.Kilobyte; chunk > 0; chunk /= 2 {
		for {
			_, err := mem.alloc_bytes(chunk, 1, exhausted_arena)
			if err == .Out_Of_Memory do break
		}
	}

	context.logger = log.nil_logger()
	handle_rename_actor(
		&actor,
		Rename_Actor {
			new_name = "after-rename-that-the-full-arena-cannot-hold",
		},
	)

	testing.expect_value(t, actor.name, "before-rename")
	testing.expect(
		t,
		actor.published_name == published_before,
		"the published record should stay the old one",
	)
	testing.expect_value(t, actor.published_name^, "before-rename")
}
