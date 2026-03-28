package benchmark

import "../../src/pkgs/threads_act/"
import "../shared"
import "core:fmt"
import vmem "core:mem/virtual"

generate_scaling_configs :: proc(cpu_count: int) -> []shared.Scaling_Config {
	configs := make([dynamic]shared.Scaling_Config)
	base_messages := 1_000_000

	test_sizes := []shared.Message_Size{.Empty, .INLINE, .MEDIUM, .LARGE, .XLARGE, .HUGE}

	// BASELINE: 1 sender → 1 receiver, same worker
	for size in test_sizes {
		msg_count := base_messages
		sz := shared.size_bytes(size)
		if sz >= 4096 do msg_count = base_messages / 4
		if sz >= 32768 do msg_count = base_messages / 8

		append(
			&configs,
			shared.Scaling_Config {
				actor_count = 1,
				sender_count = 1,
				message_count = msg_count,
				message_size = size,
				description = fmt.tprintf("1:1 %s", shared.size_name(size)),
				category = .BASELINE,
				dedicated = true,
				worker_count = 1,
				same_worker = true,
			},
		)
	}

	// FANIN: N senders → 1 receiver, cross-worker
	fanin_senders := min(4, cpu_count)
	for size in test_sizes {
		append(
			&configs,
			shared.Scaling_Config {
				actor_count = 1,
				sender_count = fanin_senders,
				message_count = base_messages,
				message_size = size,
				description = fmt.tprintf("%d:1 %s", fanin_senders, shared.size_name(size)),
				category = .FANIN,
				dedicated = false,
			},
		)
	}

	// PARALLEL: N pairs, each pair on same worker
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
						worker_count = n,
						same_worker = true,
					},
				)
			}
		}
	}


	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 1,
			sender_count = cpu_count,
			message_count = base_messages * 2,
			message_size = .LARGE,
			description = fmt.tprintf("%d:1 1KB", cpu_count),
			category = .STRESS,
			dedicated = false,
		},
	)

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 2,
			sender_count = cpu_count,
			message_count = base_messages * 2,
			message_size = .XLARGE,
			description = fmt.tprintf("%d:2 4KB", cpu_count),
			category = .STRESS,
			dedicated = false,
		},
	)

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 4,
			sender_count = cpu_count,
			message_count = base_messages / 4,
			message_size = .XLARGE,
			description = fmt.tprintf("%d:4 32KB", cpu_count),
			category = .STRESS,
			dedicated = false,
		},
	)

	if cpu_count >= 4 {
		append(
			&configs,
			shared.Scaling_Config {
				actor_count = cpu_count / 2,
				sender_count = cpu_count,
				message_count = base_messages * 2,
				message_size = .MEDIUM,
				description = fmt.tprintf("Mesh %d:%d", cpu_count, cpu_count / 2),
				category = .STRESS,
				dedicated = false,
			},
		)
	}

	contention_messages := base_messages / 4

	if cpu_count >= 8 {
		append(
			&configs,
			shared.Scaling_Config {
				actor_count = 1,
				sender_count = min(32, cpu_count * 2),
				message_count = contention_messages,
				message_size = .Empty,
				description = fmt.tprintf("%d:1 Empty", min(32, cpu_count * 2)),
				category = .CONTENTION,
				dedicated = false,
			},
		)
	}

	if cpu_count >= 16 {
		append(
			&configs,
			shared.Scaling_Config {
				actor_count = 1,
				sender_count = 64,
				message_count = contention_messages / 2,
				message_size = .Empty,
				description = "64:1 Empty",
				category = .CONTENTION,
				dedicated = false,
			},
		)
	}

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 2,
			sender_count = 2,
			message_count = base_messages / 2,
			message_size = .Empty,
			description = "2:2 Ping-Pong",
			category = .CONTENTION,
			dedicated = true,
		},
	)

	burst_messages := base_messages / 10

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 1,
			sender_count = cpu_count / 2,
			message_count = burst_messages,
			message_size = .INLINE,
			description = fmt.tprintf("%d:1 Burst", cpu_count / 2),
			category = .BURST,
			dedicated = false,
		},
	)

	if cpu_count >= 8 {
		append(
			&configs,
			shared.Scaling_Config {
				actor_count = 2,
				sender_count = 8,
				message_count = base_messages / 2,
				message_size = .MEDIUM,
				description = "8:2 Fairness",
				category = .FAIRNESS,
				dedicated = false,
			},
		)
	}

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 1,
			sender_count = 1,
			message_count = base_messages / 4,
			message_size = .XLARGE,
			description = "Size: 4KB vs 32B",
			category = .SIZE_SCALING,
			dedicated = true,
		},
	)

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 1,
			sender_count = 1,
			message_count = base_messages / 8,
			message_size = .XLARGE,
			description = "Size: 4KB vs 32B",
			category = .SIZE_SCALING,
			dedicated = true,
		},
	)

	append(
		&configs,
		shared.Scaling_Config {
			actor_count = 1,
			sender_count = 8,
			message_count = base_messages / 4,
			message_size = .XLARGE,
			description = "8:1 4KB contention",
			category = .SIZE_SCALING,
			dedicated = false,
		},
	)

	return configs[:]
}

