package integration

import "../actod"
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
			_ = actod.send_message(from, "pong")
		}

	case Integration_Test_Message:
		sync.atomic_add(&global_test_state.messages_received, 1)
		_ = actod.send_message(from, m)
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
	init                = supervisor_test_init,
	handle_message      = supervisor_test_handle_message,
	terminate           = supervisor_test_terminate,
	on_child_terminated = supervisor_test_on_child_terminated,
}

supervisor_test_on_child_terminated :: proc(
	data: ^Supervisor_Test_Data,
	child_pid: actod.PID,
	child_name: string,
	reason: actod.Termination_Reason,
	will_restart: bool,
) {
	g_last_stop_name_len = copy(g_last_stop_name[:], child_name)
	sync.atomic_store(&g_last_stop_reason, i32(reason))
	sync.atomic_add(&g_stops_observed, 1)
}

supervisor_test_init :: proc(data: ^Supervisor_Test_Data) {
	sync.atomic_add(&global_test_state.actors_spawned, 1)
}

@(private = "file")
g_stops_observed: u64
@(private = "file")
g_last_stop_reason: i32
@(private = "file")
g_last_stop_name: [64]u8
@(private = "file")
g_last_stop_name_len: int

supervisor_test_handle_message :: proc(data: ^Supervisor_Test_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case actod.Actor_Stopped:
		data.restarts_seen += 1
		data.last_stopped_child = m.child_pid
		data.last_stop_reason = m.reason

	case string:
		if m == "get_stats" {
			stats := fmt.tprintf("restarts=%d", data.restarts_seen)
			_ = actod.send_message(from, stats)
		}
	}
}

supervisor_test_terminate :: proc(data: ^Supervisor_Test_Data) {
	sync.atomic_add(&global_test_state.actors_terminated, 1)
}

Registry_Probe :: struct {
	pid: actod.PID,
}

Child_Count_Probe :: struct {
	parent:   actod.PID,
	expected: int,
}

Child_Change_Probe :: struct {
	parent:  actod.PID,
	old_pid: actod.PID,
	index:   int,
	new_pid: actod.PID,
}

Children_Replaced_Probe :: struct {
	parent: actod.PID,
	old:    []actod.PID,
	from:   int,
}

Slot_Restart_Probe :: struct {
	parent:   actod.PID,
	previous: []actod.PID,
	index:    int,
	new_pid:  actod.PID,
}

plain_condition_holds :: proc(state: rawptr) -> bool {
	condition := (cast(^proc() -> bool)state)^
	return condition()
}

actor_gone :: proc(state: rawptr) -> bool {
	probe := cast(^Registry_Probe)state
	return !actod.valid(&actod.NODE.actor_registry, probe.pid)
}

child_count_matches :: proc(state: rawptr) -> bool {
	probe := cast(^Child_Count_Probe)state
	children := actod.get_children(probe.parent)
	defer delete(children)
	return len(children) == probe.expected
}

child_pid_changed :: proc(state: rawptr) -> bool {
	probe := cast(^Child_Change_Probe)state
	children := actod.get_children(probe.parent)
	defer delete(children)
	if len(children) > probe.index && children[probe.index] != probe.old_pid {
		probe.new_pid = children[probe.index]
		return true
	}
	return false
}

child_restarted_in_slot :: proc(state: rawptr) -> bool {
	probe := cast(^Slot_Restart_Probe)state
	children := actod.get_children(probe.parent)
	defer delete(children)
	if len(children) != len(probe.previous) do return false
	candidate := children[probe.index]
	for previous_pid in probe.previous {
		if candidate == previous_pid do return false
	}
	if !actod.valid(&actod.NODE.actor_registry, candidate) do return false
	probe.new_pid = candidate
	return true
}

wait_for_condition :: proc(condition: proc() -> bool, timeout_ms: int) -> bool {
	held := condition
	return poll_until(
		plain_condition_holds,
		&held,
		time.Duration(timeout_ms) * time.Millisecond,
		time.Millisecond,
	)
}

wait_for_child_count :: proc(parent: actod.PID, expected: int, timeout_ms: int) -> bool {
	probe := Child_Count_Probe{parent = parent, expected = expected}
	return poll_until(child_count_matches, &probe, time.Duration(timeout_ms) * time.Millisecond)
}

wait_for_actor_invalid :: proc(pid: actod.PID, timeout_ms: int) -> bool {
	probe := Registry_Probe{pid = pid}
	return poll_until(actor_gone, &probe, time.Duration(timeout_ms) * time.Millisecond)
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
	probe := Child_Change_Probe{parent = parent, old_pid = old_pid, index = index}
	changed := poll_until(child_pid_changed, &probe, time.Duration(timeout_ms) * time.Millisecond)
	if changed do return probe.new_pid, true
	return 0, false
}

