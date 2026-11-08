package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

START_LISTENING_STOP_PORT :: 17610
START_LISTENING_STOP_ROUNDS :: 40

restart_node_without_a_port :: proc() {
	actod.node_init(
		"start_listening_stop",
		actod.make_node_config(
			network = actod.make_network_config(port = 0),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = test_log_level()),
			),
		),
	)
	wait_for_node()
}

stop_the_listener_proc :: proc(data: rawptr) {
	actod.stop_network_listener()
	sync.atomic_store(cast(^bool)data, true)
}

stop_returned :: proc(data: rawptr) -> bool {
	return sync.atomic_load(cast(^bool)data)
}

test_a_listener_stopped_right_after_start_listening_ends :: proc(t: ^testing.T) {
	actod.shutdown_node()
	for round in 0 ..< START_LISTENING_STOP_ROUNDS {
		restart_node_without_a_port()
		if !expectf(
			t,
			actod.start_listening(START_LISTENING_STOP_PORT),
			"round %d: start_listening",
			round,
		) {
			return
		}
		done: bool
		stop_thread := thread.create_and_start_with_data(&done, stop_the_listener_proc)
		if !expectf(
			t,
			poll_until(stop_returned, &done, scaled_timeout(5 * time.Second)),
			"round %d: stopping the listener right after start_listening returned",
			round,
		) {
			return
		}
		thread.join(stop_thread)
		thread.destroy(stop_thread)
		expectf(
			t,
			sync.atomic_load(&actod.NODE.network_listener_running) == actod.LISTENER_STOPPED,
			"round %d: the listener is stopped",
			round,
		)
		actod.shutdown_node()
	}
	restart_node_without_a_port()
}