run_scaling_benchmark :: proc() {
	a: vmem.Arena
	arena_err := vmem.arena_init_static(&a)
	ensure(arena_err == nil)
	context.allocator = vmem.arena_allocator(&a)
	defer vmem.arena_destroy(&a)
	cpu_count := threads_act.get_cpu_count()

	fmt.printf("\n=== ACTOD Benchmark (%d cores) ===\n\n", cpu_count)

	configs := generate_scaling_configs(cpu_count)

	fmt.println(
		"Test                 │ Category │  Msgs/sec  │    MB/s  │  Latency │ Errors",
	)
	fmt.println(
		"─────────────────────┼──────────┼────────────┼──────────┼──────────┼────────",
	)

	for config in configs {
		bench_config := shared.Benchmark_Config {
			message_size    = config.message_size,
			message_count   = config.message_count,
			actor_count     = config.actor_count,
			sender_count    = config.sender_count,
			warmup_messages = 10000,
			dedicated       = config.dedicated,
			worker_count    = config.worker_count,
			same_worker     = config.same_worker,
		}

		result := run_benchmark_for_size(config.message_size, bench_config)

		bytes := shared.size_bytes(config.message_size)
		bandwidth := (result.throughput * f64(bytes)) / (1024 * 1024)

		error_str: string
		if result.err_pool_full > 0 && result.err_mailbox_full > 0 {
			error_str = fmt.tprintf("P:%d M:%d", result.err_pool_full, result.err_mailbox_full)
		} else if result.err_pool_full > 0 {
			error_str = fmt.tprintf("Pool:%d", result.err_pool_full)
		} else if result.err_mailbox_full > 0 {
			error_str = fmt.tprintf("Mbox:%d", result.err_mailbox_full)
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
			"  %-18s │ %-8s │  %7sM  │  %7s │ %5sns  │ %s\n",
			config.description,
			cat_name,
			fmt.tprintf("%.2f", result.throughput / 1_000_000),
			fmt.tprintf("%.1f", bandwidth),
			fmt.tprintf("%.0f", result.latency_ns),
			error_str,
		)

		wait_for_actors_cleanup()
	}

	fmt.println()
}

run_benchmark_for_size :: proc(
	size: shared.Message_Size,
	config: shared.Benchmark_Config,
) -> shared.Benchmark_Result {
	switch size {
	case .Empty:
		return run_benchmark(shared.Empty_Message, config)
	case .INLINE:
		return run_benchmark(shared.Inline_Message, config)
	case .STRING:
		return run_benchmark(shared.Inline_Message_string, config)
	case .MEDIUM:
		return run_benchmark(shared.Medium_Message, config)
	case .LARGE:
		return run_benchmark(shared.Large_Message, config)
	case .XLARGE:
		return run_benchmark(shared.XLarge_Message, config)
	case .HUGE:
		return run_benchmark(shared.Huge_Message, config)
	case .MEGA:
		return run_benchmark(shared.Mega_Message, config)
	case .MEGA2:
		return run_benchmark(shared.Mega2_Message, config)
	case .MEGA4:
		return run_benchmark(shared.Mega4_Message, config)
	}
	return {}
}
