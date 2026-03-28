package integration

import "../actod"
import "core:testing"

Panic_Actor_Data :: struct {
	message_count: int,
	init_panic:    bool,
}

Panic_Actor_Behaviour :: actod.Actor_Behaviour(Panic_Actor_Data) {
	init           = panic_actor_init,
	handle_message = panic_actor_handle_message,
}

panic_actor_init :: proc(data: ^Panic_Actor_Data) {
	if data.init_panic {
		panic("panic in init")
	}
}

panic_actor_handle_message :: proc(data: ^Panic_Actor_Data, from: actod.PID, msg: any) {
	data.message_count += 1
	switch m in msg {
	case string:
		if m == "panic" {
			panic("intentional panic")
		} else if m == "ping" {
			actod.send_message(from, "pong")
		}
	}
}

test_actor_panic_recovery :: proc(t: ^testing.T) {
	reset_test_state()

	panic_pid, panic_ok := actod.spawn(
		"panic-actor",
		Panic_Actor_Data{},
		Panic_Actor_Behaviour,
		actod.make_actor_config(),
	)
	testing.expect(t, panic_ok, "Failed to spawn panic actor")

	echo_pid, echo_ok := actod.spawn(
		"echo-actor",
		Panic_Actor_Data{},
		Panic_Actor_Behaviour,
		actod.make_actor_config(),
	)
	testing.expect(t, echo_ok, "Failed to spawn echo actor")

	err := actod.send_message(panic_pid, "panic")
	testing.expect(t, err == .OK, "Failed to send panic message")

	testing.expect(
		t,
		wait_for_actor_invalid(panic_pid, 1000),
		"Panicked actor should be removed from registry",
	)

	testing.expect(
		t,
		actod.valid(&actod.global_registry, echo_pid),
		"Echo actor should still be alive",
	)
	err2 := actod.send_message(echo_pid, "ping")
	testing.expect(t, err2 == .OK, "Echo actor should still accept messages")

	actod.send_message(echo_pid, actod.Terminate{reason = .NORMAL})
	wait_for_actor_invalid(echo_pid, 500)
}

test_actor_panic_supervisor_restart :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	append(&child_spawns, proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
		return actod.spawn_child(
			"panic-child",
			Panic_Actor_Data{},
			Panic_Actor_Behaviour,
			actod.make_actor_config(),
		)
	})

	supervisor_pid, ok := actod.spawn(
		"panic-supervisor",
		Supervisor_Test_Data{},
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")
	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 1000), "Child should be spawned")

	children := actod.get_children(supervisor_pid)
	old_child := children[0]
	delete(children)

	err := actod.send_message(old_child, "panic")
	testing.expect(t, err == .OK, "Failed to send panic to child")

	new_pid, restarted := wait_for_child_pid_change(supervisor_pid, old_child, 0, 2000)
	testing.expect(t, restarted, "Child should be restarted after panic")
	testing.expect(t, new_pid != old_child, "Restarted child should have new PID")

	err2 := actod.send_message(new_pid, "ping")
	testing.expect(t, err2 == .OK, "Restarted child should accept messages")

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	wait_for_actor_invalid(supervisor_pid, 500)
}

test_actor_panic_in_init :: proc(t: ^testing.T) {
	reset_test_state()

	panic_pid, panic_ok := actod.spawn(
		"init-panic-actor",
		Panic_Actor_Data{init_panic = true},
		Panic_Actor_Behaviour,
		actod.make_actor_config(),
	)
	testing.expect(t, panic_ok, "Spawn should succeed even if init panics")

	testing.expect(
		t,
		wait_for_actor_invalid(panic_pid, 1000),
		"Init-panicked actor should be removed",
	)

	echo_pid, echo_ok := actod.spawn(
		"post-panic-echo",
		Panic_Actor_Data{},
		Panic_Actor_Behaviour,
		actod.make_actor_config(),
	)
	testing.expect(t, echo_ok, "Should be able to spawn new actors after init panic")

	err := actod.send_message(echo_pid, "ping")
	testing.expect(t, err == .OK, "System should be functional after init panic")

	actod.send_message(echo_pid, actod.Terminate{reason = .NORMAL})
	wait_for_actor_invalid(echo_pid, 500)
}
