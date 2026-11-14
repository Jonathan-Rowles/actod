package integration

import "../actod"
import "core:testing"

counted_blocking_child_spawns: int

spawn_counted_blocking_child :: proc(
	name: string,
	parent: actod.PID,
) -> (
	actod.PID,
	bool,
) {
	counted_blocking_child_spawns += 1
	return spawn_blocking_reap_child(name, parent)
}

test_next_node_does_not_inherit_blocking_child :: proc(t: ^testing.T) {
	reset_test_state()
	counted_blocking_child_spawns = 0

	restart_node_with(
		"config-reset-first",
		nil,
		3,
		spawn_counted_blocking_child,
	)
	expect_value(t, counted_blocking_child_spawns, 1)

	actod.shutdown_node()
	actod.node_init(
		"config-reset-second",
		actod.make_node_config(
			worker_count = 2,
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = test_log_level()),
			),
		),
	)

	expect_value(t, counted_blocking_child_spawns, 1)
	expect(
		t,
		actod.NODE.config.blocking_child == nil,
		"a node that names no blocking child must not take the previous node's",
	)

	actod.shutdown_node()
	expect_value(t, actod.NODE.shutdown_leaked_actors, 0)
}
