package actod

import "base:runtime"
import "core:sync"
import "core:testing"
_ :: runtime
_ :: sync
_ :: testing

when ODIN_TEST {
	@(private)
	One_Thread_Counted_Allocator :: struct {
		backing:          runtime.Allocator,
		thread_id:        int,
		live_allocations: int,
	}

	@(private)
	stats_test_counter: One_Thread_Counted_Allocator

	@(private)
	one_thread_counted_allocator :: proc(
		counter: ^One_Thread_Counted_Allocator,
	) -> runtime.Allocator {
		return runtime.Allocator {
			procedure = one_thread_counted_allocator_proc,
			data = counter,
		}
	}

	@(private)
	one_thread_counted_allocator_proc :: proc(
		allocator_data: rawptr,
		mode: runtime.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		location := #caller_location,
	) -> (
		[]byte,
		runtime.Allocator_Error,
	) {
		counter := (^One_Thread_Counted_Allocator)(allocator_data)
		result, err := counter.backing.procedure(
			counter.backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			location,
		)
		if err != .None || sync.current_thread_id() != counter.thread_id do return result, err
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			if result != nil do counter.live_allocations += 1
		case .Free:
			if old_memory != nil do counter.live_allocations -= 1
		case .Resize, .Resize_Non_Zeroed:
			if old_memory == nil && result != nil do counter.live_allocations += 1
			if old_memory != nil && size == 0 do counter.live_allocations -= 1
		}
		return result, err
	}

	@(private)
	release_stats_test_recorder :: proc(recorder: ^Traffic_Recorder) {
		if recorder.tally == nil do return
		delete(recorder.tally.counts)
		free(recorder.tally, recorder.allocator)
	}

	@(test)
	stats_maps_are_freed_when_the_observer_cannot_take_the_response_test :: proc(
		t: ^testing.T,
	) {
		sync.lock(&global_registry_swap_mutex)
		defer sync.unlock(&global_registry_swap_mutex)

		saved_registry := NODE.actor_registry
		test_registry := make_test_registry()
		NODE.actor_registry = test_registry^
		defer {
			NODE.actor_registry = saved_registry
			free(test_registry)
		}

		saved_system_allocator := actor_system_allocator
		stats_test_counter = One_Thread_Counted_Allocator {
			backing   = runtime.heap_allocator(),
			thread_id = sync.current_thread_id(),
		}
		actor_system_allocator = one_thread_counted_allocator(
			&stats_test_counter,
		)
		defer actor_system_allocator = saved_system_allocator

		observer := new(Actor)
		defer free(observer)
		observer.state = .STOPPING
		observer_pid, added := add(
			&NODE.actor_registry,
			rawptr(observer),
			"stopping_observer",
		)
		if !testing.expect(t, added, "the observer should register") do return
		defer remove(&NODE.actor_registry, observer_pid)

		reporter := new(Actor)
		defer free(reporter)
		reporter.state = .RUNNING
		reporter.pid = pack_pid(Handle{idx = 7, gen = 1})

		reporter_context: Actor_Context
		reporter_context.pid = reporter.pid
		reporter_context.stats.received = Traffic_Recorder {
			allocator = runtime.heap_allocator(),
		}
		reporter_context.stats.sent = Traffic_Recorder {
			allocator = runtime.heap_allocator(),
		}
		defer release_stats_test_recorder(&reporter_context.stats.received)
		defer release_stats_test_recorder(&reporter_context.stats.sent)
		record_traffic(&reporter_context.stats.received, PID(11))
		record_traffic(&reporter_context.stats.received, PID(12))
		record_traffic(&reporter_context.stats.received, PID(11))
		record_traffic(&reporter_context.stats.sent, PID(13))
		record_traffic(&reporter_context.stats.sent, PID(14))

		saved_context := current_actor_context
		current_actor_context = &reporter_context
		defer current_actor_context = saved_context

		handle_get_stats_request(reporter, Get_Stats{requester = observer_pid})

		testing.expectf(
			t,
			stats_test_counter.live_allocations == 0,
			"a stats response the observer refused left %d system heap allocations live",
			stats_test_counter.live_allocations,
		)
	}
}
