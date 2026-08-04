package integration

import "../actod"
import "core:sync"
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
			_ = actod.send_message(from, "pong")
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
	expect(t, panic_ok, "Failed to spawn panic actor")

	echo_pid, echo_ok := actod.spawn(
		"echo-actor",
		Panic_Actor_Data{},
		Panic_Actor_Behaviour,
		actod.make_actor_config(),
	)
	expect(t, echo_ok, "Failed to spawn echo actor")

	err := actod.send_message(panic_pid, "panic")
	expect(t, err == .OK, "Failed to send panic message")

	expect(
		t,
		wait_for_actor_invalid(panic_pid, 1000),
		"Panicked actor should be removed from registry",
	)

	expect(
		t,
		actod.valid(&actod.global_registry, echo_pid),
		"Echo actor should still be alive",
	)
	err2 := actod.send_message(echo_pid, "ping")
	expect(t, err2 == .OK, "Echo actor should still accept messages")

	_ = actod.send_message(echo_pid, actod.Terminate{reason = .NORMAL})
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
	expect(t, ok, "Failed to spawn supervisor")
	expect(t, wait_for_child_count(supervisor_pid, 1, 1000), "Child should be spawned")

	children := actod.get_children(supervisor_pid)
	old_child := children[0]
	delete(children)

	err := actod.send_message(old_child, "panic")
	expect(t, err == .OK, "Failed to send panic to child")

	new_pid, restarted := wait_for_child_pid_change(supervisor_pid, old_child, 0, 2000)
	expect(t, restarted, "Child should be restarted after panic")
	expect(t, new_pid != old_child, "Restarted child should have new PID")

	err2 := actod.send_message(new_pid, "ping")
	expect(t, err2 == .OK, "Restarted child should accept messages")

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
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
	expect(t, panic_ok, "Spawn should succeed even if init panics")

	expect(
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
	expect(t, echo_ok, "Should be able to spawn new actors after init panic")

	err := actod.send_message(echo_pid, "ping")
	expect(t, err == .OK, "System should be functional after init panic")

	_ = actod.send_message(echo_pid, actod.Terminate{reason = .NORMAL})
	wait_for_actor_invalid(echo_pid, 500)
}

Crash_Teardown_Data :: struct {
	id: int,
}

crash_teardown_terminate_ran: int

Crash_Teardown_Behaviour :: actod.Actor_Behaviour(Crash_Teardown_Data) {
	handle_message = crash_teardown_handle_message,
	terminate      = crash_teardown_terminate,
}

crash_teardown_handle_message :: proc(data: ^Crash_Teardown_Data, from: actod.PID, msg: any) {
	if text, ok := msg.(string); ok && text == "panic" {
		panic("intentional panic")
	}
}

crash_teardown_terminate :: proc(data: ^Crash_Teardown_Data) {
	sync.atomic_add(&crash_teardown_terminate_ran, 1)
}

test_crash_runs_terminate_and_reaps_children :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&crash_teardown_terminate_ran, 0)

	parent_pid, ok := actod.spawn(
		"crash-teardown-parent",
		Crash_Teardown_Data{id = 1},
		Crash_Teardown_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
	)
	expect(t, ok, "Failed to spawn parent")
	if !ok do return

	_, added := actod.add_child(parent_pid, create_crash_child(0))
	expect(t, added, "Failed to add child")
	expect(t, wait_for_child_count(parent_pid, 1, 2000), "Child should be registered")

	children := actod.get_children(parent_pid)
	child_pid := children[0]
	delete(children)

	err := actod.send_message(parent_pid, "panic")
	expect(t, err == .OK, "Failed to send panic message")

	expect(
		t,
		wait_for_actor_invalid(parent_pid, 2000),
		"Crashed parent should be removed from registry",
	)
	expect(
		t,
		wait_for_actor_invalid(child_pid, 2000),
		"Crashed parent's child must be terminated, not orphaned",
	)
	expect(
		t,
		sync.atomic_load(&crash_teardown_terminate_ran) == 1,
		"terminate callback must run exactly once on crash",
	)
}

panicking_terminate_ran: int

Panicking_Terminate_Behaviour :: actod.Actor_Behaviour(Crash_Teardown_Data) {
	handle_message = crash_teardown_handle_message,
	terminate      = panicking_terminate,
}

panicking_terminate :: proc(data: ^Crash_Teardown_Data) {
	sync.atomic_add(&panicking_terminate_ran, 1)
	panic("intentional panic in terminate")
}

test_panic_in_terminate_runs_teardown_once :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&panicking_terminate_ran, 0)

	pid, ok := actod.spawn(
		"panicking-terminate",
		Crash_Teardown_Data{id = 1},
		Panicking_Terminate_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
	)
	expect(t, ok, "Failed to spawn actor")
	if !ok do return

	expect(t, actod.terminate_actor(pid), "Failed to request termination")
	expect(
		t,
		wait_for_actor_invalid(pid, 2000),
		"Actor should be removed from registry despite terminate panicking",
	)
	expect(
		t,
		sync.atomic_load(&panicking_terminate_ran) == 1,
		"terminate callback must run exactly once when it panics during normal shutdown",
	)
}
