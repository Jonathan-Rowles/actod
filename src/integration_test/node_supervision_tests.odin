package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

NODE_CRASH_CHILD_NAME :: "node-crash-child"
NODE_DYNAMIC_CHILD_NAME :: "node-dynamic-child"

blocking_child_terminated: bool

spawn_node_crash_child :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	data := Crash_Test_Data {
		crash_on_msg = "crash",
		crash_reason = .INTERNAL_ERROR,
	}
	return actod.spawn(NODE_CRASH_CHILD_NAME, data, Crash_Test_Behaviour, parent_pid = parent)
}

spawn_node_dynamic_child :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	data := Crash_Test_Data {
		crash_on_msg = "crash",
		crash_reason = .INTERNAL_ERROR,
	}
	return actod.spawn(NODE_DYNAMIC_CHILD_NAME, data, Crash_Test_Behaviour, parent_pid = parent)
}

Named_Pid_Probe :: struct {
	name:    string,
	old_pid: actod.PID,
	new_pid: actod.PID,
}

named_pid_changed :: proc(state: rawptr) -> bool {
	probe := cast(^Named_Pid_Probe)state
	pid, ok := actod.get_actor_pid(probe.name)
	if !ok || pid == probe.old_pid do return false
	probe.new_pid = pid
	return true
}

wait_for_named_pid_change :: proc(name: string, old_pid: actod.PID, timeout: time.Duration) -> (actod.PID, bool) {
	probe := Named_Pid_Probe{name = name, old_pid = old_pid}
	if poll_until(named_pid_changed, &probe, timeout, time.Millisecond) do return probe.new_pid, true
	return 0, false
}

restart_node_with :: proc(name: string, children: [dynamic]actod.SPAWN, max_restarts: int, blocking_child: actod.SPAWN = nil) {
	actod.shutdown_node()
	actod.node_init(
		name,
		actod.make_node_config(
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = test_log_level()),
				children = children,
				max_restarts = max_restarts,
				restart_window = 5 * time.Second,
			),
			blocking_child = blocking_child,
		),
	)
}

crash_named_child :: proc(t: ^testing.T, name: string) -> (old_pid: actod.PID, ok: bool) {
	old_pid, ok = actod.get_actor_pid(name)
	if !ok {
		expectf(t, false, "%s is not running", name)
		return
	}
	err := actod.send_message(old_pid, "crash")
	expectf(t, err == .OK, "crash send to %s failed: %v", name, err)
	return old_pid, err == .OK
}

test_node_child_restarts :: proc(t: ^testing.T) {
	reset_test_state()
	restart_node_with("node-restart", actod.make_children(spawn_node_crash_child), 10)
	wait_for_node()

	first_pid, ok := crash_named_child(t, NODE_CRASH_CHILD_NAME)
	if !ok do return
	restarted_pid, restarted := wait_for_named_pid_change(NODE_CRASH_CHILD_NAME, first_pid, 2 * time.Second)
	expect(t, restarted, "a declared node child must be restarted after an abnormal exit")
	expect(t, restarted_pid != first_pid, "the restarted child must have a new pid")

	node_pid := actod.get_local_node_pid()
	expect(t, actod.add_child(node_pid, spawn_node_dynamic_child), "add_child on the node pid")
	dynamic_pid, appeared := wait_for_named_pid_change(NODE_DYNAMIC_CHILD_NAME, 0, 2 * time.Second)
	expect(t, appeared, "the dynamically added node child must start")

	expect(t, wait_for_child_count(node_pid, 2, 1000), "get_children(node) must list both supervised children")
	children := actod.get_children(node_pid)
	defer delete(children)
	for child in children do expect(t, child != actod.NODE.timer_pid, "get_children(node) must list user children, not system actors")

	_, crashed := crash_named_child(t, NODE_DYNAMIC_CHILD_NAME)
	if !crashed do return
	_, dynamic_restarted := wait_for_named_pid_change(NODE_DYNAMIC_CHILD_NAME, dynamic_pid, 2 * time.Second)
	expect(t, dynamic_restarted, "a node child added with add_child must be restarted too")

	actod.shutdown_node()
}

test_node_child_max_restarts_shuts_down_node :: proc(t: ^testing.T) {
	reset_test_state()
	restart_node_with("node-escalation", actod.make_children(spawn_node_crash_child), 1)
	wait_for_node()

	first_pid, ok := crash_named_child(t, NODE_CRASH_CHILD_NAME)
	if !ok do return
	second_pid, restarted := wait_for_named_pid_change(NODE_CRASH_CHILD_NAME, first_pid, 2 * time.Second)
	expect(t, restarted, "the first crash is within budget and must restart")
	expect(t, !sync.atomic_load(&actod.NODE.shutting_down), "one restart must not shut the node down")

	_ = second_pid
	thread.create_and_start(proc() {
		time.sleep(50 * time.Millisecond)
		pid, ok := actod.get_actor_pid(NODE_CRASH_CHILD_NAME)
		if ok do _ = actod.send_message(pid, "crash")
	})

	started := time.tick_now()
	actod.await_signal()
	elapsed := time.tick_since(started)

	expectf(t, elapsed < 2 * time.Second, "await_signal took %v to return after escalation", elapsed)
	expect(t, !actod.NODE.started, "await_signal must have shut the node down after the second crash")
}

