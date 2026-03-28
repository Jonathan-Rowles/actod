package coro

import "base:runtime"
import "core:mem"

MIN_STACK_SIZE :: 16 * mem.Kilobyte
DEFAULT_STORAGE_SIZE :: 1024
DEFAULT_STACK_SIZE :: 56 * 1024
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
	coro_size:    uint,
	coro_ctx:     Ctx_Buf,
	back_ctx:     Ctx_Buf,
	allocator:    mem.Allocator,
	storage:      [^]u8,
	bytes_stored: uint,
	storage_size: uint,
}

Desc :: struct {
	func:         Func,
	user_data:    rawptr,
	allocator:    mem.Allocator,
	storage_size: uint,
	coro_size:    uint,
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

create_context :: proc(co: ^Coro, desc: ^Desc) -> Result {
	co_addr := uint(uintptr(co))
	storage_addr := align_forward(co_addr + size_of(Coro), 16)
	stack_addr := align_forward(storage_addr + desc.storage_size, 16)

	storage := cast([^]u8)uintptr(storage_addr)
	stack_base := rawptr(uintptr(stack_addr))
	stack_size := desc.stack_size

	res := makectx(co, stack_base, stack_size)
	if res != .Success {
		return res
	}

	co.stack_base = stack_base
	co.stack_size = stack_size
	co.storage = storage
	co.storage_size = desc.storage_size
	return .Success
}

init_desc_sizes :: proc(desc: ^Desc, stack_size: uint) {
	desc.coro_size =
		align_forward(size_of(Coro), 16) + align_forward(desc.storage_size, 16) + stack_size + 16
	desc.stack_size = stack_size
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
	if desc.coro_size < size_of(Coro) {
		return .Invalid_Arguments
	}
	return .Success
}


desc_init :: proc(func: Func, stack_size: uint = 0, allocator := context.allocator) -> Desc {
	ss := stack_size
	if ss != 0 {
		if ss < MIN_STACK_SIZE {
			ss = MIN_STACK_SIZE
		}
	} else {
		ss = DEFAULT_STACK_SIZE
	}
	ss = align_forward(ss, 16)

	desc: Desc
	desc.func = func
	desc.storage_size = DEFAULT_STORAGE_SIZE
	desc.allocator = allocator
	init_desc_sizes(&desc, ss)
	return desc
}

init :: proc(co: ^Coro, desc: ^Desc) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	co^ = {}

	res := validate_desc(desc)
	if res != .Success {
		return res
	}

	res = create_context(co, desc)
	if res != .Success {
		return res
	}

	co.state = .Suspended
	co.coro_size = desc.coro_size
	co.allocator = desc.allocator
	co.func = desc.func
	co.user_data = desc.user_data
	co.magic_number = MAGIC_NUMBER
	return .Success
}

uninit :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	if !(co.state == .Suspended || co.state == .Dead) {
		return .Invalid_Operation
	}
	co.state = .Dead
	return .Success
}

create :: proc(desc: ^Desc) -> (^Coro, Result) {
	if desc == nil {
		return nil, .Invalid_Arguments
	}

	alloc_size := int(desc.coro_size)
	ptr, err := mem.alloc(alloc_size, 64, desc.allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}

	co := cast(^Coro)ptr
	res := init(co, desc)
	if res != .Success {
		mem.free(ptr, desc.allocator)
		return nil, res
	}
	return co, .Success
}

destroy :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	res := uninit(co)
	if res != .Success {
		return res
	}
	allocator := co.allocator
	mem.free(co, allocator)
	return .Success
}

resume :: proc(co: ^Coro) -> Result {
	if co == nil {
		return .Invalid_Coroutine
	}
	if co.state != .Suspended {
		return .Not_Suspended
	}
	co.state = .Running
	jumpin(co)
	return .Success
}

resume_top_level :: proc(co: ^Coro) {
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
