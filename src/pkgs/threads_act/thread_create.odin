#+build linux, darwin, freebsd, openbsd, netbsd
package threads_act

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:sys/posix"
import "core:thread"

@(private)
actor_thread_entry :: proc "c" (t_raw: rawptr) -> rawptr {
	t := cast(^thread.Thread)t_raw
	t.id = sync.current_thread_id()

	for (.Started not_in sync.atomic_load(&t.flags)) {
		sync.wait(&t.start_ok)
	}

	context = runtime.default_context()
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}

	t.procedure(t)

	intrinsics.atomic_or(&t.flags, {.Done})
	return nil
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
	t.procedure = thread_proc
	t.data = rawptr(fn)
	t.user_index = 1
	t.user_args[0] = data

	attrs: posix.pthread_attr_t
	posix.pthread_attr_init(&attrs)
	defer posix.pthread_attr_destroy(&attrs)

	if stack_size > 0 {
		posix.pthread_attr_setstacksize(&attrs, stack_size)
	}

	posix.pthread_attr_setdetachstate(&attrs, .CREATE_JOINABLE)
	posix.pthread_create(&t.unix_thread, &attrs, actor_thread_entry, t)

	intrinsics.atomic_or(&t.flags, {.Started})
	sync.post(&t.start_ok)

	return t
}
