package coro

import "base:runtime"
import "core:mem"
import vmem "core:mem/virtual"

MIN_STACK_SIZE :: 16 * mem.Kilobyte
DEFAULT_STORAGE_SIZE :: 1024
DEFAULT_STACK_SIZE :: 56 * 1024
STACK_GUARD_SIZE :: 16 * mem.Kilobyte
STACK_CANARY_SIZE :: 64
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

Coro :: struct #align (64) {
	state:        State,
	prev_co:      ^Coro,
	magic_number: uint, // yield stack-overflow check (debug only)
	stack_base:   rawptr, // yield stack-overflow check (debug only)
	stack_size:   uint, // yield stack-overflow check (debug only)
	user_data:    rawptr,
	func:         Func,
	mapping_base: rawptr,
	mapping_size: uint,
	canary_base:  rawptr,
	coro_ctx:     Ctx_Buf,
	back_ctx:     Ctx_Buf,
	storage:      [^]u8,
	bytes_stored: uint,
	storage_size: uint,
}

Desc :: struct {
	func:         Func,
	user_data:    rawptr,
	storage_size: uint,
	stack_size:   uint,
}

@(thread_local)
current_co: ^Coro

mco_main :: proc "c" (co: ^Coro) {
	ctx := runtime.default_context()
	context = ctx
	co.func(co)
	co.state = .Dead
	jumpout(co)
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
	if prev_co != nil {
		prev_co.state = .Running
	}
	current_co = prev_co
}

jumpin :: proc(co: ^Coro) {
	prepare_jumpin(co)
	mco_switch(&co.back_ctx, &co.coro_ctx)
}

jumpout :: proc(co: ^Coro) {
	prepare_jumpout(co)
	mco_switch(&co.coro_ctx, &co.back_ctx)
}

align_forward :: proc "contextless" (addr: uint, align: uint) -> uint {
	return (addr + (align - 1)) & ~(align - 1)
}

page_align :: proc "contextless" (size: uint) -> uint {
	return align_forward(size, uint(mem.PAGE_SIZE))
}

validate_desc :: proc(desc: ^Desc) -> Result {
	if desc == nil {
		return .Invalid_Arguments
	}
	if desc.func == nil {
		return .Invalid_Arguments
	}
	if desc.stack_size < MIN_STACK_SIZE {
		return .Invalid_Arguments
	}
	return .Success
}


desc_init :: proc(func: Func, stack_size: uint = 0) -> Desc {
	ss := stack_size
	if ss != 0 {
		if ss < MIN_STACK_SIZE {
			ss = MIN_STACK_SIZE
		}
	} else {
		ss = DEFAULT_STACK_SIZE
	}

	desc: Desc
	desc.func = func
	desc.storage_size = DEFAULT_STORAGE_SIZE
	desc.stack_size = page_align(ss)
	return desc
}

uninit :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	assert(co.magic_number == MAGIC_NUMBER, "coro header corrupted, stack overflow, stale pointer, or double destroy")
	if !(co.state == .Suspended || co.state == .Dead) {
		return .Invalid_Operation
	}
	co.state = .Dead
	return .Success
}

header_size :: proc "contextless" (storage_size: uint) -> uint {
	return page_align(
		align_forward(size_of(Coro), 64) + align_forward(storage_size, 16) + STACK_CANARY_SIZE,
	)
}

region_size :: proc "contextless" (stack_size: uint, storage_size: uint) -> uint {
	return header_size(storage_size) + page_align(stack_size)
}

stack_canary_intact :: proc "contextless" (co: ^Coro) -> bool {
	if co == nil || co.canary_base == nil {
		return true
	}
	words := cast([^]u64)co.canary_base
	for i in 0 ..< STACK_CANARY_SIZE / size_of(u64) {
		if words[i] != STACK_CANARY_WORD {
			return false
		}
	}
	return true
}

@(private)
init_at :: proc(desc: ^Desc, base: uintptr, stack_size: uint, storage_size: uint) -> (^Coro, Result) {
	header := header_size(storage_size)

	co := cast(^Coro)base
	co^ = {}

	canary_at := base + uintptr(header) - STACK_CANARY_SIZE
	canary := cast([^]u64)canary_at
	for i in 0 ..< STACK_CANARY_SIZE / size_of(u64) {
		canary[i] = STACK_CANARY_WORD
	}

	usable_base := rawptr(base + uintptr(header))

	if res := makectx(co, usable_base, stack_size); res != .Success {
		return nil, res
	}

	co.canary_base = rawptr(canary_at)
	co.stack_base = usable_base
	co.stack_size = stack_size
	co.storage = cast([^]u8)(uintptr(co) + uintptr(align_forward(size_of(Coro), 64)))
	co.storage_size = storage_size
	co.state = .Suspended
	co.func = desc.func
	co.user_data = desc.user_data
	co.magic_number = MAGIC_NUMBER
	return co, .Success
}

