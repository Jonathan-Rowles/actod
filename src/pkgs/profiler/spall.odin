package prof

import "core:prof/spall"

ENABLE_PROFILING :: false
BUFFER_SIZE :: spall.BUFFER_DEFAULT_SIZE

ctx: spall.Context
initialized: bool

@(thread_local)
buffer: spall.Buffer
@(thread_local)
buffer_backing: []u8
@(thread_local)
thread_initialized: bool

init :: proc(filename: string = "trace.spall") {
	when ENABLE_PROFILING {
		if initialized {
			return
		}

		ctx = spall.context_create(filename)
		initialized = true

		init_thread()
	}
}

cleanup :: proc() {
	when ENABLE_PROFILING {
		if !initialized {
			return
		}

		cleanup_thread()

		spall.context_destroy(&ctx)
		initialized = false
	}
}

init_thread :: proc() {
	when ENABLE_PROFILING {
		if !initialized || thread_initialized {
			return
		}

		buffer_backing = make([]u8, BUFFER_SIZE)
		buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
		thread_initialized = true
	}
}

cleanup_thread :: proc() {
	when ENABLE_PROFILING {
		if !thread_initialized {
			return
		}

		spall.buffer_destroy(&ctx, &buffer)
		delete(buffer_backing)
		thread_initialized = false
	}
}

begin :: proc(name: string, loc := #caller_location) {
	when ENABLE_PROFILING {
		if initialized && thread_initialized {
			spall._buffer_begin(&ctx, &buffer, name, "", loc)
		}
	}
}

end :: proc() {
	when ENABLE_PROFILING {
		if initialized && thread_initialized {
			spall._buffer_end(&ctx, &buffer)
		}
	}
}

@(deferred_out = end)
scoped :: proc(name: string, loc := #caller_location) {
	begin(name, loc)
}

get_context :: proc() -> ^spall.Context {
	when ENABLE_PROFILING {
		if initialized {
			return &ctx
		}
	}
	return nil
}

is_initialized :: proc() -> bool {
	return initialized when ENABLE_PROFILING else false
}

is_thread_initialized :: proc() -> bool {
	return thread_initialized when ENABLE_PROFILING else false
}
