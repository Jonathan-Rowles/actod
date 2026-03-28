package integration

import "../actod"
import "base:intrinsics"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"

Crash_Test_Data :: struct {
	id:            int,
	crash_on_msg:  string,
	crash_reason:  actod.Termination_Reason,
	message_count: int,
	init_count:    int,
	should_panic:  bool,
}

Crash_Test_Behaviour :: actod.Actor_Behaviour(Crash_Test_Data) {
	init           = crash_test_init,
	handle_message = crash_test_handle_message,
	terminate      = crash_test_terminate,
}

crash_test_init :: proc(data: ^Crash_Test_Data) {
	data.init_count += 1
	sync.atomic_add(&global_test_state.actors_spawned, 1)

	if data.should_panic && data.init_count == 1 {
		actod.self_terminate(data.crash_reason)
	}
}

crash_test_handle_message :: proc(data: ^Crash_Test_Data, from: actod.PID, msg: any) {
	data.message_count += 1

	switch m in msg {
	case string:
		if m == data.crash_on_msg {
			actod.self_terminate(data.crash_reason)
		} else if m == "ping" {
			actod.send_message(from, "pong")
		}

	case Integration_Test_Message:
		sync.atomic_add(&global_test_state.messages_received, 1)
		actod.send_message(from, m)
		sync.atomic_add(&global_test_state.messages_sent, 1)
	}
}

crash_test_terminate :: proc(data: ^Crash_Test_Data) {
	sync.atomic_add(&global_test_state.actors_terminated, 1)
}

Supervisor_Test_Data :: struct {
	id:                 int,
	children_spawned:   int,
	restarts_seen:      int,
	child_pids:         [dynamic]actod.PID,
	last_stopped_child: actod.PID,
	last_stop_reason:   actod.Termination_Reason,
}

Supervisor_Test_Behaviour :: actod.Actor_Behaviour(Supervisor_Test_Data) {
	init           = supervisor_test_init,
	handle_message = supervisor_test_handle_message,
	terminate      = supervisor_test_terminate,
}

supervisor_test_init :: proc(data: ^Supervisor_Test_Data) {
	sync.atomic_add(&global_test_state.actors_spawned, 1)
}

supervisor_test_handle_message :: proc(data: ^Supervisor_Test_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case actod.Actor_Stopped:
		data.restarts_seen += 1
		data.last_stopped_child = m.child_pid
		data.last_stop_reason = m.reason

	case string:
		if m == "get_stats" {
			stats := fmt.tprintf("restarts=%d", data.restarts_seen)
			actod.send_message(from, stats)
		}
	}
}

supervisor_test_terminate :: proc(data: ^Supervisor_Test_Data) {
	sync.atomic_add(&global_test_state.actors_terminated, 1)
}

wait_for_condition :: proc(condition: proc() -> bool, timeout_ms: int) -> bool {
	start := time.now()
	deadline := time.time_add(start, time.Duration(timeout_ms) * time.Millisecond)

	if condition() {
		return true
	}

	for i := 0; i < 20; i += 1 {
		if condition() {
			return true
		}
		time.sleep(1 * time.Millisecond)
	}

	for time.diff(deadline, time.now()) > 0 {
		if condition() {
			return true
		}
		time.sleep(1 * time.Millisecond)
	}

	return false
}

