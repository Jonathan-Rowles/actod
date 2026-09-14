package integration

import "../actod"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

Survival_Probe_Data :: struct {
	target:  actod.PID,
	replied: ^bool,
}

Survival_Probe_Behaviour :: actod.Actor_Behaviour(Survival_Probe_Data) {
	init           = survival_probe_init,
	handle_message = survival_probe_handle_message,
}

survival_probe_init :: proc(data: ^Survival_Probe_Data) {
	_ = actod.send_message(data.target, "get_stats")
}

survival_probe_handle_message :: proc(data: ^Survival_Probe_Data, from: actod.PID, msg: any) {
	switch reply in msg {
	case string:
		if from == data.target && strings.has_prefix(reply, "restarts=") do sync.atomic_store(data.replied, true)
	}
}

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

	remaining := []actod.PID{initial_children[0], initial_children[2]}
	expect(
		t,
		wait_for_children_replaced(supervisor_pid, remaining, 0, 1000),
		"ONE_FOR_ALL should restart both remaining children",
	)

	_, supervisor_alive := actod.get_actor_pid("remove-oob-supervisor")
	expect(
		t,
		supervisor_alive,
		"Supervisor must survive ONE_FOR_ALL restart after a prior child removal",
	)

	supervisor_replied: bool
	probe_pid, probe_ok := actod.spawn(
		"remove-oob-survival-probe",
		Survival_Probe_Data{target = supervisor_pid, replied = &supervisor_replied},
		Survival_Probe_Behaviour,
	)
	expect(t, probe_ok, "Failed to spawn survival probe")
	expect(
		t,
		poll_until(atomic_flag_raised, &supervisor_replied, 1 * time.Second),
		"Supervisor must handle a message after the ONE_FOR_ALL restart",
	)
	_ = actod.terminate_actor(probe_pid)
	actod.wait_for_pids([]actod.PID{probe_pid})

	survivors := actod.get_children(supervisor_pid)
	defer delete(survivors)
	expect_value(t, len(survivors), 2)

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}
