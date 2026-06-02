package benchmark

import "../../src/actod"
import "../../src/pkgs/threads_act/"
import "core:fmt"
import "core:mem"

main :: proc() {
	init_bench_repeats()
	print_provenance_header()

	run_local_mailbox_benchmark()
	run_scaling_benchmark()

	actod.node_init(
		name = "latency_bench",
		opts = actod.make_node_config(
			actor_config = actod.make_actor_config(
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(.Error),
				spin_strategy = actod.SPIN_STRATEGY.CPU_RELAX,
			),
		),
	)

	run_latency_pingpong()
	run_saturation_test()

	actod.shutdown_node()
}

print_provenance_header :: proc() {
	fmt.println("=== actod benchmark run ===")
	fmt.printf("cores (logical):  %d\n", threads_act.get_cpu_count())
	fmt.printf("os/arch:          %v / %v\n", ODIN_OS, ODIN_ARCH)
	fmt.printf("odin version:     %v\n", ODIN_VERSION)
	fmt.printf("build:            -o:aggressive -no-bounds-check -disable-assert -microarch:native\n")
	fmt.printf("page_size:        %d KB\n", 64)
	fmt.printf("spin_strategy:    CPU_RELAX\n")
	fmt.printf("repeats:          %d\n", BENCH_REPEATS)
	fmt.println()
}
