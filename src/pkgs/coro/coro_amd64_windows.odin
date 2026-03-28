#+build amd64, windows
package coro

Ctx_Buf :: struct {
	rip, rsp, rbp, rbx, rdi, rsi, r12, r13, r14, r15: rawptr,
	xmm6:                                             [2]u64,
	xmm7:                                             [2]u64,
	xmm8:                                             [2]u64,
	xmm9:                                             [2]u64,
	xmm10:                                            [2]u64,
	xmm11:                                            [2]u64,
	xmm12:                                            [2]u64,
	xmm13:                                            [2]u64,
	xmm14:                                            [2]u64,
	xmm15:                                            [2]u64,
}

foreign import mco_asm "mco_switch_amd64_windows.asm"

@(default_calling_convention = "c")
foreign mco_asm {
	mco_switch :: proc(from: ^Ctx_Buf, to: ^Ctx_Buf) ---
	mco_wrap_main :: proc() ---
}

makectx :: proc(co: ^Coro, stack_base: rawptr, stack_size: uint) -> Result {
	// Windows x64 has no red zone — no size adjustment needed.
	stack_high_ptr := cast(^rawptr)(uintptr(stack_base) + uintptr(stack_size) - size_of(uintptr))
	stack_high_ptr^ = rawptr(uintptr(0xdeaddeaddeaddead)) // Dummy return address.
	co.coro_ctx.rip = rawptr(mco_wrap_main)
	co.coro_ctx.rsp = rawptr(stack_high_ptr)
	co.coro_ctx.r12 = rawptr(mco_main)
	co.coro_ctx.r13 = rawptr(co)
	return .Success
}