wait_for_child_restart :: proc(
	parent: actod.PID,
	previous: []actod.PID,
	index: int,
	timeout_ms: int,
) -> (
	new_pid: actod.PID,
	success: bool,
) {
	probe := Slot_Restart_Probe{parent = parent, previous = previous, index = index}
	restarted := poll_until(child_restarted_in_slot, &probe, time.Duration(timeout_ms) * time.Millisecond)
	if restarted do return probe.new_pid, true
	return 0, false
}

children_replaced :: proc(state: rawptr) -> bool {
	probe := cast(^Children_Replaced_Probe)state
	children := actod.get_children(probe.parent)
	defer delete(children)
	if len(children) != len(probe.old) do return false
	for i in probe.from ..< len(children) {
		if children[i] == probe.old[i] do return false
	}
	return true
}

wait_for_children_replaced :: proc(
	parent: actod.PID,
	old: []actod.PID,
	from: int,
	timeout_ms: int,
) -> bool {
	probe := Children_Replaced_Probe{parent = parent, old = old, from = from}
	return poll_until(children_replaced, &probe, time.Duration(timeout_ms) * time.Millisecond)
}

verify_child_count :: proc(t: ^testing.T, parent: actod.PID, expected: int) {
	children := actod.get_children(parent)
	defer delete(children)
	expect_value(t, len(children), expected)
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
				actod.make_actor_config(restart_policy = .PERMANENT),
			)
		}
}

create_temporary_crash_child :: proc() -> actod.SPAWN {
	return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
			data := Crash_Test_Data {
				id           = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
				crash_on_msg = "crash",
				crash_reason = .INTERNAL_ERROR,
			}
			return actod.spawn_child(
				fmt.tprintf("temporary-crash-child-%d", data.id),
				data,
				Crash_Test_Behaviour,
				actod.make_actor_config(restart_policy = .TEMPORARY),
			)
		}
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
			max_restarts = 3,
			restart_window = 1 * time.Second,
		),
	)
	expect(t, ok, "Failed to spawn supervisor")

	expect(t, wait_for_child_count(supervisor_pid, 1, 500), "Child should be spawned")

	for i in 0 ..< 4 {
		children := actod.get_children(supervisor_pid)
		defer delete(children)

		child_expected := i < 3
		if child_expected && !expectf(t, len(children) > 0, "child missing before crash %d", i + 1) {
			break
		}
		if len(children) > 0 {
			err := actod.send_message(children[0], "crash")
			if i < 3 {
				expect(
					t,
					err == .OK,
					fmt.tprintf("Failed to crash child attempt %d", i + 1),
				)
				_, restarted := wait_for_child_pid_change(supervisor_pid, children[0], 0, 1000)
				expectf(t, restarted, "child should restart after crash %d", i + 1)

				new_children := actod.get_children(supervisor_pid)
				defer delete(new_children)
				expect_value(t, len(new_children), 1)
			} else {
				expect(
					t,
					wait_for_child_count(supervisor_pid, 0, 1000),
					"child should be dropped once max_restarts is exceeded",
				)

				final_children := actod.get_children(supervisor_pid)
				defer delete(final_children)
				expect_value(t, len(final_children), 0)
			}
		}
	}

	expect(
		t,
		actod.valid(&actod.NODE.actor_registry, supervisor_pid),
		"Supervisor should still be running",
	)

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})

	for i := 0; i < 20; i += 1 {
		if !actod.valid(&actod.NODE.actor_registry, supervisor_pid) {
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
			max_restarts = 2,
			restart_window = 200 * time.Millisecond,
		),
	)
	expect(t, ok, "Failed to spawn supervisor")

	expect(t, wait_for_child_count(supervisor_pid, 1, 500), "Child should be spawned")

	for i in 0 ..< 2 {
		children := actod.get_children(supervisor_pid)
		defer delete(children)

		if !expectf(t, len(children) > 0, "child missing before crash %d", i + 1) {
			break
		}
		if len(children) > 0 {
			_ = actod.send_message(children[0], "crash")
			expect(
				t,
				wait_for_child_count(supervisor_pid, 1, 200),
				fmt.tprintf("Child should restart on attempt %d", i + 1),
			)
		}
	}

	time.sleep(250 * time.Millisecond)

	children := actod.get_children(supervisor_pid)
	defer delete(children)

	expect(t, len(children) > 0, "child missing after window reset")
	if len(children) > 0 {
		err := actod.send_message(children[0], "crash")
		expect(t, err == .OK, "Failed to crash after window")

		restarted := wait_for_child_count(supervisor_pid, 1, 500)
		expect(t, restarted, "Child should restart after window reset")

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)
		expect_value(t, len(new_children), 1)
	}

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})

	for i := 0; i < 20; i += 1 {
		if !actod.valid(&actod.NODE.actor_registry, supervisor_pid) {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
}

spawn_policy_child :: proc(restart_policy: actod.Restart_Policy) -> (actod.PID, bool) {
	data := Crash_Test_Data {
		id = int(sync.atomic_add(&global_test_state.actors_spawned, 1)),
	}
	return actod.spawn_child(
		fmt.tprintf("%v-child-%d", restart_policy, data.id),
		data,
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = restart_policy),
	)
}

