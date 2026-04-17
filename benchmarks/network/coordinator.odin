package network_benchmark

import "../../src/actod"
import "../../src/pkgs/threads_act"
import "../shared"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:net"
import "core:os"
import "core:time"


Benchmark_Process :: struct {
	process: os.Process,
	role:    string,
}

run_network_benchmark_suite :: proc() {
	fmt.println("\n=== Network Benchmark Suite ===\n")

	receiver := spawn_benchmark_node("receiver", port = 17200)
	defer cleanup_process(receiver)

	fmt.println("Waiting for receiver to start...")
	startup_wait :: 5 * time.Second when ODIN_OS == .Windows else 2 * time.Second
	time.sleep(startup_wait)

	run_benchmark_tests()

	fmt.println("\nBenchmark complete!")
}

spawn_benchmark_node :: proc(role: string, port: int) -> Benchmark_Process {
	exe_path := "bin/network_benchmark" when ODIN_OS != .Windows else "bin\\network_benchmark.exe"

	proc_desc := os.Process_Desc {
		command = []string{exe_path},
		env     = make_bench_env(
			[]string {
				fmt.tprintf("ACTOD_BENCH_NODE=%s", role),
				fmt.tprintf("BENCH_PORT=%d", port),
				"BENCH_AUTH=bench_password",
			},
		),
		stdout  = os.stdout,
		stderr  = os.stderr,
	}

	process, err := os.process_start(proc_desc)
	if err != nil {
		fmt.eprintf("Failed to start %s process: %v\n", role, err)
		panic("Process spawn failed")
	}

	fmt.printf("[Coordinator] Spawned %s process (port %d)\n", role, port)

	return Benchmark_Process{process = process, role = role}
}

cleanup_process :: proc(bp: Benchmark_Process) {
	fmt.printf("[Coordinator] Cleaning up %s process...\n", bp.role)
	_ = os.process_kill(bp.process)
	_, _ = os.process_wait(bp.process)
}

run_benchmark_tests :: proc() {
	actod.NODE_INIT(
		name = "BenchmarkSender",
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = 0, // Auto-assign port for sender
				auth_password = "bench_password",
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
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(level = .Error),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = 17200,
	}
	_, ok := actod.register_node("BenchmarkReceiver", remote_addr, .TCP_Custom_Protocol)
	if !ok {
		panic("Failed to register remote receiver node")
	}

	coordinator_data := 0
	coordinator_behaviour := create_sender_coordinator_behaviour()
	coordinator_pid: actod.PID
	coordinator_pid, ok = actod.spawn("TestCoordinator", coordinator_data, coordinator_behaviour)
	if !ok {
		panic("Failed to spawn test coordinator")
	}
	global_coordinator_pid = coordinator_pid

	stats_data := 0
	stats_behaviour := create_sender_stats_behaviour()
	_, ok = actod.spawn("StatsCollector", stats_data, stats_behaviour)
	if !ok {
		panic("Failed to spawn stats collector")
	}

	time.sleep(1 * time.Second)

	arena: vmem.Arena
	arena_err := vmem.arena_init_static(&arena)
	if arena_err != nil {
		panic("Failed to initialize arena")
	}
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	cpu_count := threads_act.get_cpu_count()

	fmt.printf("\n=== ACTOD Network Benchmark (%d cores) ===\n\n", cpu_count)
	fmt.println(
		"Test                 │ Category │  Msgs/sec │    MB/s │ Latency │ Errors",
	)
	fmt.println(
		"─────────────────────┼──────────┼───────────┼─────────┼─────────┼────────",
	)

	configs := generate_network_scaling_configs(cpu_count)

	test_id := 0

	for config in configs {
		test_id += 1
		result := run_network_benchmark_for_size(config.message_size, config, test_id)

		if result.messages_received == 0 {
			fmt.printf("  %-18s │ %-11s │ FAILED\n", config.description, "ERROR")
			continue
		}

		bytes := shared.size_bytes(config.message_size)
		bandwidth := (result.throughput * f64(bytes)) / (1024 * 1024)

		error_str: string
		if result.err_receiver_backlogged > 0 ||
		   result.err_message_too_large > 0 ||
		   result.err_network > 0 {
			error_str = fmt.tprintf(
				"Backlog:%d TooLarge:%d Net:%d",
				result.err_receiver_backlogged,
				result.err_message_too_large,
				result.err_network,
			)
		} else {
			error_str = "-"
		}

		cat_name: string
		switch config.category {
		case .BASELINE:
			cat_name = "BASE"
		case .FANIN:
			cat_name = "FANIN"
		case .PARALLEL:
			cat_name = "PARALLEL"
		case .STRESS:
			cat_name = "STRESS"
		case .CONTENTION:
			cat_name = "CONTENT"
		case .BURST:
			cat_name = "BURST"
		case .FAIRNESS:
			cat_name = "FAIR"
		case .SIZE_SCALING:
			cat_name = "SIZE"
		}

		fmt.printf(
			"  %-18s │ %-8s │ %7sM  │ %7s │ %5sns │ %s\n",
			config.description,
			cat_name,
			fmt.tprintf("%.2f", result.throughput / 1_000_000),
			fmt.tprintf("%.1f", bandwidth),
			fmt.tprintf("%.0f", result.latency_ns),
			error_str,
		)

		time.sleep(100 * time.Millisecond)
	}

	fmt.println()
}
