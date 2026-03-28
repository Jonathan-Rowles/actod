package benchmark

import "../../src/actod"
import "../shared"
import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:time"

Start_Benchmark_Send :: struct {}

@(init)
register_benchmark_messages :: proc "contextless" () {
	actod.register_message_type(Start_Benchmark_Send)
}

global_benchmark_state: shared.Benchmark_State

Benchmark_Sender_Data :: struct {
	targets:          []actod.PID,
	messages_to_send: int,
	warmup_messages:  int,
	sender_id:        int,
	dedicated:        bool,
	done_sema:        ^sync.Sema,
	warmup_sema:      ^sync.Sema,
	state:            ^shared.Benchmark_State,
}

create_benchmark_behaviour :: proc(
	$T: typeid,
) -> actod.Actor_Behaviour(shared.Benchmark_Actor_Data) {
	return actod.Actor_Behaviour(shared.Benchmark_Actor_Data) {
		handle_message = proc(data: ^shared.Benchmark_Actor_Data, from: actod.PID, msg: any) {
			data.message_count += 1
			if data.message_count & 0xFF == 0 {
				sync.atomic_add(&global_benchmark_state.receive_count, 256)
			}

			if data.message_count == 10_000_000 {
				remaining := data.message_count & 0xFF
				if remaining > 0 {
					sync.atomic_add(&global_benchmark_state.receive_count, remaining)
				}
			}
		},
		init = proc(data: ^shared.Benchmark_Actor_Data) {
			data.message_count = 0
			data.start_time = time.now()
		},
	}
}

create_sender_behaviour :: proc($T: typeid) -> actod.Actor_Behaviour(Benchmark_Sender_Data) {
	return actod.Actor_Behaviour(Benchmark_Sender_Data) {
		handle_message = proc(data: ^Benchmark_Sender_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case Start_Benchmark_Send:
				for i in 0 ..< data.warmup_messages {
					v: T
					when size_of(T) >= 8 {
						(cast(^u64)&v)^ = u64(i)
					}
					target: actod.PID
					if data.dedicated {
						target = data.targets[data.sender_id % len(data.targets)]
					} else {
						target = data.targets[i % len(data.targets)]
					}
					err := actod.send_message(target, v)
					if err != .OK {
						shared.track_send_error(data.state, err)
					}
				}

				sync.sema_post(data.warmup_sema)

				local_count: u64 = 0
				for i in 0 ..< data.messages_to_send {
					v: T
					when T == shared.Inline_Message_string {
						v.data = "test"
					} else when size_of(T) >= 8 {
						(cast(^u64)&v)^ = u64(i)
					}
					target: actod.PID
					if data.dedicated {
						target = data.targets[data.sender_id % len(data.targets)]
					} else {
						target = data.targets[i % len(data.targets)]
					}
					err := actod.send_message(target, v)
					if err == .OK {
						local_count += 1
					} else {
						shared.track_send_error(data.state, err)
					}
				}

				sync.atomic_add(&data.state.send_count, local_count)
				sync.sema_post(data.done_sema)
			}
		},
		init = proc(data: ^Benchmark_Sender_Data) {},
	}
}