spawn_permanent_policy_child :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_policy_child(.PERMANENT)
}

spawn_transient_policy_child :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_policy_child(.TRANSIENT)
}

spawn_temporary_policy_child :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_policy_child(.TEMPORARY)
}

test_children_restart_by_their_own_policy :: proc(t: ^testing.T) {
	reset_test_state()

	child_spawns := actod.make_children(
		spawn_permanent_policy_child,
		spawn_transient_policy_child,
		spawn_transient_policy_child,
		spawn_temporary_policy_child,
	)
	defer delete(child_spawns)

	supervisor_pid, ok := actod.spawn(
		"mixed-policy-supervisor",
		Supervisor_Test_Data{id = 20},
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			children = child_spawns,
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .TEMPORARY,
			max_restarts = 10,
		),
	)
	expect(t, ok, "Failed to spawn supervisor")
	if !ok do return
	expect(t, wait_for_child_count(supervisor_pid, 4, 500), "Children should be spawned")

	initial := actod.get_children(supervisor_pid)
	defer delete(initial)
	if !expectf(t, len(initial) == 4, "expected 4 children, got %d", len(initial)) do return

	_ = actod.send_message(initial[0], actod.Terminate{reason = .NORMAL})
	new_permanent, permanent_restarted := wait_for_child_restart(supervisor_pid, initial, 0, 1000)
	expect(
		t,
		permanent_restarted,
		"a PERMANENT child must restart after a NORMAL exit under a TEMPORARY supervisor",
	)

	after_permanent := actod.get_children(supervisor_pid)
	defer delete(after_permanent)
	_ = actod.send_message(initial[1], actod.Terminate{reason = .ABNORMAL})
	new_transient, transient_restarted := wait_for_child_restart(supervisor_pid, after_permanent, 1, 1000)
	expect(
		t,
		transient_restarted,
		"a TRANSIENT child must restart after an ABNORMAL exit under a TEMPORARY supervisor",
	)

	transient_name_buf: [64]u8
	transient_name := string(transient_name_buf[:copy(transient_name_buf[:], actod.get_actor_name(initial[2]))])
	temporary_name_buf: [64]u8
	temporary_name := string(temporary_name_buf[:copy(temporary_name_buf[:], actod.get_actor_name(initial[3]))])

	_ = actod.send_message(initial[2], actod.Terminate{reason = .NORMAL})
	expect(
		t,
		wait_for_child_count(supervisor_pid, 3, 1000),
		"a TRANSIENT child must not restart after a NORMAL exit",
	)
	expect_value(t, actod.Termination_Reason(sync.atomic_load(&g_last_stop_reason)), actod.Termination_Reason.NORMAL)
	expect_value(t, string(g_last_stop_name[:g_last_stop_name_len]), transient_name)

	_ = actod.send_message(initial[3], actod.Terminate{reason = .ABNORMAL})
	expect(
		t,
		wait_for_child_count(supervisor_pid, 2, 1000),
		"a TEMPORARY child must not restart even after an ABNORMAL exit",
	)
	expect_value(t, actod.Termination_Reason(sync.atomic_load(&g_last_stop_reason)), actod.Termination_Reason.ABNORMAL)
	expect_value(t, string(g_last_stop_name[:g_last_stop_name_len]), temporary_name)

	final := actod.get_children(supervisor_pid)
	defer delete(final)
	if expectf(t, len(final) == 2, "expected 2 children left, got %d", len(final)) {
		expect_value(t, final[0], new_permanent)
		expect_value(t, final[1], new_transient)
	}

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	expect(t, wait_for_actor_invalid(supervisor_pid, 1000), "supervisor should stop")
}

ORDER_CHILD_COUNT :: 5

Order_Supervisor_Data :: struct {
	orders_spawned: int,
}

