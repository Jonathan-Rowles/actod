package network_benchmark

import "core:os"

main :: proc() {
	if role, ok := os.lookup_env("ACTOD_BENCH_NODE", context.temp_allocator); ok {
		run_node_role(role)
		os.exit(0)
	}

	run_network_benchmark_suite()
}
