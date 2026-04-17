package network_benchmark

import "../../src/actod"
import "../shared"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:time"

CORRUPTION_DEBUG :: #config(CORRUPTION_DEBUG, false)
global_recv_message_counter: i32

run_node_role :: proc(role: string) {
	switch role {
	case "receiver":
		run_receiver_node()
	case:
		fmt.eprintf("Unknown node role: %s\n", role)
		os.exit(1)
	}
}

Network_Benchmark_State :: struct {
	current_test:    ^shared.Start_Test_Message,
	actors:          []actod.PID,
	stats_collector: actod.PID,
	test_complete:   bool,
	total_received:  u64,
	start_time:      time.Time,
	end_time:        time.Time,
}

global_receiver_state: Network_Benchmark_State

Stats_Collector_Data :: struct {
	test_id:           int,
	expected_messages: u64,
	received_messages: u64,
	actor_count:       int,
	actors_done:       int,
	start_time:        time.Time,
	end_time:          time.Time,
	errors:            shared.Benchmark_State,
}

Actor_Complete_Message :: struct {
	messages_received: u64,
	start_time:        time.Time,
	end_time:          time.Time,
}

@(init)
register_receiver_messages :: proc "contextless" () {
	context = runtime.default_context()
	actod.register_message_type(Actor_Complete_Message)
}

create_network_benchmark_behaviour :: proc(
	$T: typeid,
) -> actod.Actor_Behaviour(shared.Benchmark_Actor_Data) {
	return actod.Actor_Behaviour(shared.Benchmark_Actor_Data) {
		handle_message = proc(data: ^shared.Benchmark_Actor_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Get_PID_Request:
				actod.send_message(from, shared.Get_PID_Response{request_id = m.request_id})
			case T:
				data.message_count += 1
				when CORRUPTION_DEBUG {
					total := sync.atomic_add(&global_recv_message_counter, 1) + 1
					if total % 100_000 == 0 {
						fmt.eprintf("CORRUPTION_DEBUG: total_messages_received=%d\n", total)
					}
				}

				if global_receiver_state.current_test != nil {
					warmup_per_actor :=
						u64(global_receiver_state.current_test.warmup_count) /
						u64(global_receiver_state.current_test.actor_count)
					test_per_actor :=
						u64(global_receiver_state.current_test.message_count) /
						u64(global_receiver_state.current_test.actor_count)
					total_expected := warmup_per_actor + test_per_actor

					if data.message_count == warmup_per_actor + 1 {
						data.start_time = time.now()
					}

					if data.message_count >= total_expected {
						data.last_msg_time = time.now()
						complete_msg := Actor_Complete_Message {
							messages_received = test_per_actor,
							start_time        = data.start_time,
							end_time          = data.last_msg_time,
						}
						actod.send_message(global_receiver_state.stats_collector, complete_msg)
					}
				}
			}
		},
		init = proc(data: ^shared.Benchmark_Actor_Data) {
			data.message_count = 0
		},
	}
}

create_stats_collector_behaviour :: proc() -> actod.Actor_Behaviour(Stats_Collector_Data) {
	return actod.Actor_Behaviour(Stats_Collector_Data) {
		handle_message = proc(data: ^Stats_Collector_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Start_Test_Message:
				data.test_id = m.test_id
				data.expected_messages = u64(m.message_count)
				data.received_messages = 0
				data.actor_count = m.actor_count
				data.actors_done = 0
				data.start_time = time.Time{}
				data.end_time = time.Time{}
				data.errors = {}

			case Actor_Complete_Message:
				if data.start_time == {} || time.diff(data.start_time, m.start_time) < 0 {
					data.start_time = m.start_time
				}
				if data.end_time == {} || time.diff(data.end_time, m.end_time) > 0 {
					data.end_time = m.end_time
				}
				data.received_messages += m.messages_received
				data.actors_done += 1

				if data.actors_done >= data.actor_count {
					report := shared.Stats_Report_Message {
						test_id                  = data.test_id,
						messages_received        = data.received_messages,
						start_time_ns            = time.to_unix_nanoseconds(data.start_time),
						end_time_ns              = time.to_unix_nanoseconds(data.end_time),
						err_receiver_backlogged  = sync.atomic_load(
							&data.errors.err_receiver_backlogged,
						),
						err_message_too_large    = sync.atomic_load(
							&data.errors.err_message_too_large,
						),
						err_actor_not_found      = sync.atomic_load(
							&data.errors.err_actor_not_found,
						),
						err_system_shutting_down = sync.atomic_load(
							&data.errors.err_system_shutting_down,
						),
						err_network              = sync.atomic_load(&data.errors.err_network),
						err_other                = sync.atomic_load(&data.errors.err_other),
					}

					err := actod.send_remote_by_name("BenchmarkSender", "StatsCollector", report)
					if err != .OK {
						fmt.printf("Failed to send stats report: %v\n", err)
					}

					global_receiver_state.test_complete = true
				}
			}
		},
	}
}

