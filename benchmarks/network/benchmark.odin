package network_benchmark

import "../../src/actod"
import "../shared"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

Test_Status :: struct {
	test_id:        int,
	config:         shared.Scaling_Config,
	ready:          bool,
	stats_received: bool,
	stats:          shared.Stats_Report_Message,
}

MAX_CACHED_PIDS :: 256
PID_Cache :: struct {
	pids:           [MAX_CACHED_PIDS]actod.PID,
	count:          int,
	responses_recv: int,
}

global_test_status: Test_Status
global_send_state: shared.Benchmark_State
global_pid_cache: PID_Cache
global_coordinator_pid: actod.PID

Request_PIDs_Message :: struct {
	actor_count: int,
	type_name:   string,
}

@(init)
register_sender_messages :: proc "contextless" () {
	actod.register_message_type(Request_PIDs_Message)
}

generate_network_scaling_configs :: proc(cpu_count: int) -> []shared.Scaling_Config {
	configs := make([dynamic]shared.Scaling_Config)

	base_messages := 1_000_000

	test_sizes := []shared.Message_Size{.INLINE, .Empty, .MEDIUM, .LARGE}

	for size in test_sizes {
		append(
			&configs,
			shared.Scaling_Config {
				actor_count = 1,
				sender_count = 1,
				message_count = base_messages,
				message_size = size,
				description = fmt.tprintf("1:1 %s", shared.size_name(size)),
				category = .BASELINE,
				dedicated = true,
			},
		)
	}

	for n in ([]int{2, 4}) {
		if n * 2 <= cpu_count {
			for size in test_sizes {
				append(
					&configs,
					shared.Scaling_Config {
						actor_count = n,
						sender_count = n,
						message_count = n * base_messages,
						message_size = size,
						description = fmt.tprintf("%dx %s", n, shared.size_name(size)),
						category = .PARALLEL,
						dedicated = true,
					},
				)
			}
		}
	}

	return configs[:]
}

create_sender_coordinator_behaviour :: proc() -> actod.Actor_Behaviour(int) {
	return actod.Actor_Behaviour(int) {
		handle_message = proc(data: ^int, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Ready_Message:
				if m.test_id == global_test_status.test_id {
					global_test_status.ready = true
				}
			case shared.Get_PID_Response:
				if m.request_id >= 0 && m.request_id < MAX_CACHED_PIDS {
					global_pid_cache.pids[m.request_id] = from
					sync.atomic_add(&global_pid_cache.responses_recv, 1)
				}
			case Request_PIDs_Message:
				req := shared.Get_PID_Request {
					actor_name = m.type_name,
					request_id = m.actor_count,
				}
				actod.send_remote_by_name("BenchmarkReceiver", m.type_name, req)
			}
		},
	}
}

create_sender_stats_behaviour :: proc() -> actod.Actor_Behaviour(int) {
	return actod.Actor_Behaviour(int) {
		handle_message = proc(data: ^int, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Stats_Report_Message:
				if m.test_id == global_test_status.test_id {
					global_test_status.stats = m
					global_test_status.stats_received = true
				}
			}
		},
	}
}

network_sender_worker :: proc($T: typeid) -> proc(_: rawptr) {
	return proc(data: rawptr) {
			work_data := cast(^struct {
				actor_count:      int,
				messages_to_send: int,
				warmup_messages:  int,
				sender_id:        int,
				dedicated:        bool,
			})data

			for i in 0 ..< work_data.warmup_messages {
				msg: T
				when T == shared.Inline_Message_string {
					msg.data = "test"
				} else when size_of(T) >= 8 {
					(cast(^u64)&msg)^ = u64(i)
				}

				actor_id := i % work_data.actor_count
				target_pid := global_pid_cache.pids[actor_id]

				err := actod.send_message(target_pid, msg)
				if err != .OK {
					shared.track_send_error(&global_send_state, err)
				}
			}

			for i in 0 ..< work_data.messages_to_send {
				msg: T
				when T == shared.Inline_Message_string {
					msg.data = "test"
				} else when size_of(T) >= 8 {
					(cast(^u64)&msg)^ = u64(i + work_data.warmup_messages)
				}

				actor_id: int
				if work_data.dedicated {
					actor_id = work_data.sender_id % work_data.actor_count
				} else {
					actor_id = i % work_data.actor_count
				}

				target_pid := global_pid_cache.pids[actor_id]

				err := actod.send_message(target_pid, msg)
				if err == .OK {
					sync.atomic_add(&global_send_state.send_count, 1)
				} else {
					shared.track_send_error(&global_send_state, err)
					sync.atomic_add(&global_send_state.send_failures, 1)
				}
			}
		}
}

