package actod

import "core:mem"
import vmem "core:mem/virtual"
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
	testing.expect(t, arena.overflow.curr_block == nil, "a small allocation should not open the spill arena")
	testing.expect(
		t,
		raw_data(data) >= raw_data(slot) && raw_data(data) < raw_data(slot[len(slot):]),
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
	testing.expect(t, big_err == nil, "an allocation larger than the slot should spill, not fail")
	testing.expect(t, arena.overflow.curr_block != nil, "the spill arena should be open")

	big[0] = 0x11
	big[len(big) - 1] = 0x22
	testing.expect(t, big[0] == 0x11 && big[len(big) - 1] == 0x22, "spilled memory should be writable")
	testing.expect(
		t,
		small[0] == 0xAB && small[len(small) - 1] == 0xCD,
		"spilling must not disturb allocations already in the slot",
	)
}

@(test)
test_actor_arena_resize_across_the_slot_boundary_keeps_contents :: proc(t: ^testing.T) {
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

	grown, grow_err := mem.resize_bytes(data, ARENA_TEST_SLOT * 4, allocator = allocator)
	testing.expect(t, grow_err == nil, "growing past the slot should spill, not fail")
	testing.expect(t, len(grown) == ARENA_TEST_SLOT * 4, "the grown allocation should have the requested size")

	intact := true
	for i in 0 ..< 2048 {
		if grown[i] != u8(i) {
			intact = false
			break
		}
	}
	testing.expect(t, intact, "growing across the slot boundary should copy the old contents")
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
	testing.expect(t, arena.overflow.curr_block != nil, "the spill arena should be open before free_all")

	free_all(allocator)

	testing.expect(t, arena.primary.total_used == 0, "free_all should reset the slot")
	testing.expect(t, arena.overflow.total_used == 0, "free_all should reset the spill arena")

	again, err := mem.alloc_bytes(1024, allocator = allocator)
	testing.expect(t, err == nil, "the arena should be reusable after free_all")
	testing.expect(
		t,
		raw_data(again) >= raw_data(slot) && raw_data(again) < raw_data(slot[len(slot):]),
		"after free_all the slot should be used again before spilling",
	)
}
