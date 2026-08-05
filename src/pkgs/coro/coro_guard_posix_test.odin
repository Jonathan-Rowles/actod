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
		uintptr(co.stack_base) - uintptr(co.mapping_base) == STACK_GUARD_SIZE,
		"the guard region should sit directly below the stack",
	)
	testing.expect(
		t,
		uintptr(co) == uintptr(co.stack_base) + uintptr(co.stack_size),
		"the coro header should sit directly above the stack, away from a downward overflow",
	)

	reader, writer, pipe_err := os.pipe()
	testing.expect(t, pipe_err == nil, "could not open a pipe")
	defer os.close(reader)
	defer os.close(writer)

	guard_top := mem.slice_ptr(cast(^u8)(uintptr(co.stack_base) - 1), 1)
	_, guard_err := os.write(writer, guard_top)
	testing.expect(t, guard_err != nil, "the guard region should not be readable")

	stack_bottom := mem.slice_ptr(cast(^u8)co.stack_base, 1)
	_, stack_err := os.write(writer, stack_bottom)
	testing.expect(t, stack_err == nil, "the stack itself should stay readable")
}