@(private = "file")
g_order_restarts: i32
@(private = "file")
g_order_restart_intents: i32
@(private = "file")
g_order_children_len: int
@(private = "file")
g_order_table_reads: i32

Order_Supervisor_Behaviour :: actod.Actor_Behaviour(Order_Supervisor_Data) {
	handle_message = order_supervisor_handle_message,
	on_child_terminated = proc(
		data: ^Order_Supervisor_Data,
		child_pid: actod.PID,
		child_name: string,
		reason: actod.Termination_Reason,
		will_restart: bool,
	) {
		if will_restart do sync.atomic_add(&g_order_restart_intents, 1)
	},
	on_child_restarted = proc(
		data: ^Order_Supervisor_Data,
		old_pid: actod.PID,
		new_pid: actod.PID,
		restart_count: int,
	) {
		sync.atomic_add(&g_order_restarts, 1)
	},
}

order_supervisor_handle_message :: proc(data: ^Order_Supervisor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case string:
		switch m {
		case "spawn_order":
			data.orders_spawned += 1
			_, _ = actod.spawn_child(
				fmt.tprintf("order-%d", data.orders_spawned),
				Crash_Test_Data{crash_on_msg = "done", crash_reason = .NORMAL},
				Crash_Test_Behaviour,
				actod.make_actor_config(restart_policy = .TEMPORARY),
			)
		case "read_tables":
			self := cast(^actod.Actor)actod.get(&actod.NODE.actor_registry, actod.get_self_pid())
			sync.atomic_store(&g_order_children_len, len(self.children))
			sync.atomic_add(&g_order_table_reads, 1)
		}
	}
}

order_tables_read :: proc(state: rawptr) -> bool {
	before := (cast(^i32)state)^
	return sync.atomic_load(&g_order_table_reads) > before
}

test_temporary_direct_child_leaves_permanent_supervisor :: proc(t: ^testing.T) {
	strategies := []actod.Supervision_Strategy{.ONE_FOR_ONE, .ONE_FOR_ALL, .REST_FOR_ONE}
	for strategy in strategies {
		reset_test_state()
		sync.atomic_store(&g_order_restarts, 0)
		sync.atomic_store(&g_order_restart_intents, 0)

		declared := actod.make_children(create_crash_child(0))
		defer delete(declared)

		supervisor_pid, ok := actod.spawn(
			fmt.tprintf("order-supervisor-%v", strategy),
			Order_Supervisor_Data{},
			Order_Supervisor_Behaviour,
			actod.make_actor_config(
				children = declared,
				supervision_strategy = strategy,
				restart_policy = .PERMANENT,
			),
		)
		expectf(t, ok, "%v: failed to spawn supervisor", strategy)
		if !ok do continue
		expectf(t, wait_for_child_count(supervisor_pid, 1, 500), "%v: declared child should start", strategy)

		initial := actod.get_children(supervisor_pid)
		declared_pid := initial[0] if len(initial) > 0 else 0
		delete(initial)

		for _ in 0 ..< ORDER_CHILD_COUNT {
			_ = actod.send_message(supervisor_pid, "spawn_order")
		}
		expectf(
			t,
			wait_for_child_count(supervisor_pid, 1 + ORDER_CHILD_COUNT, 1000),
			"%v: every order child should register",
			strategy,
		)

		orders := actod.get_children(supervisor_pid)
		for order_pid in orders {
			if order_pid != declared_pid do _ = actod.send_message(order_pid, "done")
		}
		delete(orders)

		expectf(
			t,
			wait_for_child_count(supervisor_pid, 1, 1000),
			"%v: a TEMPORARY child ending NORMAL must leave the child list",
			strategy,
		)

		reads_before := sync.atomic_load(&g_order_table_reads)
		_ = actod.send_message(supervisor_pid, "read_tables")
		answered := poll_until(order_tables_read, &reads_before, time.Second)
		expectf(t, answered, "%v: supervisor never read its tables", strategy)
		if answered {
			expect_value(t, sync.atomic_load(&g_order_children_len), 1)
		}

		expect_value(t, sync.atomic_load(&g_order_restart_intents), 0)
		expect_value(t, sync.atomic_load(&g_order_restarts), 0)

		remaining := actod.get_children(supervisor_pid)
		if expectf(t, len(remaining) == 1, "%v: expected only the declared child, got %d", strategy, len(remaining)) {
			expectf(
				t,
				remaining[0] == declared_pid,
				"%v: the declared sibling must not be touched when a TEMPORARY child ends",
				strategy,
			)
		}
		delete(remaining)

		_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
		expectf(t, wait_for_actor_invalid(supervisor_pid, 1000), "%v: supervisor should stop", strategy)
	}
}