wait_for_actor_state :: proc(pid: actod.PID, timeout_ms: int) -> bool {
	start := time.now()
	deadline := time.time_add(start, time.Duration(timeout_ms) * time.Millisecond)

	if _, ok := actod.get(&actod.global_registry, pid); ok {
		return true
	}

	for i := 0; i < 20; i += 1 {
		if _, ok := actod.get(&actod.global_registry, pid); ok {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}

	for time.diff(deadline, time.now()) > 0 {
		if _, ok := actod.get(&actod.global_registry, pid); ok {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}

	return false
}

wait_for_child_count :: proc(parent: actod.PID, expected: int, timeout_ms: int) -> bool {
	start := time.now()
	deadline := time.time_add(start, time.Duration(timeout_ms) * time.Millisecond)

	{
		children := actod.get_children(parent)
		defer delete(children)
		if len(children) == expected {
			return true
		}
	}

	for i := 0; i < 20; i += 1 {
		children := actod.get_children(parent)
		defer delete(children)
		if len(children) == expected {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}

	for time.diff(deadline, time.now()) > 0 {
		children := actod.get_children(parent)
		defer delete(children)
		if len(children) == expected {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}

	return false
}

wait_for_actor_invalid :: proc(pid: actod.PID, timeout_ms: int) -> bool {
	start := time.now()
	deadline := time.time_add(start, time.Duration(timeout_ms) * time.Millisecond)

	if !actod.valid(&actod.global_registry, pid) {
		return true
	}

	for i := 0; i < 20; i += 1 {
		if !actod.valid(&actod.global_registry, pid) {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}

	for time.diff(deadline, time.now()) > 0 {
		if !actod.valid(&actod.global_registry, pid) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}

	return false
}

wait_for_child_pid_change :: proc(
	parent: actod.PID,
	old_pid: actod.PID,
	index: int,
	timeout_ms: int,
) -> (
	new_pid: actod.PID,
	success: bool,
) {
	start := time.now()
	deadline := time.time_add(start, time.Duration(timeout_ms) * time.Millisecond)

	{
		children := actod.get_children(parent)
		defer delete(children)
		if len(children) > index && children[index] != old_pid {
			return children[index], true
		}
	}

	for i := 0; i < 20; i += 1 {
		children := actod.get_children(parent)
		defer delete(children)
		if len(children) > index && children[index] != old_pid {
			return children[index], true
		}
		time.sleep(2 * time.Millisecond)
	}

	for time.diff(deadline, time.now()) > 0 {
		children := actod.get_children(parent)
		defer delete(children)
		if len(children) > index && children[index] != old_pid {
			return children[index], true
		}
		time.sleep(5 * time.Millisecond)
	}

	return 0, false
}

verify_child_count :: proc(t: ^testing.T, parent: actod.PID, expected: int) {
	children := actod.get_children(parent)
	defer delete(children)
	testing.expect_value(t, len(children), expected)
}

create_crash_child :: proc(parent: actod.PID) -> actod.SPAWN {
	return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
			data := Crash_Test_Data {
				id           = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
				crash_on_msg = "crash",
				crash_reason = .INTERNAL_ERROR,
			}
			return actod.spawn_child(
				fmt.tprintf("crash-child-%d", data.id),
				data,
				Crash_Test_Behaviour,
				actod.make_actor_config(),
			)
		}
}

Spawn_Config :: struct {
	crash_reason: actod.Termination_Reason,
}

make_terminating_child_spawner :: proc(reason: actod.Termination_Reason) -> actod.SPAWN {
	#partial switch reason {
	case .NORMAL:
		return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
				data := Crash_Test_Data {
					id           = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
					crash_on_msg = "terminate_self",
					crash_reason = .NORMAL,
				}
				return actod.spawn_child(
					fmt.tprintf("self-term-child-%d", data.id),
					data,
					Crash_Test_Behaviour,
					actod.make_actor_config(),
				)
			}
	case .INTERNAL_ERROR:
		return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
				data := Crash_Test_Data {
					id           = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
					crash_on_msg = "terminate_self",
					crash_reason = .INTERNAL_ERROR,
				}
				return actod.spawn_child(
					fmt.tprintf("self-term-child-%d", data.id),
					data,
					Crash_Test_Behaviour,
					actod.make_actor_config(),
				)
			}
	case .ABNORMAL:
		return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
				data := Crash_Test_Data {
					id           = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
					crash_on_msg = "terminate_self",
					crash_reason = .ABNORMAL,
				}
				return actod.spawn_child(
					fmt.tprintf("self-term-child-%d", data.id),
					data,
					Crash_Test_Behaviour,
					actod.make_actor_config(),
				)
			}
	case:
		panic("Unhandled termination reason")
	}
}

