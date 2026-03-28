#+build arm64, darwin
package coro

Ctx_Buf :: struct {
	x:  [12]rawptr, // x19-x30
	sp: rawptr,
	lr: rawptr,
	d:  [8]rawptr, // d8-d15
}

foreign import mco_asm "mco_switch_arm64_darwin.asm"

@(default_calling_convention = "c")
foreign mco_asm {
	mco_switch :: proc(from: ^Ctx_Buf, to: ^Ctx_Buf) ---
	mco_wrap_main :: proc() ---
}

makectx :: proc(co: ^Coro, stack_base: rawptr, stack_size: uint) -> Result {
	co.coro_ctx.x[0] = rawptr(co) // x19 = coroutine pointer
	co.coro_ctx.x[1] = rawptr(mco_main) // x20 = _mco_main
	co.coro_ctx.x[2] = rawptr(uintptr(0xdeaddeaddeaddead)) // x21 = dummy return address
	co.coro_ctx.sp = rawptr(uintptr(stack_base) + uintptr(stack_size)) // stack top
	co.coro_ctx.lr = rawptr(mco_wrap_main) // entry via trampoline
	return .Success
}