spawn_benchmark_actor :: proc($T: typeid, id: int) -> actod.PID {
	name := fmt.tprintf("NetworkBenchmarkActor-%v-%d", typeid_of(T), id)
	data := shared.Benchmark_Actor_Data {
		id = id,
	}

	behaviour := create_network_benchmark_behaviour(T)

	pid, ok := actod.spawn(
		name,
		data,
		behaviour,
		actod.make_actor_config(
			spin_strategy = .CPU_RELAX,
			logging = actod.make_log_config(level = .Error),
		),
	)

	if !ok {
		panic(fmt.tprintf("Failed to spawn benchmark actor %d", id))
	}

	return pid
}

handle_start_test :: proc(msg: shared.Start_Test_Message) {
	for pid in global_receiver_state.actors {
		actod.terminate_actor(pid)
	}
	delete(global_receiver_state.actors)

	test_copy := new(shared.Start_Test_Message)
	test_copy^ = msg
	global_receiver_state.current_test = test_copy
	global_receiver_state.test_complete = false

	actod.send_message(global_receiver_state.stats_collector, msg)

	actors := make([]actod.PID, msg.actor_count)

	for i in 0 ..< msg.actor_count {
		switch msg.message_size {
		case .Empty:
			actors[i] = spawn_benchmark_actor(shared.Empty_Message, i)
		case .INLINE:
			actors[i] = spawn_benchmark_actor(shared.Inline_Message, i)
		case .STRING:
			actors[i] = spawn_benchmark_actor(shared.Inline_Message_string, i)
		case .MEDIUM:
			actors[i] = spawn_benchmark_actor(shared.Medium_Message, i)
		case .LARGE:
			actors[i] = spawn_benchmark_actor(shared.Large_Message, i)
		case .XLARGE:
			actors[i] = spawn_benchmark_actor(shared.XLarge_Message, i)
		case .HUGE:
			actors[i] = spawn_benchmark_actor(shared.Huge_Message, i)
		case .MEGA:
			actors[i] = spawn_benchmark_actor(shared.Mega_Message, i)
		case .MEGA2:
			actors[i] = spawn_benchmark_actor(shared.Mega2_Message, i)
		case .MEGA4:
			actors[i] = spawn_benchmark_actor(shared.Mega4_Message, i)
		}
	}

	global_receiver_state.actors = actors

	ready_msg := shared.Ready_Message {
		test_id     = msg.test_id,
		actor_count = msg.actor_count,
	}

	err := actod.send_remote_by_name("BenchmarkSender", "TestCoordinator", ready_msg)
	if err != .OK {
		fmt.printf("Failed to send ready message: %v\n", err)
	}
}

create_test_coordinator_behaviour :: proc() -> actod.Actor_Behaviour(int) {
	return actod.Actor_Behaviour(int) {
		handle_message = proc(data: ^int, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Start_Test_Message:
				handle_start_test(m)
			}
		},
	}
}

run_receiver_node :: proc() {
	port_str := os.lookup_env("BENCH_PORT", context.temp_allocator) or_else "17200"
	port, port_ok := strconv.parse_int(port_str)
	if !port_ok {
		port = 17200
	}

	auth := os.lookup_env("BENCH_AUTH", context.temp_allocator) or_else "bench_password"

	actod.NODE_INIT(
		name = "BenchmarkReceiver",
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = port,
				auth_password = auth,
				connection_ring = actod.Connection_Ring_Config {
					send_slot_count = 64,
					send_slot_size = 64 * 1024,
					recv_buffer_size = 4 * 1024 * 1024,
					tcp_nodelay = true,
					scale_up_contention_threshold = 1,
					scale_down_idle_seconds = 10,
				},
			),
			actor_config = actod.make_actor_config(
				spin_strategy = .CPU_RELAX,
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(level = .Warning),
			),
		),
	)

	stats_data := Stats_Collector_Data{}
	stats_behaviour := create_stats_collector_behaviour()
	stats_pid, ok := actod.spawn("StatsCollector", stats_data, stats_behaviour)
	if !ok {
		panic("Failed to spawn stats collector")
	}
	global_receiver_state.stats_collector = stats_pid

	coordinator_data := 0
	coordinator_behaviour := create_test_coordinator_behaviour()
	_, ok = actod.spawn("TestCoordinator", coordinator_data, coordinator_behaviour)
	if !ok {
		panic("Failed to spawn test coordinator")
	}

	fmt.println("[Receiver] Node started, waiting for tests...")

	actod.await_signal()
}