Blocking_Test_Data :: struct {
	on_init: proc(),
}

blocking_test_init :: proc(data: ^Blocking_Test_Data) {
	data.on_init()
}

blocking_test_handle :: proc(data: ^Blocking_Test_Data, from: actod.PID, msg: any) {}

blocking_test_terminate :: proc(data: ^Blocking_Test_Data) {
	sync.atomic_store(&blocking_child_terminated, true)
}

Blocking_Test_Behaviour :: actod.Actor_Behaviour(Blocking_Test_Data) {
	init           = blocking_test_init,
	handle_message = blocking_test_handle,
	terminate      = blocking_test_terminate,
}

spawn_blocking_signal_child :: proc(_name: string, _parent: actod.PID) -> (actod.PID, bool) {
	return actod.spawn("blocking-signal-child", Blocking_Test_Data{on_init = raise_sigint_to_self}, Blocking_Test_Behaviour)
}

crash_sibling_from_blocking_child :: proc() {
	pid, ok := actod.get_actor_pid(NODE_CRASH_CHILD_NAME)
	if ok do _ = actod.send_message(pid, "crash")
}

spawn_blocking_escalation_child :: proc(_name: string, _parent: actod.PID) -> (actod.PID, bool) {
	return actod.spawn("blocking-escalation-child", Blocking_Test_Data{on_init = crash_sibling_from_blocking_child}, Blocking_Test_Behaviour)
}

test_blocking_child_stops_on_signal :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	reset_test_state()
	sync.atomic_store(&blocking_child_terminated, false)

	started := time.tick_now()
	restart_node_with("blocking-signal", nil, 3, spawn_blocking_signal_child)
	elapsed := time.tick_since(started)

	expectf(t, elapsed < 2 * time.Second, "node_init took %v to return after SIGINT", elapsed)
	expect(t, sync.atomic_load(&blocking_child_terminated), "the blocking child's terminate callback must run on SIGINT")
	expect(t, !sync.atomic_load(&actod.NODE.shutting_down), "a signal must not mark the node shutting down before node_shutdown is called")

	actod.shutdown_node()
}

Foreign_Wait_Data :: struct {
	gate:     sync.Sema,
	timeouts: int,
}

foreign_wait_idle :: proc(data: ^Foreign_Wait_Data) {
	if !sync.sema_wait_with_timeout(&data.gate, 5 * time.Second) do data.timeouts += 1
}

foreign_wait_wake :: proc "contextless" (data: ^Foreign_Wait_Data) {
	sync.sema_post(&data.gate)
}

foreign_wait_handle :: proc(data: ^Foreign_Wait_Data, from: actod.PID, msg: any) {}

foreign_wait_terminate :: proc(data: ^Foreign_Wait_Data) {
	sync.atomic_store(&blocking_child_terminated, true)
	sync.atomic_store(&foreign_wait_timeouts, data.timeouts)
}

foreign_wait_timeouts: int

Foreign_Wait_Behaviour :: actod.Actor_Behaviour(Foreign_Wait_Data) {
	handle_message = foreign_wait_handle,
	terminate      = foreign_wait_terminate,
	on_idle        = foreign_wait_idle,
	on_wake        = foreign_wait_wake,
}

spawn_foreign_wait_child :: proc(_name: string, _parent: actod.PID) -> (actod.PID, bool) {
	raise_sigint_to_self_after(50 * time.Millisecond)
	return actod.spawn("blocking-foreign-wait-child", Foreign_Wait_Data{}, Foreign_Wait_Behaviour)
}

test_blocking_child_signal_interrupts_foreign_wait :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	reset_test_state()
	sync.atomic_store(&blocking_child_terminated, false)
	sync.atomic_store(&foreign_wait_timeouts, 0)

	started := time.tick_now()
	restart_node_with("blocking-foreign-wait", nil, 3, spawn_foreign_wait_child)
	elapsed := time.tick_since(started)

	expectf(t, elapsed < 2 * time.Second, "node_init took %v to return after SIGINT into a foreign wait", elapsed)
	expect(t, sync.atomic_load(&blocking_child_terminated), "the terminate callback must run")
	expect_value(t, sync.atomic_load(&foreign_wait_timeouts), 0)

	actod.shutdown_node()
}

test_blocking_child_stops_on_escalation :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&blocking_child_terminated, false)

	started := time.tick_now()
	restart_node_with("blocking-escalation", actod.make_children(spawn_node_crash_child), 0, spawn_blocking_escalation_child)
	elapsed := time.tick_since(started)

	expectf(t, elapsed < 2 * time.Second, "node_init took %v to return after escalation", elapsed)
	expect(t, sync.atomic_load(&blocking_child_terminated), "escalation must stop the blocking child through its terminate callback")
	expect(t, sync.atomic_load(&actod.NODE.shutting_down), "escalation must mark the node shutting down")

	actod.shutdown_node()
}
