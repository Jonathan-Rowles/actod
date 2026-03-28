package benchmark

import "../../src/actod"
import "core:mem"

main :: proc() {
	run_local_mailbox_benchmark()
	run_scaling_benchmark()

	actod.NODE_INIT(
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

	actod.SHUTDOWN_NODE()
}
