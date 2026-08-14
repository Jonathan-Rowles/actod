package coro

import "base:runtime"
import "core:mem"
import vmem "core:mem/virtual"

MIN_STACK_SIZE :: 16 * mem.Kilobyte
DEFAULT_STACK_SIZE :: 56 * 1024
STACK_GUARD_SIZE :: 16 * mem.Kilobyte
CANARY_ENABLED :: true
STACK_CANARY_SIZE :: 64 when CANARY_ENABLED else 0
STACK_CANARY_WORD :: 0xC5C5C5C5C5C5C5C5
MAGIC_NUMBER :: 0x7E3CB1A9

State :: enum {
	Dead      = 0,
	Normal    = 1,
	Running   = 2,
	Suspended = 3,
}

Result :: enum {
	Success              = 0,
	Generic_Error        = 1,
	Invalid_Pointer      = 2,
	Invalid_Coroutine    = 3,
	Not_Suspended        = 4,
	Not_Running          = 5,
	Make_Context_Error   = 6,
	Switch_Context_Error = 7,
	Not_Enough_Space     = 8,
	Out_Of_Memory        = 9,
	Invalid_Arguments    = 10,
	Invalid_Operation    = 11,
	Stack_Overflow       = 12,
}

Func :: proc(co: ^Coro)

ASAN_FIBERS :: .Address in ODIN_SANITIZER_FLAGS

when ASAN_FIBERS {
	@(default_calling_convention = "c")
	foreign {
		__sanitizer_start_switch_fiber :: proc(save: ^rawptr, bottom: rawptr, size: uint) ---
		__sanitizer_finish_switch_fiber :: proc(save: rawptr, bottom_old: ^rawptr, size_old: ^uint) ---
		__asan_handle_no_return :: proc() ---
	}
}

asan_before_longjmp :: #force_inline proc "contextless" () {
	when ASAN_FIBERS {
		__asan_handle_no_return()
	}
}

@(private)
asan_leaving :: #force_inline proc "contextless" (save: ^rawptr, bottom: rawptr, size: uint) {
	when ASAN_FIBERS {
		__sanitizer_start_switch_fiber(save, bottom, size)
	}
}

@(private)
asan_arrived :: #force_inline proc "contextless" (
	save: rawptr,
	bottom_old: ^rawptr,
	size_old: ^uint,
) {
	when ASAN_FIBERS {
		__sanitizer_finish_switch_fiber(save, bottom_old, size_old)
	}
}

Coro :: struct #align (64) {
	state:        State,
	prev_co:      ^Coro,
	magic_number: uint,
	stack_base:   rawptr,
	stack_size:   uint,
	user_data:    rawptr,
	func:         Func,
	mapping_base: rawptr,
	mapping_size: uint,
	canary_base:  rawptr,
	coro_ctx:     Ctx_Buf,
	back_ctx:     Ctx_Buf,
	caller_stack:      rawptr,
	caller_stack_size: uint,
	asan_save_caller:  rawptr,
	asan_save_self:    rawptr,
}

Desc :: struct {
	func:         Func,
	user_data:    rawptr,
	stack_size:   uint,
}

@(thread_local)
current_co: ^Coro

mco_main :: proc "c" (co: ^Coro) {
	asan_arrived(nil, &co.caller_stack, &co.caller_stack_size)
	ctx := runtime.default_context()
	context = ctx
	co.func(co)
	co.state = .Dead
	prepare_jumpout(co)
	asan_leaving(nil, co.caller_stack, co.caller_stack_size)
	mco_switch(&co.coro_ctx, &co.back_ctx)
}

@(optimization_mode = "none")
running :: proc() -> ^Coro {
	return current_co
}

prepare_jumpin :: proc(co: ^Coro) {
	prev_co := running()
	assert(co.prev_co == nil)
	co.prev_co = prev_co
	if prev_co != nil {
		assert(prev_co.state == .Running)
		prev_co.state = .Normal
	}
	current_co = co
}

