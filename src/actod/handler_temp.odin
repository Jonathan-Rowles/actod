package actod

import "base:intrinsics"
import "base:runtime"

@(private)
Temp_Mark :: struct {
	arena:      ^runtime.Arena,
	block:      ^runtime.Memory_Block,
	used:       uint,
	total_used: uint,
}

@(private, thread_local)
handlers_running_on_this_thread: int

@(private, thread_local)
temp_before_handlers: Temp_Mark

@(private)
handler_temp_begin :: #force_inline proc(actor_ctx: ^Actor_Context) {
	if handlers_running_on_this_thread == 0 {
		temp_before_handlers = temp_arena_mark(
			&runtime.global_default_temp_allocator_data.arena,
		)
	}
	handlers_running_on_this_thread += 1
	if actor_ctx != nil do actor_ctx.handlers_running += 1
}

@(private)
handler_temp_end :: #force_inline proc(actor_ctx: ^Actor_Context) {
	if actor_ctx != nil do actor_ctx.handlers_running -= 1
	handlers_running_on_this_thread -= 1
	if handlers_running_on_this_thread == 0 do rewind_temp_arena(temp_before_handlers)
}

@(private)
handler_temp_abandon :: proc(actor_ctx: ^Actor_Context) {
	if actor_ctx.handlers_running == 0 do return
	handlers_running_on_this_thread -= actor_ctx.handlers_running
	actor_ctx.handlers_running = 0
	if handlers_running_on_this_thread == 0 do rewind_temp_arena(temp_before_handlers)
}

@(private)
temp_arena_mark :: #force_inline proc(arena: ^runtime.Arena) -> Temp_Mark {
	mark := Temp_Mark {
		arena      = arena,
		block      = arena.curr_block,
		total_used = arena.total_used,
	}
	if arena.curr_block != nil do mark.used = arena.curr_block.used
	return mark
}

@(private)
rewind_temp_arena :: #force_inline proc(mark: Temp_Mark) {
	arena := mark.arena
	if arena.curr_block == mark.block &&
	   (mark.block == nil || mark.block.used == mark.used) {
		return
	}
	rewind_temp_arena_to_mark(mark)
}

@(private)
rewind_temp_arena_to_mark :: #force_no_inline proc(mark: Temp_Mark) {
	arena := mark.arena
	if mark.block == nil {
		runtime.arena_free_all(arena)
		return
	}
	if !arena_holds_block(arena, mark.block) do return
	if mark.block.used < mark.used do return
	for arena.curr_block != mark.block do runtime.arena_free_last_memory_block(arena)
	block := arena.curr_block
	intrinsics.mem_zero(&block.base[mark.used], int(block.used - mark.used))
	block.used = mark.used
	arena.total_used = mark.total_used
}

@(private)
arena_holds_block :: proc(
	arena: ^runtime.Arena,
	wanted: ^runtime.Memory_Block,
) -> bool {
	for block := arena.curr_block; block != nil; block = block.prev {
		if block == wanted do return true
	}
	return false
}