create :: proc(desc: ^Desc) -> (^Coro, Result) {
	res := validate_desc(desc)
	if res != .Success {
		return nil, res
	}

	stack_size := page_align(desc.stack_size)
	region := region_size(stack_size, desc.storage_size)
	mapping_size := STACK_GUARD_SIZE + region

	mapping, reserve_err := vmem.reserve(mapping_size)
	if reserve_err != nil {
		return nil, .Out_Of_Memory
	}

	base := uintptr(raw_data(mapping))
	region_base := rawptr(base + STACK_GUARD_SIZE)
	if commit_err := vmem.commit(region_base, region); commit_err != nil {
		vmem.release(rawptr(base), mapping_size)
		return nil, .Out_Of_Memory
	}

	co, init_res := init_at(desc, base + STACK_GUARD_SIZE, stack_size, desc.storage_size)
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
	if res != .Success {
		return nil, res
	}

	stack_size := page_align(desc.stack_size)
	if uint(len(region)) < region_size(stack_size, desc.storage_size) {
		return nil, .Not_Enough_Space
	}

	co, init_res := init_at(desc, uintptr(raw_data(region)), stack_size, desc.storage_size)
	if init_res != .Success {
		return nil, init_res
	}

	co.mapping_base = nil
	co.mapping_size = 0
	return co, .Success
}

destroy :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	if !stack_canary_intact(co) {
		panic("coro stack overflow: the canary below the stack was overwritten")
	}
	res := uninit(co)
	if res != .Success {
		return res
	}
	if co.mapping_base != nil {
		vmem.release(co.mapping_base, co.mapping_size)
	}
	return .Success
}

resume :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	assert(co.magic_number == MAGIC_NUMBER, "coro header corrupted, stack overflow or stale pointer")
	if co.state != .Suspended {
		return .Not_Suspended
	}
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
	mco_switch(&co.back_ctx, &co.coro_ctx)
}


yield :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	when ODIN_DEBUG {
		dummy: uint
		stack_addr := uint(uintptr(&dummy))
		stack_min := uint(uintptr(co.stack_base))
		stack_max := stack_min + co.stack_size
		if co.magic_number != MAGIC_NUMBER || stack_addr < stack_min || stack_addr > stack_max {
			return .Stack_Overflow
		}
	}
	if co.state != .Running {
		return .Not_Running
	}
	co.state = .Suspended
	jumpout(co)
	return .Success
}

// Fast yield for worker-pool coros resumed via resume_top_level.
// Skips nil check, state validation, prev_co tracking, and Result return.
yield_top_level :: proc(co: ^Coro) {
	if !stack_canary_intact(co) {
		panic("coro stack overflow: the canary below the stack was overwritten")
	}
	assert(co.magic_number == MAGIC_NUMBER, "coro header corrupted, stack overflow or stale pointer")
	when ODIN_DEBUG {
		assert(co != nil)
		assert(co.state == .Running)
		dummy: uint
		stack_addr := uint(uintptr(&dummy))
		stack_min := uint(uintptr(co.stack_base))
		stack_max := stack_min + co.stack_size
		assert(
			co.magic_number == MAGIC_NUMBER && stack_addr >= stack_min && stack_addr <= stack_max,
		)
	}
	co.state = .Suspended
	current_co = nil
	mco_switch(&co.coro_ctx, &co.back_ctx)
}

status :: proc(co: ^Coro) -> State {
	if co != nil {
		return co.state
	}
	return .Dead
}

get_user_data :: proc(co: ^Coro) -> rawptr {
	if co != nil {
		return co.user_data
	}
	return nil
}

push :: proc(co: ^Coro, src: rawptr, len: uint) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	if len > 0 {
		bytes_stored := co.bytes_stored + len
		if bytes_stored > co.storage_size {
			return .Not_Enough_Space
		}
		if src == nil {
			return .Invalid_Pointer
		}
		mem.copy(&co.storage[co.bytes_stored], src, int(len))
		co.bytes_stored = bytes_stored
	}
	return .Success
}

pop :: proc(co: ^Coro, dest: rawptr, len: uint) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	if len > 0 {
		if len > co.bytes_stored {
			return .Not_Enough_Space
		}
		bytes_stored := co.bytes_stored - len
		if dest != nil {
			mem.copy(dest, &co.storage[bytes_stored], int(len))
		}
		co.bytes_stored = bytes_stored
	}
	return .Success
}

peek :: proc(co: ^Coro, dest: rawptr, len: uint) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	if len > 0 {
		if len > co.bytes_stored {
			return .Not_Enough_Space
		}
		if dest == nil {
			return .Invalid_Pointer
		}
		mem.copy(dest, &co.storage[co.bytes_stored - len], int(len))
	}
	return .Success
}

get_bytes_stored :: proc(co: ^Coro) -> uint {
	if co == nil {
		return 0
	}
	return co.bytes_stored
}

get_storage_size :: proc(co: ^Coro) -> uint {
	if co == nil {
		return 0
	}
	return co.storage_size
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