prepare_jumpout :: proc(co: ^Coro) {
	prev_co := co.prev_co
	co.prev_co = nil
	if prev_co != nil do prev_co.state = .Running
	current_co = prev_co
}

jumpin :: proc(co: ^Coro) {
	prepare_jumpin(co)
	asan_leaving(&co.asan_save_caller, co.stack_base, co.stack_size)
	mco_switch(&co.back_ctx, &co.coro_ctx)
	asan_arrived(co.asan_save_caller, nil, nil)
}

jumpout :: proc(co: ^Coro) {
	prepare_jumpout(co)
	asan_leaving(&co.asan_save_self, co.caller_stack, co.caller_stack_size)
	mco_switch(&co.coro_ctx, &co.back_ctx)
	asan_arrived(co.asan_save_self, &co.caller_stack, &co.caller_stack_size)
}

align_forward :: proc "contextless" (addr: uint, align: uint) -> uint {
	return (addr + (align - 1)) & ~(align - 1)
}

page_align :: proc "contextless" (size: uint) -> uint {
	return align_forward(size, uint(mem.PAGE_SIZE))
}

validate_desc :: proc(desc: ^Desc) -> Result {
	if desc == nil do return .Invalid_Arguments
	if desc.func == nil do return .Invalid_Arguments
	if desc.stack_size < MIN_STACK_SIZE do return .Invalid_Arguments
	return .Success
}


desc_init :: proc(func: Func, stack_size: uint = 0) -> Desc {
	ss := stack_size
	if ss != 0 {
		if ss < MIN_STACK_SIZE do ss = MIN_STACK_SIZE
	} else {
		ss = DEFAULT_STACK_SIZE
	}

	desc: Desc
	desc.func = func
	desc.stack_size = page_align(ss)
	return desc
}

uninit :: proc(co: ^Coro) -> Result {
	if co == nil do return .Invalid_Coroutine
	assert(co.magic_number == MAGIC_NUMBER, "coro header corrupted, stack overflow, stale pointer, or double destroy")
	if !(co.state == .Suspended || co.state == .Dead) do return .Invalid_Operation
	co.state = .Dead
	return .Success
}

header_size :: proc "contextless" () -> uint {
	return align_forward(align_forward(size_of(Coro), 64), 16)
}

region_size :: proc "contextless" (stack_size: uint) -> uint {
	return page_align(STACK_CANARY_SIZE + stack_size + header_size())
}

stack_canary_intact :: proc "contextless" (co: ^Coro) -> bool {
	when CANARY_ENABLED {
		if co == nil || co.canary_base == nil do return true
		words := cast([^]u64)co.canary_base
		for i in 0 ..< STACK_CANARY_SIZE / size_of(u64) {
			if words[i] != STACK_CANARY_WORD do return false
		}
	}
	return true
}

@(private)
init_at :: proc(desc: ^Desc, base: uintptr, region: uint) -> (^Coro, Result) {
	header_at := base + uintptr(region) - uintptr(header_size())

	co := cast(^Coro)header_at
	co^ = {}

	when CANARY_ENABLED {
		canary := cast([^]u64)base
		for i in 0 ..< STACK_CANARY_SIZE / size_of(u64) {
			canary[i] = STACK_CANARY_WORD
		}
	}

	usable_base := rawptr(base + STACK_CANARY_SIZE)
	stack_size := uint(header_at - uintptr(usable_base))

	if res := makectx(co, usable_base, stack_size); res != .Success do return nil, res

	co.canary_base = rawptr(base)
	co.stack_base = usable_base
	co.stack_size = stack_size
	co.state = .Suspended
	co.func = desc.func
	co.user_data = desc.user_data
	co.magic_number = MAGIC_NUMBER
	return co, .Success
}