run_benchmark :: proc($T: typeid, config: shared.Benchmark_Config) -> shared.Benchmark_Result {
	sync.atomic_store(&global_benchmark_state.send_count, 0)
	sync.atomic_store(&global_benchmark_state.receive_count, 0)
	sync.atomic_store(&global_benchmark_state.send_failures, 0)
	sync.atomic_store(&global_benchmark_state.retry_count, 0)
	sync.atomic_store(&global_benchmark_state.err_actor_not_found, 0)
	sync.atomic_store(&global_benchmark_state.err_mailbox_full, 0)
	sync.atomic_store(&global_benchmark_state.err_pool_full, 0)
	sync.atomic_store(&global_benchmark_state.err_system_shutting_down, 0)
	sync.atomic_store(&global_benchmark_state.err_network, 0)
	sync.atomic_store(&global_benchmark_state.err_other, 0)

	wc := config.worker_count if config.worker_count > 0 else 0

	actod.NODE_INIT(
		name = "bench",
		opts = actod.make_node_config(
			worker_count = wc,
			actor_config = actod.make_actor_config(
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(enable_file = false, level = .Error),
				spin_strategy = actod.SPIN_STRATEGY.CPU_RELAX,
			),
		),
	)

	actors := make([]actod.PID, config.actor_count)
	senders := make([]actod.PID, config.sender_count)
	defer delete(actors)
	defer delete(senders)

	receiver_behaviour := create_benchmark_behaviour(T)

	for i in 0 ..< config.actor_count {
		hw := i if config.same_worker else -1
		actor_config := actod.make_actor_config(
			logging = actod.make_log_config(enable_file = false, level = .Error),
			home_worker = hw,
		)
		name := fmt.tprintf("recv-%d", i)
		data := shared.Benchmark_Actor_Data{id = i}
		pid, ok := actod.spawn(name, data, receiver_behaviour, actor_config)
		if !ok do panic("Failed to spawn receiver")
		actors[i] = pid
	}

	done_sema: sync.Sema
	warmup_sema: sync.Sema

	messages_per_sender := config.message_count / config.sender_count
	warmup_per_sender := config.warmup_messages / config.sender_count

	sender_behaviour := create_sender_behaviour(T)

	for i in 0 ..< config.sender_count {
		target_actor := actors[i % config.actor_count]
		aff: actod.Actor_Ref = actod.Actor_Ref(target_actor) if config.same_worker else nil
		stack_size := max(mem.Kilobyte * 56, size_of(T) * 4)
		actor_config := actod.make_actor_config(
			logging = actod.make_log_config(enable_file = false, level = .Error),
			coro_stack_size = stack_size,
			affinity = aff,
		)
		name := fmt.tprintf("send-%d", i)
		sender_data := Benchmark_Sender_Data {
			targets          = actors,
			messages_to_send = messages_per_sender,
			warmup_messages  = warmup_per_sender,
			sender_id        = i,
			dedicated        = config.dedicated,
			done_sema        = &done_sema,
			warmup_sema      = &warmup_sema,
			state            = &global_benchmark_state,
		}
		pid, ok := actod.spawn(name, sender_data, sender_behaviour, actor_config)
		if !ok do panic("Failed to spawn sender")
		senders[i] = pid
	}

	time.sleep(5 * time.Millisecond)

	for i in 0 ..< config.sender_count {
		actod.send_message(senders[i], Start_Benchmark_Send{})
	}

	for _ in 0 ..< config.sender_count {
		sync.sema_wait(&warmup_sema)
	}

	start := time.now()

	for _ in 0 ..< config.sender_count {
		sync.sema_wait(&done_sema)
	}

	// Wait for receivers to catch up
	wait_start := time.now()
	for {
		sent := sync.atomic_load(&global_benchmark_state.send_count)
		received := sync.atomic_load(&global_benchmark_state.receive_count)
		if received >= sent || time.since(wait_start) > 100 * time.Millisecond {
			break
		}
		intrinsics.cpu_relax()
	}

	elapsed := time.since(start)

	final_sent := sync.atomic_load(&global_benchmark_state.send_count)
	final_received := sync.atomic_load(&global_benchmark_state.receive_count)

	for pid in actors {
		actod.terminate_actor(pid)
	}
	for pid in senders {
		actod.terminate_actor(pid)
	}

	time.sleep(50 * time.Millisecond)

	wait_for_actors_cleanup()
	actod.SHUTDOWN_NODE()

	duration_sec := time.duration_seconds(elapsed)
	throughput := f64(final_received) / duration_sec
	bandwidth := (f64(final_received) * f64(size_of(T))) / (1024 * 1024) / duration_sec
	latency_ns := (duration_sec * 1e9) / f64(final_received)

	return shared.Benchmark_Result {
		config              = config,
		duration            = elapsed,
		messages_sent       = final_sent,
		messages_received   = final_received,
		throughput          = throughput,
		bandwidth           = bandwidth,
		latency_ns          = latency_ns,
		err_actor_not_found = sync.atomic_load(&global_benchmark_state.err_actor_not_found),
		err_mailbox_full    = sync.atomic_load(&global_benchmark_state.err_mailbox_full),
		err_pool_full       = sync.atomic_load(&global_benchmark_state.err_pool_full),
		err_system_shutting_down = sync.atomic_load(&global_benchmark_state.err_system_shutting_down),
		err_network         = sync.atomic_load(&global_benchmark_state.err_network),
		err_other           = sync.atomic_load(&global_benchmark_state.err_other),
	}
}

wait_for_actors_cleanup :: proc() {
	max_wait := 50
	for attempt in 0 ..< max_wait {
		total := actod.num_used(&actod.global_registry)
		if total <= 3 do break
		time.sleep(100 * time.Millisecond)
		if attempt == max_wait - 1 {
			fmt.printf("WARNING: %d actors still active\n", total - 3)
		}
	}
}
