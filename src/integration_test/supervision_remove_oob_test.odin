package integration

import "../actod"
import "core:testing"
import "core:time"

test_remove_child_then_restart_all :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)
	for _ in 0 ..< 3 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 7,
	}
	supervisor_pid, ok := actod.spawn(
		"remove-oob-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ALL,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	expect(t, ok, "Failed to spawn supervisor")
	expect(t, wait_for_child_count(supervisor_pid, 3, 500), "Children should be spawned")

	initial_children := actod.get_children(supervisor_pid)
	defer delete(initial_children)
	expect_value(t, len(initial_children), 3)
	if len(initial_children) != 3 {
		return
	}

	removed := actod.remove_child(supervisor_pid, initial_children[1])
	expect(t, removed, "Failed to remove middle child")
	expect(
		t,
		wait_for_child_count(supervisor_pid, 2, 500),
		"Supervisor should have 2 children after removal",
	)

	err := actod.send_message(initial_children[0], "crash")
	expect(t, err == .OK, "Failed to crash remaining child")

	time.sleep(500 * time.Millisecond)

	_, supervisor_alive := actod.get_actor_pid("remove-oob-supervisor")
	expect(
		t,
		supervisor_alive,
		"Supervisor must survive ONE_FOR_ALL restart after a prior child removal",
	)

	survivors := actod.get_children(supervisor_pid)
	defer delete(survivors)
	expect_value(t, len(survivors), 2)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}