test_supervisor_child_lifecycle :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	for _ in 0 ..< 3 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 1,
	}
	supervisor_pid, ok := actod.spawn(
		"test-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
			restart_window = 1 * time.Second,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 3, 500), "Children should be spawned")

	verify_child_count(t, supervisor_pid, 3)

	children := actod.get_children(supervisor_pid)
	defer delete(children)

	for child_pid in children {
		err := actod.send_message(child_pid, "ping")
		testing.expect(t, err == .OK, "Failed to send ping")
	}

	if len(children) > 0 {
		old_child := children[0]
		err := actod.send_message(old_child, "crash")
		testing.expect(t, err == .OK, "Failed to send crash message")

		new_pid, success := wait_for_child_pid_change(supervisor_pid, old_child, 0, 500)
		testing.expect(t, success, "Child should have restarted with new PID")

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		testing.expect_value(t, len(new_children), 3)

		found_old := false
		for pid in new_children {
			if pid == old_child {
				found_old = true
				break
			}
		}
		testing.expect(t, !found_old, "Old child PID should not exist")
		testing.expect(t, new_pid != old_child, "Child should have new PID after restart")
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_one_for_one_strategy :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	for _ in 0 ..< 3 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 2,
	}
	supervisor_pid, ok := actod.spawn(
		"one-for-one-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 3, 500), "Children should be spawned")

	initial_children := actod.get_children(supervisor_pid)
	defer delete(initial_children)
	testing.expect_value(t, len(initial_children), 3)

	if len(initial_children) >= 2 {
		old_middle := initial_children[1]
		err := actod.send_message(old_middle, "crash")
		testing.expect(t, err == .OK, "Failed to crash child")

		new_middle, success := wait_for_child_pid_change(supervisor_pid, old_middle, 1, 500)
		testing.expect(t, success, "Middle child should restart")

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		testing.expect_value(t, len(new_children), 3)
		testing.expect_value(t, new_children[0], initial_children[0])
		testing.expect(t, new_middle != old_middle, "Middle child should have new PID")
		testing.expect_value(t, new_children[2], initial_children[2])
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_one_for_all_strategy :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	for _ in 0 ..< 3 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 3,
	}
	supervisor_pid, ok := actod.spawn(
		"one-for-all-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ALL,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 3, 500), "Children should be spawned")

	initial_children := actod.get_children(supervisor_pid)
	defer delete(initial_children)
	testing.expect_value(t, len(initial_children), 3)

	if len(initial_children) > 0 {
		err := actod.send_message(initial_children[0], "crash")
		testing.expect(t, err == .OK, "Failed to crash child")

		time.sleep(300 * time.Millisecond)

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		testing.expect_value(t, len(new_children), 3)
		for new_pid, i in new_children {
			testing.expect(
				t,
				new_pid != initial_children[i],
				fmt.tprintf("Child %d should have new PID", i),
			)
		}
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_rest_for_one_strategy :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	for _ in 0 ..< 5 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 4,
	}
	supervisor_pid, ok := actod.spawn(
		"rest-for-one-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .REST_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 5, 500), "Children should be spawned")

	initial_children := actod.get_children(supervisor_pid)
	defer delete(initial_children)
	testing.expect_value(t, len(initial_children), 5)

	if len(initial_children) >= 3 {
		err := actod.send_message(initial_children[1], "crash")
		testing.expect(t, err == .OK, "Failed to crash child")

		time.sleep(300 * time.Millisecond)

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		testing.expect_value(t, len(new_children), 5)
		testing.expect_value(t, new_children[0], initial_children[0])

		for i in 1 ..< 5 {
			testing.expect(
				t,
				new_children[i] != initial_children[i],
				fmt.tprintf("Child %d should have new PID", i),
			)
		}
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_restart_limit_within_window :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	append(&child_spawns, create_crash_child(0))

	supervisor_data := Supervisor_Test_Data {
		id = 5,
	}
	supervisor_pid, ok := actod.spawn(
		"restart-limit-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 3,
			restart_window = 1 * time.Second,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)

	for i in 0 ..< 4 {
		children := actod.get_children(supervisor_pid)
		defer delete(children)

		if len(children) > 0 {
			err := actod.send_message(children[0], "crash")
			if i < 3 {
				testing.expect(
					t,
					err == .OK,
					fmt.tprintf("Failed to crash child attempt %d", i + 1),
				)
				time.sleep(100 * time.Millisecond)

				new_children := actod.get_children(supervisor_pid)
				defer delete(new_children)
				testing.expect_value(t, len(new_children), 1)
			} else {
				time.sleep(100 * time.Millisecond)

				final_children := actod.get_children(supervisor_pid)
				defer delete(final_children)
				testing.expect_value(t, len(final_children), 0)
			}
		}
	}

	testing.expect(
		t,
		actod.valid(&actod.global_registry, supervisor_pid),
		"Supervisor should still be running",
	)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})

	for i := 0; i < 20; i += 1 {
		if !actod.valid(&actod.global_registry, supervisor_pid) {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
}

test_restart_limit_window_reset :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	append(&child_spawns, create_crash_child(0))

	supervisor_data := Supervisor_Test_Data {
		id = 6,
	}
	supervisor_pid, ok := actod.spawn(
		"window-reset-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 2,
			restart_window = 200 * time.Millisecond,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 500), "Child should be spawned")

	for i in 0 ..< 2 {
		children := actod.get_children(supervisor_pid)
		defer delete(children)

		if len(children) > 0 {
			actod.send_message(children[0], "crash")
			testing.expect(
				t,
				wait_for_child_count(supervisor_pid, 1, 200),
				fmt.tprintf("Child should restart on attempt %d", i + 1),
			)
		}
	}

	time.sleep(250 * time.Millisecond)

	children := actod.get_children(supervisor_pid)
	defer delete(children)

	if len(children) > 0 {
		err := actod.send_message(children[0], "crash")
		testing.expect(t, err == .OK, "Failed to crash after window")

		restarted := wait_for_child_count(supervisor_pid, 1, 500)
		testing.expect(t, restarted, "Child should restart after window reset")

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)
		testing.expect_value(t, len(new_children), 1)
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})

	for i := 0; i < 20; i += 1 {
		if !actod.valid(&actod.global_registry, supervisor_pid) {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
}

test_permanent_restart_policy :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	append(&child_spawns, create_crash_child(0))

	supervisor_data := Supervisor_Test_Data {
		id = 7,
	}
	supervisor_pid, ok := actod.spawn(
		"permanent-policy-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 10,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 500), "Child should be spawned")

	test_reasons := []actod.Termination_Reason{.NORMAL, .ABNORMAL, .INTERNAL_ERROR}

	for reason in test_reasons {
		children := actod.get_children(supervisor_pid)
		defer delete(children)

		if len(children) > 0 {
			old_child := children[0]
			err := actod.send_message(old_child, actod.Terminate{reason = reason})
			testing.expect(t, err == .OK, "Failed to terminate child")

			_, success := wait_for_child_pid_change(supervisor_pid, old_child, 0, 500)
			testing.expect(t, success, fmt.tprintf("Child should restart for reason %v", reason))

			new_children := actod.get_children(supervisor_pid)
			defer delete(new_children)
			testing.expect_value(t, len(new_children), 1)
		}
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_transient_restart_policy :: proc(t: ^testing.T) {
	reset_test_state()

	create_transient_child := proc(parent: actod.PID) -> actod.SPAWN {
		return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
				data := Crash_Test_Data {
					id = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
				}
				return actod.spawn_child(
					fmt.tprintf("transient-child-%d", data.id),
					data,
					Crash_Test_Behaviour,
					actod.make_actor_config(restart_policy = .TRANSIENT),
				)
			}
	}

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)
	append(&child_spawns, create_transient_child(0))

	supervisor_data := Supervisor_Test_Data {
		id = 8,
	}
	supervisor_pid, ok := actod.spawn(
		"transient-policy-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .TRANSIENT,
			max_restarts = 10,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 500), "Child should be spawned")

	children := actod.get_children(supervisor_pid)
	defer delete(children)

	if len(children) > 0 {
		old_child := children[0]
		err := actod.send_message(old_child, actod.Terminate{reason = .NORMAL})
		testing.expect(t, err == .OK, "Failed to terminate normally")

		no_child := wait_for_child_count(supervisor_pid, 0, 300)
		testing.expect(t, no_child, "TRANSIENT child should NOT restart on NORMAL termination")
	}

	actod.add_child(supervisor_pid, create_transient_child(0))
	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 500), "New child should be added")

	children2 := actod.get_children(supervisor_pid)
	defer delete(children2)

	if len(children2) > 0 {
		old_child := children2[0]
		msg := Integration_Test_Message {
			id      = 999,
			payload = "cause_abnormal",
		}
		actod.send_message(old_child, msg)
		actod.send_message(old_child, actod.Terminate{reason = .ABNORMAL})

		_, success := wait_for_child_pid_change(supervisor_pid, old_child, 0, 500)
		testing.expect(t, success, "TRANSIENT child should restart on ABNORMAL termination")

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)
		testing.expect_value(t, len(new_children), 1)
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})

	for i := 0; i < 20; i += 1 {
		if !actod.valid(&actod.global_registry, supervisor_pid) {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
}

test_add_child_dynamically :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	for _ in 0 ..< 2 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 9,
	}
	supervisor_pid, ok := actod.spawn(
		"dynamic-add-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)
	verify_child_count(t, supervisor_pid, 2)

	_, add_ok := actod.add_child(supervisor_pid, create_crash_child(0))
	testing.expect(t, add_ok, "Failed to add child dynamically")

	count_ok := wait_for_child_count(supervisor_pid, 3, 500)
	testing.expect(t, count_ok, "Child count did not increase to 3 within timeout")
	verify_child_count(t, supervisor_pid, 3)

	new_children := actod.get_children(supervisor_pid)
	defer delete(new_children)
	testing.expect_value(t, len(new_children), 3)

	new_child_pid := new_children[2]

	err := actod.send_message(new_child_pid, "ping")
	testing.expect(t, err == .OK, "Failed to send to new child")

	err = actod.send_message(new_child_pid, "crash")
	testing.expect(t, err == .OK, "Failed to crash new child")

	time.sleep(150 * time.Millisecond)
	verify_child_count(t, supervisor_pid, 3)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_remove_child_dynamically :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns: [dynamic]actod.SPAWN
	defer delete(child_spawns)

	for _ in 0 ..< 3 {
		append(&child_spawns, create_crash_child(0))
	}

	supervisor_data := Supervisor_Test_Data {
		id = 10,
	}
	supervisor_pid, ok := actod.spawn(
		"dynamic-remove-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
		),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)
	verify_child_count(t, supervisor_pid, 3)

	children := actod.get_children(supervisor_pid)
	defer delete(children)

	if len(children) >= 2 {
		middle_child := children[1]

		remove_ok := actod.remove_child(supervisor_pid, middle_child)
		testing.expect(t, remove_ok, "Failed to remove child")

		count_ok := wait_for_child_count(supervisor_pid, 2, 500)
		testing.expect(t, count_ok, "Child count did not reduce to 2 within timeout")

		verify_child_count(t, supervisor_pid, 2)

		for i := 0; i < 50; i += 1 {
			if !actod.valid(&actod.global_registry, middle_child) {
				break
			}
			time.sleep(10 * time.Millisecond)
		}

		testing.expect(
			t,
			!actod.valid(&actod.global_registry, middle_child),
			"Removed child should be invalid",
		)

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		for child_pid in new_children {
			err := actod.send_message(child_pid, "ping")
			testing.expect(t, err == .OK, "Remaining children should still work")
		}
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_adopt_existing_actor :: proc(t: ^testing.T) {
	reset_test_state()

	supervisor_data := Supervisor_Test_Data {
		id = 11,
	}
	supervisor_pid, ok := actod.spawn(
		"adopt-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(supervision_strategy = .ONE_FOR_ONE, restart_policy = .PERMANENT),
	)
	testing.expect(t, ok, "Failed to spawn supervisor")

	orphan_data := Crash_Test_Data {
		id           = 100,
		crash_on_msg = "crash",
		crash_reason = .INTERNAL_ERROR,
	}
	orphan_pid, orphan_ok := actod.spawn(
		"orphan-actor",
		orphan_data,
		Crash_Test_Behaviour,
		actod.make_actor_config(),
		0,
	)
	testing.expect(t, orphan_ok, "Failed to spawn orphan actor")

	time.sleep(50 * time.Millisecond)

	orphan_spawn := proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
		data := Crash_Test_Data {
			id           = 100,
			crash_on_msg = "crash",
			crash_reason = .INTERNAL_ERROR,
		}
		return actod.spawn_child(
			"orphan-actor-restarted",
			data,
			Crash_Test_Behaviour,
			actod.make_actor_config(),
		)
	}

	_, adopt_ok := actod.add_child_existing(supervisor_pid, orphan_pid, orphan_spawn)
	testing.expect(t, adopt_ok, "Failed to adopt orphan actor")

	count_ok := wait_for_child_count(supervisor_pid, 1, 500)
	testing.expect(t, count_ok, "Supervisor did not adopt child within timeout")

	children := actod.get_children(supervisor_pid)
	defer delete(children)
	testing.expect_value(t, len(children), 1)
	testing.expect_value(t, children[0], orphan_pid)

	err := actod.send_message(orphan_pid, "crash")
	testing.expect(t, err == .OK, "Failed to crash adopted child")

	time.sleep(200 * time.Millisecond)

	new_children := actod.get_children(supervisor_pid)
	defer delete(new_children)
	testing.expect_value(t, len(new_children), 1)
	testing.expect(
		t,
		new_children[0] != orphan_pid,
		"Adopted child should have new PID after restart",
	)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_self_termination_reasons :: proc(t: ^testing.T) {
	reset_test_state()

	reasons_to_test := []actod.Termination_Reason{.NORMAL, .INTERNAL_ERROR, .ABNORMAL}

	for test_reason in reasons_to_test {
		create_terminating_child := make_terminating_child_spawner(test_reason)

		supervisor_data := Supervisor_Test_Data {
			id = 100 + int(test_reason),
		}
		supervisor_pid, ok := actod.spawn(
			fmt.tprintf("reason-test-supervisor-%d", test_reason),
			supervisor_data,
			Supervisor_Test_Behaviour,
			actod.make_actor_config(
				supervision_strategy = .ONE_FOR_ONE,
				restart_policy = .TEMPORARY,
			),
		)
		testing.expect(t, ok, "Failed to spawn supervisor")

		child_pid, add_ok := actod.add_child(supervisor_pid, create_terminating_child)
		testing.expect(t, add_ok, "Failed to add child")

		time.sleep(50 * time.Millisecond)

		actod.send_message(child_pid, "terminate_self")

		time.sleep(100 * time.Millisecond)

		actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
		time.sleep(50 * time.Millisecond)
	}
}