create :: proc(desc: ^Desc) -> (^Coro, Result) {
	res := validate_desc(desc)
	if res != .Success do return nil, res

	stack_size := page_align(desc.stack_size)
	region := region_size(stack_size)
	mapping_size := STACK_GUARD_SIZE + region

	mapping, reserve_err := vmem.reserve(mapping_size)
	if reserve_err != nil do return nil, .Out_Of_Memory

	base := uintptr(raw_data(mapping))
	region_base := rawptr(base + STACK_GUARD_SIZE)
	if commit_err := vmem.commit(region_base, region); commit_err != nil {
		vmem.release(rawptr(base), mapping_size)
		return nil, .Out_Of_Memory
	}

	co, init_res := init_at(desc, base + STACK_GUARD_SIZE, region)
	if init_res != .Success {
		vmem.release(rawptr(base), mapping_size)
		return nil, init_res
	}

	co.mapping_base = rawptr(base)
	co.mapping_size = mapping_size
	return co, .Success
}

create_in :: proc(desc: ^Desc, region: []byte) -> (^Coro, Result) {
	res := validate_desc(desc)
	if res != .Success do return nil, res

	stack_size := page_align(desc.stack_size)
	needed := region_size(stack_size)
	if uint(len(region)) < needed do return nil, .Not_Enough_Space

	co, init_res := init_at(desc, uintptr(raw_data(region)), needed)
	if init_res != .Success do return nil, init_res

	co.mapping_base = nil
	co.mapping_size = 0
	return co, .Success
}

destroy :: proc(co: ^Coro) -> Result {
	if co == nil do return .Invalid_Coroutine
	if !stack_canary_intact(co) {
		panic("coro stack overflow: the canary below the stack was overwritten")
	}
	res := uninit(co)
	if res != .Success do return res
	if co.mapping_base != nil do vmem.release(co.mapping_base, co.mapping_size)
	return .Success
}

resume :: proc(co: ^Coro) -> Result {
	if co == nil do return .Invalid_Coroutine
	assert(co.magic_number == MAGIC_NUMBER, "coro header corrupted, stack overflow or stale pointer")
	if co.state != .Suspended do return .Not_Suspended
	co.state = .Running
	jumpin(co)
	return .Success
}

resume_top_level :: proc(co: ^Coro) {
	assert(co.magic_number == MAGIC_NUMBER, "coro header corrupted, stack overflow or stale pointer")
	when ODIN_DEBUG {
		assert(co != nil)
		assert(co.state == .Suspended)
		assert(running() == nil)
	}
	co.state = .Running
	current_co = co
	asan_leaving(&co.asan_save_caller, co.stack_base, co.stack_size)
	mco_switch(&co.back_ctx, &co.coro_ctx)
	asan_arrived(co.asan_save_caller, nil, nil)
}


yield :: proc(co: ^Coro) -> Result {
	if co == nil do return .Invalid_Coroutine
	when ODIN_DEBUG {
		dummy: uint
		stack_addr := uint(uintptr(&dummy))
		stack_min := uint(uintptr(co.stack_base))
		stack_max := stack_min + co.stack_size
		if co.magic_number != MAGIC_NUMBER || stack_addr < stack_min || stack_addr > stack_max {
			return .Stack_Overflow
		}
	}
	if co.state != .Running do return .Not_Running
	co.state = .Suspended
	jumpout(co)
	return .Success
}

status :: proc(co: ^Coro) -> State {
	if co != nil do return co.state
	return .Dead
}

get_user_data :: proc(co: ^Coro) -> rawptr {
	if co != nil do return co.user_data
	return nil
}

result_description :: proc(res: Result) -> string {
	switch res {
	case .Success:
		return "No error"
	case .Generic_Error:
		return "Generic error"
	case .Invalid_Pointer:
		return "Invalid pointer"
	case .Invalid_Coroutine:
		return "Invalid coroutine"
	case .Not_Suspended:
		return "Coroutine not suspended"
	case .Not_Running:
		return "Coroutine not running"
	case .Make_Context_Error:
		return "Make context error"
	case .Switch_Context_Error:
		return "Switch context error"
	case .Not_Enough_Space:
		return "Not enough space"
	case .Out_Of_Memory:
		return "Out of memory"
	case .Invalid_Arguments:
		return "Invalid arguments"
	case .Invalid_Operation:
		return "Invalid operation"
	case .Stack_Overflow:
		return "Stack overflow"
	}
	return "Unknown error"
}
