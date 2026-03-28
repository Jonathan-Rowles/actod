package actotest

// Single-actor test harness — isolates one actor and captures all side effects.
// For multi-actor simulation with message routing, use test_harness/sim.

import "../src/actod"
import "./ti"
import "./unit"
import "core:testing"
import "core:time"

Test_Harness :: unit.Test_Harness
Captured_Timer :: ti.Captured_Timer
Captured_Spawn :: ti.Captured_Spawn
Captured_Terminate :: ti.Captured_Terminate
Captured_Rename :: ti.Captured_Rename
Captured_Subscribe :: ti.Captured_Subscribe
Captured_Topic_Subscribe :: ti.Captured_Topic_Subscribe

EXTERNAL_PID :: unit.EXTERNAL_PID

// Lifecycle

// Create a test harness for a single actor with the given initial state and behaviour.
create :: proc(data: $T, behaviour: actod.Actor_Behaviour(T)) -> Test_Harness(T) {
	return unit.create(data, behaviour)
}

// Free all resources owned by the harness.
destroy :: proc(h: ^Test_Harness($T)) {
	unit.destroy(h)
}

// Call the actor's init callback.
init :: proc(h: ^Test_Harness($T)) {
	unit.init(h)
}

// Call the actor's terminate callback.
terminate :: proc(h: ^Test_Harness($T)) {
	unit.terminate(h)
}

// Return the actor's current state.
get_state :: proc(h: ^Test_Harness($T)) -> ^T {
	return unit.get_state(h)
}

// Sending

// Deliver a message to the actor under test.
send :: proc(h: ^Test_Harness($T), msg: $M, from: actod.PID = EXTERNAL_PID) {
	unit.send(h, msg, from)
}

// Configuration

// Register a name→PID mapping so the actor can send by name.
register_pid :: proc(h: ^Test_Harness($T), name: string, pid: actod.PID) {
	unit.register_pid(h, name, pid)
}

// Add a child PID for send_message_to_children.
add_child :: proc(h: ^Test_Harness($T), pid: actod.PID) {
	unit.add_child(h, pid)
}

// Set the parent PID for send_message_to_parent.
set_parent :: proc(h: ^Test_Harness($T), pid: actod.PID) {
	unit.set_parent(h, pid)
}

// Time

// Set the virtual clock to an absolute time.
set_virtual_now :: proc(h: ^Test_Harness($T), t: time.Time) {
	unit.set_virtual_now(h, t)
}

// Advance the virtual clock by a duration.
advance_time :: proc(h: ^Test_Harness($T), d: time.Duration) {
	unit.advance_time(h, d)
}

// Supervision

// Invoke on_child_terminated callback.
simulate_child_terminated :: proc(
	h: ^Test_Harness($T),
	child_pid: actod.PID,
	reason: actod.Termination_Reason,
	will_restart: bool = false,
) {
	unit.simulate_child_terminated(h, child_pid, reason, will_restart)
}

// Invoke on_child_started callback.
simulate_child_started :: proc(h: ^Test_Harness($T), child_pid: actod.PID) {
	unit.simulate_child_started(h, child_pid)
}

// Invoke on_child_restarted callback.
simulate_child_restarted :: proc(
	h: ^Test_Harness($T),
	old_pid: actod.PID,
	new_pid: actod.PID,
	restart_count: int,
) {
	unit.simulate_child_restarted(h, old_pid, new_pid, restart_count)
}

// Invoke on_max_restarts_exceeded callback.
simulate_max_restarts :: proc(h: ^Test_Harness($T), child_pid: actod.PID) {
	unit.simulate_max_restarts(h, child_pid)
}

// Send Assertions

// Assert next send matches type, consume and return the message.
expect_sent :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> M {
	return unit.expect_sent(h, t, M, loc)
}

// Assert next send matches type and target PID, consume and return.
expect_sent_to :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	to: actod.PID,
	$M: typeid,
	loc := #caller_location,
) -> M {
	return unit.expect_sent_to(h, t, to, M, loc)
}

// Assert next send matches type and predicate, consume and return.
expect_sent_where :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	pred: proc(_: M) -> bool,
	loc := #caller_location,
) -> M {
	return unit.expect_sent_where(h, t, M, pred, loc)
}

// Assert no messages were sent.
expect_no_sends :: proc(h: ^Test_Harness($T), t: ^testing.T, loc := #caller_location) {
	unit.expect_no_sends(h, t, loc)
}

// Return the number of captured sends.
sent_count :: proc(h: ^Test_Harness($T)) -> int {
	return unit.sent_count(h)
}

// Discard all captured sends.
clear_sent :: proc(h: ^Test_Harness($T)) {
	unit.clear_sent(h)
}

// Search all captured sends by type (unordered). Removes match if found.
find_sent :: proc(h: ^Test_Harness($T), $M: typeid) -> (M, int, bool) {
	return unit.find_sent(h, M)
}

// Publish Assertions

// Assert next publish matches type, consume and return.
expect_published :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> M {
	return unit.expect_published(h, t, M, loc)
}

// Assert next publish matches type and topic, consume and return.
expect_published_to :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	topic: rawptr,
	$M: typeid,
	loc := #caller_location,
) -> M {
	return unit.expect_published_to(h, t, topic, M, loc)
}

// Assert no publishes captured.
expect_no_publishes :: proc(h: ^Test_Harness($T), t: ^testing.T, loc := #caller_location) {
	unit.expect_no_publishes(h, t, loc)
}

// Timer Assertions

// Assert an active timer was captured, consume and return.
expect_timer :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> Captured_Timer {
	return unit.expect_timer(h, t, loc)
}

// Deliver a Timer_Tick to the actor under test.
fire_timer :: proc(h: ^Test_Harness($T), id: u32) {
	unit.fire_timer(h, id)
}

// Spawn Assertions

// Assert a spawn of the given state type was captured.
expect_spawned :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> Captured_Spawn {
	return unit.expect_spawned(h, t, M, loc)
}

// Terminate Assertions

// Assert a termination was captured, consume and return.
expect_terminated :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> Captured_Terminate {
	return unit.expect_terminated(h, t, loc)
}

// Assert a termination of a specific PID was captured.
expect_terminated_pid :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	pid: actod.PID,
	loc := #caller_location,
) -> Captured_Terminate {
	return unit.expect_terminated_pid(h, t, pid, loc)
}

// Broadcast Assertions

// Assert a broadcast of the given type was captured, consume and return.
expect_broadcast :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> M {
	return unit.expect_broadcast(h, t, M, loc)
}

// Rename Assertions

// Assert a rename was captured, consume and return.
expect_renamed :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> Captured_Rename {
	return unit.expect_renamed(h, t, loc)
}

// Intercept Control — for running code with the harness intercept installed.
// Use when calling non-actor procs (e.g. WS callbacks) that invoke actod APIs.

install :: proc(h: ^Test_Harness($T)) {
	unit.install_intercept(h)
}

uninstall :: proc(h: ^Test_Harness($T)) {
	unit.uninstall_intercept()
}

// Subscription Assertions

// Assert a type subscription was captured.
expect_subscribed_type :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> Captured_Subscribe {
	return unit.expect_subscribed_type(h, t, loc)
}

// Assert a topic subscription was captured.
expect_subscribed_topic :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	topic: rawptr,
	loc := #caller_location,
) -> Captured_Topic_Subscribe {
	return unit.expect_subscribed_topic(h, t, topic, loc)
}