run_network_benchmark :: proc(
	$T: typeid,
	config: shared.Scaling_Config,
	test_id: int,
) -> shared.Benchmark_Result {
	global_send_state = {}
	global_test_status.ready = false
	global_test_status.stats_received = false
	global_test_status.test_id = test_id
	global_test_status.config = config

	start_msg := shared.Start_Test_Message {
		test_id       = test_id,
		message_size  = config.message_size,
		message_count = config.message_count,
		actor_count   = config.actor_count,
		sender_count  = config.sender_count,
		warmup_count  = 10_000,
		test_category = config.category,
		dedicated     = config.dedicated,
	}

	global_pid_cache = {}
	global_pid_cache.count = config.actor_count

	err := actod.send_remote_by_name("BenchmarkReceiver", "TestCoordinator", start_msg)
	if err != .OK {
		fmt.printf("Failed to send start test message: %v\n", err)
		return {}
	}

	time.sleep(500 * time.Millisecond)

	for i in 0 ..< config.actor_count {
		actod.send_message(
			global_coordinator_pid,
			Request_PIDs_Message {
				actor_count = i,
				type_name = fmt.tprintf("NetworkBenchmarkActor-%v-%d", typeid_of(T), i),
			},
		)
	}
	time.sleep(500 * time.Millisecond)

	ready_timeout := time.now()
	for !global_test_status.ready {
		if time.since(ready_timeout) > 10 * time.Second {
			fmt.printf("Timeout waiting for ready signal\n")
			return {}
		}
		time.sleep(10 * time.Millisecond)
	}

	pid_timeout := time.now()
	for global_pid_cache.responses_recv < config.actor_count {
		if time.since(pid_timeout) > 10 * time.Second {
			fmt.printf(
				"Timeout waiting for PID responses (%d/%d)\n",
				global_pid_cache.responses_recv,
				config.actor_count,
			)
			return {}
		}
		time.sleep(1 * time.Millisecond)
	}

	time.sleep(50 * time.Millisecond)

	messages_per_sender := config.message_count / config.sender_count
	warmup_per_sender := 10_000 / config.sender_count

	threads := make([]^thread.Thread, config.sender_count)
	defer delete(threads)

	work_datas := make([]^struct {
			actor_count:      int,
			messages_to_send: int,
			warmup_messages:  int,
			sender_id:        int,
			dedicated:        bool,
		}, config.sender_count)
	defer {
		for wd in work_datas {
			if wd != nil {
				free(wd)
			}
		}
		delete(work_datas)
	}

	for i in 0 ..< config.sender_count {
		work_data := new(struct {
				actor_count:      int,
				messages_to_send: int,
				warmup_messages:  int,
				sender_id:        int,
				dedicated:        bool,
			})
		work_data.actor_count = config.actor_count
		work_data.messages_to_send = messages_per_sender
		work_data.warmup_messages = warmup_per_sender
		work_data.sender_id = i
		work_data.dedicated = config.dedicated
		work_datas[i] = work_data

		sender_proc := network_sender_worker(T)
		threads[i] = thread.create_and_start_with_data(work_data, sender_proc)
	}

	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	stats_timeout := time.now()
	for !global_test_status.stats_received {
		if time.since(stats_timeout) > 20 * time.Second {
			fmt.printf("Timeout waiting for stats\n")
			return {}
		}
		time.sleep(10 * time.Millisecond)
	}

	stats := global_test_status.stats
	duration := time.Duration(stats.end_time_ns - stats.start_time_ns)
	duration_sec := f64(duration) / 1e9
	throughput := f64(stats.messages_received) / duration_sec
	bandwidth :=
		(f64(stats.messages_received) * f64(shared.size_bytes(config.message_size))) /
		(1024 * 1024) /
		duration_sec
	latency_ns := (duration_sec * 1e9) / f64(stats.messages_received)

	return shared.Benchmark_Result {
		config = shared.Benchmark_Config {
			message_size = config.message_size,
			message_count = config.message_count,
			actor_count = config.actor_count,
			sender_count = config.sender_count,
			warmup_messages = 10_000,
			dedicated = config.dedicated,
		},
		duration = duration,
		messages_sent = sync.atomic_load(&global_send_state.send_count),
		messages_received = stats.messages_received,
		send_failures = sync.atomic_load(&global_send_state.send_failures),
		retry_count = sync.atomic_load(&global_send_state.retry_count),
		err_actor_not_found = stats.err_actor_not_found,
		err_mailbox_full = stats.err_mailbox_full,
		err_pool_full = stats.err_pool_full,
		err_system_shutting_down = stats.err_system_shutting_down,
		err_network = stats.err_network,
		err_other = stats.err_other,
		throughput = throughput,
		bandwidth = bandwidth,
		latency_ns = latency_ns,
	}
}

run_network_benchmark_for_size :: proc(
	size: shared.Message_Size,
	config: shared.Scaling_Config,
	test_id: int,
) -> shared.Benchmark_Result {
	#partial switch size {
	case .Empty:
		return run_network_benchmark(shared.Empty_Message, config, test_id)
	case .INLINE:
		return run_network_benchmark(shared.Inline_Message, config, test_id)
	case .STRING:
		return run_network_benchmark(shared.Inline_Message_string, config, test_id)
	case .MEDIUM:
		return run_network_benchmark(shared.Medium_Message, config, test_id)
	case .LARGE:
		return run_network_benchmark(shared.Large_Message, config, test_id)
	}
	return {}
}
