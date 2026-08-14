#+build linux, darwin, freebsd, openbsd, netbsd
package coro

import "core:mem"
import "core:os"
import "core:testing"

@(test)
test_stack_guard_region_is_inaccessible :: proc(t: ^testing.T) {
	noop_entry :: proc(co: ^Coro) {
		yield(co)
	}

	desc := desc_init(noop_entry)
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")
	defer destroy(co)

	testing.expect(
		t,
		uintptr(co) - uintptr(co.mapping_base) == STACK_GUARD_SIZE,
		"the guard region should sit directly below the coro header",
	)
	testing.expect(
		t,
		uintptr(co.stack_base) - uintptr(co.canary_base) == STACK_CANARY_SIZE,
		"the canary should sit directly below the usable stack",
	)
	testing.expect(
		t,
		uintptr(co.canary_base) - uintptr(co) < uintptr(mem.PAGE_SIZE),
		"the canary should share the header's first page so it costs no extra resident page",
	)

	reader, writer, pipe_err := os.pipe()
	testing.expect(t, pipe_err == nil, "could not open a pipe")
	defer os.close(reader)
	defer os.close(writer)

	guard_top := mem.slice_ptr(cast(^u8)(uintptr(co) - 1), 1)
	_, guard_err := os.write(writer, guard_top)
	testing.expect(t, guard_err != nil, "the guard region should not be readable")

	stack_bottom := mem.slice_ptr(cast(^u8)co.stack_base, 1)
	_, stack_err := os.write(writer, stack_bottom)
	testing.expect(t, stack_err == nil, "the stack itself should stay readable")
}

@(test)
test_unmapped_coro_uses_a_canary_instead_of_a_guard :: proc(t: ^testing.T) {
	noop_entry :: proc(co: ^Coro) {
		yield(co)
	}

	desc := desc_init(noop_entry)
	region := make([]byte, region_size(page_align(desc.stack_size), desc.storage_size))
	defer delete(region)

	co, res := create_in(&desc, region)
	testing.expect(t, res == .Success, "create_in failed")
	if res != .Success {
		return
	}

	testing.expect(t, co.mapping_base == nil, "a caller-provided coro must not own a mapping")
	testing.expect(t, uintptr(co) == uintptr(raw_data(region)), "the coro header should sit at the base of the region")
	testing.expect(
		t,
		uintptr(co.canary_base) - uintptr(co) < uintptr(mem.PAGE_SIZE),
		"the canary should share the header's first page",
	)
	testing.expect(t, stack_canary_intact(co), "a fresh canary should be intact")

	scribble := cast([^]u64)co.canary_base
	scribble[STACK_CANARY_SIZE / size_of(u64) - 1] = 0
	testing.expect(t, !stack_canary_intact(co), "a write into the canary must be detected")

	scribble[STACK_CANARY_SIZE / size_of(u64) - 1] = STACK_CANARY_WORD
	testing.expect(t, stack_canary_intact(co), "restoring the canary should clear the detection")

	testing.expect(t, destroy(co) == .Success, "destroying a caller-provided coro should succeed")
}
