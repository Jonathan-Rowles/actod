#+build windows
package threads_act

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import win32 "core:sys/windows"
import "core:thread"

@(private)
actor_thread_entry_win :: proc "system" (t_raw: rawptr) -> win32.DWORD {
	t := cast(^thread.Thread)t_raw

	for (.Started not_in sync.atomic_load(&t.flags)) {
		sync.wait(&t.start_ok)
	}

	context = runtime.default_context()
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}

	t.procedure(t)

	intrinsics.atomic_or(&t.flags, {.Done})
	return 0
}

create_thread_with_stack_size :: proc(
	data: rawptr,
	fn: proc(data: rawptr),
	stack_size: uint,
) -> ^thread.Thread {
	thread_proc :: proc(t: ^thread.Thread) {
		fn := cast(proc(_: rawptr))t.data
		assert(t.user_index >= 1)
		fn(t.user_args[0])
	}

	t := new(thread.Thread)
	t.creation_allocator = context.allocator

	win32_thread_id: win32.DWORD
	t.win32_thread = win32.CreateThread(
		nil,
		stack_size,
		actor_thread_entry_win,
		t,
		win32.CREATE_SUSPENDED,
		&win32_thread_id,
	)

	if t.win32_thread == nil {
		free(t)
		return nil
	}

	t.procedure = thread_proc
	t.data = rawptr(fn)
	t.user_index = 1
	t.user_args[0] = data
	t.win32_thread_id = win32_thread_id
	t.id = int(win32_thread_id)

	t.flags += {.Started}
	win32.ResumeThread(t.win32_thread)

	return t
}
