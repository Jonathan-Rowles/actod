#+build amd64, linux
package coro

Ctx_Buf :: struct {
	rip, rsp, rbp, rbx, r12, r13, r14, r15: rawptr,
}

foreign import mco_asm "mco_switch_amd64_linux.asm"

@(default_calling_convention = "c")
foreign mco_asm {
	mco_switch :: proc(from: ^Ctx_Buf, to: ^Ctx_Buf) ---
	mco_wrap_main :: proc() ---
}

makectx :: proc(co: ^Coro, stack_base: rawptr, stack_size: uint) -> Result {
	// Reserve 128 bytes for the Red Zone (System V AMD64 ABI).
	adjusted_size := stack_size - 128
	stack_high_ptr := cast(^rawptr)(uintptr(stack_base) +
		uintptr(adjusted_size) -
		size_of(uintptr))
	stack_high_ptr^ = rawptr(uintptr(0xdeaddeaddeaddead)) // Dummy return address.
	co.coro_ctx.rip = rawptr(mco_wrap_main)
	co.coro_ctx.rsp = rawptr(stack_high_ptr)
	co.coro_ctx.r12 = rawptr(mco_main)
	co.coro_ctx.r13 = rawptr(co)
	return .Success
}
