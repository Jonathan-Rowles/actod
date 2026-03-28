package unit

import "../../src/actod"
import "../ti"
import "core:testing"
import "core:time"

EXTERNAL_PID :: actod.PID(999)

Test_Harness :: struct($T: typeid) {
	data:                    ^T,
	behaviour:               actod.Actor_Behaviour(T),
	intercept:               ti.Test_Intercept,
	send_capture:            [dynamic]ti.Captured_Send,
	publish_capture:         [dynamic]ti.Captured_Publish,
	timer_capture:           [dynamic]ti.Captured_Timer,
	pid_registry:            map[string]u64,
	spawn_capture:           [dynamic]ti.Captured_Spawn,
	terminate_capture:       [dynamic]ti.Captured_Terminate,
	broadcast_capture:       [dynamic]ti.Captured_Broadcast,
	rename_capture:          [dynamic]ti.Captured_Rename,
	subscribe_capture:       [dynamic]ti.Captured_Subscribe,
	topic_subscribe_capture: [dynamic]ti.Captured_Topic_Subscribe,
	children_pids:           [dynamic]u64,
}

create :: proc(data: $T, behaviour: actod.Actor_Behaviour(T)) -> Test_Harness(T) {
	h: Test_Harness(T)
	h.data = new(T)
	h.data^ = data
	h.behaviour = behaviour
	h.intercept.self_pid = 1
	h.intercept.self_name = "test-actor"
	h.intercept.next_spawn_pid = 100
	return h
}

destroy :: proc(h: ^Test_Harness($T)) {
	for &cap in h.send_capture {
		free(cap.data)
	}
	for &cap in h.publish_capture {
		free(cap.data)
	}
	for &cap in h.broadcast_capture {
		free(cap.data)
	}
	delete(h.send_capture)
	delete(h.publish_capture)
	delete(h.timer_capture)
	delete(h.pid_registry)
	delete(h.spawn_capture)
	delete(h.terminate_capture)
	delete(h.broadcast_capture)
	delete(h.rename_capture)
	delete(h.subscribe_capture)
	delete(h.topic_subscribe_capture)
	delete(h.children_pids)
	free(h.data)
}

install_intercept :: proc(h: ^Test_Harness($T)) {
	h.intercept.send_capture = &h.send_capture
	h.intercept.publish_capture = &h.publish_capture
	h.intercept.timer_capture = &h.timer_capture
	h.intercept.pid_registry = &h.pid_registry
	h.intercept.spawn_capture = &h.spawn_capture
	h.intercept.terminate_capture = &h.terminate_capture
	h.intercept.broadcast_capture = &h.broadcast_capture
	h.intercept.rename_capture = &h.rename_capture
	h.intercept.subscribe_capture = &h.subscribe_capture
	h.intercept.topic_subscribe_capture = &h.topic_subscribe_capture
	h.intercept.children_pids = &h.children_pids
	ti.test_intercept = &h.intercept
}

uninstall_intercept :: proc() {
	ti.test_intercept = nil
}


init :: proc(h: ^Test_Harness($T)) {
	if h.behaviour.init == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.init(h.data)
}

send :: proc(h: ^Test_Harness($T), msg: $M, from: actod.PID = EXTERNAL_PID) {
	if h.behaviour.handle_message == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.handle_message(h.data, actod.PID(from), msg)
}

terminate :: proc(h: ^Test_Harness($T)) {
	if h.behaviour.terminate == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.terminate(h.data)
}

register_pid :: proc(h: ^Test_Harness($T), name: string, pid: actod.PID) {
	h.pid_registry[name] = u64(pid)
}

get_state :: proc(h: ^Test_Harness($T)) -> ^T {
	return h.data
}

add_child :: proc(h: ^Test_Harness($T), pid: actod.PID) {
	append(&h.children_pids, u64(pid))
}

set_parent :: proc(h: ^Test_Harness($T), pid: actod.PID) {
	h.intercept.parent_pid = u64(pid)
}

set_virtual_now :: proc(h: ^Test_Harness($T), t: time.Time) {
	h.intercept.virtual_now = t
}

advance_time :: proc(h: ^Test_Harness($T), d: time.Duration) {
	h.intercept.virtual_now = time.time_add(h.intercept.virtual_now, d)
}


simulate_child_terminated :: proc(
	h: ^Test_Harness($T),
	child_pid: actod.PID,
	reason: actod.Termination_Reason,
	will_restart: bool = false,
) {
	if h.behaviour.on_child_terminated == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.on_child_terminated(h.data, child_pid, reason, will_restart)
}

simulate_child_started :: proc(h: ^Test_Harness($T), child_pid: actod.PID) {
	if h.behaviour.on_child_started == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.on_child_started(h.data, child_pid)
}

simulate_child_restarted :: proc(
	h: ^Test_Harness($T),
	old_pid: actod.PID,
	new_pid: actod.PID,
	restart_count: int,
) {
	if h.behaviour.on_child_restarted == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.on_child_restarted(h.data, old_pid, new_pid, restart_count)
}

simulate_max_restarts :: proc(h: ^Test_Harness($T), child_pid: actod.PID) {
	if h.behaviour.on_max_restarts_exceeded == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.on_max_restarts_exceeded(h.data, child_pid)
}


expect_sent :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> M {
	if len(h.send_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected sent %v, but no sends captured",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	cap := &h.send_capture[0]
	if cap.type_id != M {
		testing.expectf(
			t,
			false,
			"expected sent %v, but next send was %v",
			typeid_of(M),
			cap.type_id,
			loc = loc,
		)
		return {}
	}
	result := (cast(^M)cap.data)^
	free(cap.data)
	ordered_remove(&h.send_capture, 0)
	return result
}

expect_sent_to :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	to: actod.PID,
	$M: typeid,
	loc := #caller_location,
) -> M {
	if len(h.send_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected sent %v to PID %v, but no sends captured",
			typeid_of(M),
			to,
			loc = loc,
		)
		return {}
	}
	cap := &h.send_capture[0]
	if cap.type_id != M || cap.to != u64(to) {
		testing.expectf(
			t,
			false,
			"expected sent %v to PID %v, but next send was %v to PID %v",
			typeid_of(M),
			to,
			cap.type_id,
			actod.PID(cap.to),
			loc = loc,
		)
		return {}
	}
	result := (cast(^M)cap.data)^
	free(cap.data)
	ordered_remove(&h.send_capture, 0)
	return result
}

expect_sent_where :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	pred: proc(_: M) -> bool,
	loc := #caller_location,
) -> M {
	if len(h.send_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected sent %v matching predicate, but no sends captured",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	cap := &h.send_capture[0]
	if cap.type_id != M {
		testing.expectf(
			t,
			false,
			"expected sent %v matching predicate, but next send was %v",
			typeid_of(M),
			cap.type_id,
			loc = loc,
		)
		return {}
	}
	val := (cast(^M)cap.data)^
	if !pred(val) {
		testing.expectf(
			t,
			false,
			"expected sent %v matching predicate, but predicate failed",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	free(cap.data)
	ordered_remove(&h.send_capture, 0)
	return val
}

expect_no_sends :: proc(h: ^Test_Harness($T), t: ^testing.T, loc := #caller_location) {
	if len(h.send_capture) > 0 {
		testing.expectf(
			t,
			false,
			"expected no sends, but %d captured",
			len(h.send_capture),
			loc = loc,
		)
	}
}

sent_count :: proc(h: ^Test_Harness($T)) -> int {
	return len(h.send_capture)
}

clear_sent :: proc(h: ^Test_Harness($T)) {
	for &cap in h.send_capture {
		free(cap.data)
	}
	clear(&h.send_capture)
}

find_sent :: proc(h: ^Test_Harness($T), $M: typeid) -> (M, int, bool) {
	for i in 0 ..< len(h.send_capture) {
		cap := &h.send_capture[i]
		if cap.type_id == M {
			result := (cast(^M)cap.data)^
			free(cap.data)
			ordered_remove(&h.send_capture, i)
			return result, i, true
		}
	}
	return {}, 0, false
}


expect_published :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> M {
	if len(h.publish_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected published %v, but no publishes captured",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	cap := &h.publish_capture[0]
	if cap.type_id != M {
		testing.expectf(
			t,
			false,
			"expected published %v, but next publish was %v",
			typeid_of(M),
			cap.type_id,
			loc = loc,
		)
		return {}
	}
	result := (cast(^M)cap.data)^
	free(cap.data)
	ordered_remove(&h.publish_capture, 0)
	return result
}

expect_published_to :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	topic: rawptr,
	$M: typeid,
	loc := #caller_location,
) -> M {
	if len(h.publish_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected published %v to topic, but no publishes captured",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	cap := &h.publish_capture[0]
	if cap.type_id != M || cap.topic != topic {
		testing.expectf(
			t,
			false,
			"expected published %v to topic, but next publish was %v",
			typeid_of(M),
			cap.type_id,
			loc = loc,
		)
		return {}
	}
	result := (cast(^M)cap.data)^
	free(cap.data)
	ordered_remove(&h.publish_capture, 0)
	return result
}

expect_no_publishes :: proc(h: ^Test_Harness($T), t: ^testing.T, loc := #caller_location) {
	if len(h.publish_capture) > 0 {
		testing.expectf(
			t,
			false,
			"expected no publishes, but %d captured",
			len(h.publish_capture),
			loc = loc,
		)
	}
}

expect_timer :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> ti.Captured_Timer {
	if len(h.timer_capture) == 0 {
		testing.expectf(t, false, "expected active timer, but no timers captured", loc = loc)
		return {}
	}
	timer := &h.timer_capture[0]
	if !timer.active {
		testing.expectf(t, false, "expected active timer, but next timer is inactive", loc = loc)
		return {}
	}
	result := timer^
	ordered_remove(&h.timer_capture, 0)
	return result
}

fire_timer :: proc(h: ^Test_Harness($T), id: u32) {
	if h.behaviour.handle_message == nil do return
	install_intercept(h)
	defer uninstall_intercept()
	h.behaviour.handle_message(h.data, actod.PID(h.intercept.self_pid), actod.Timer_Tick{id = id})
}

expect_spawned :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> ti.Captured_Spawn {
	if len(h.spawn_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected spawn of type %v, but no spawns captured",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	cap := &h.spawn_capture[0]
	if cap.type_id != M {
		testing.expectf(
			t,
			false,
			"expected spawn of type %v, but next spawn was %v",
			typeid_of(M),
			cap.type_id,
			loc = loc,
		)
		return {}
	}
	result := cap^
	ordered_remove(&h.spawn_capture, 0)
	return result
}

expect_terminated :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> ti.Captured_Terminate {
	if len(h.terminate_capture) == 0 {
		testing.expectf(t, false, "expected termination, but none captured", loc = loc)
		return {}
	}
	result := h.terminate_capture[0]
	ordered_remove(&h.terminate_capture, 0)
	return result
}

expect_terminated_pid :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	pid: actod.PID,
	loc := #caller_location,
) -> ti.Captured_Terminate {
	if len(h.terminate_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected termination of PID %v, but none captured",
			pid,
			loc = loc,
		)
		return {}
	}
	cap := &h.terminate_capture[0]
	if cap.pid != u64(pid) {
		testing.expectf(
			t,
			false,
			"expected termination of PID %v, but next termination was PID %v",
			pid,
			actod.PID(cap.pid),
			loc = loc,
		)
		return {}
	}
	result := cap^
	ordered_remove(&h.terminate_capture, 0)
	return result
}

expect_broadcast :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	$M: typeid,
	loc := #caller_location,
) -> M {
	if len(h.broadcast_capture) == 0 {
		testing.expectf(
			t,
			false,
			"expected broadcast of type %v, but no broadcasts captured",
			typeid_of(M),
			loc = loc,
		)
		return {}
	}
	cap := &h.broadcast_capture[0]
	if cap.type_id != M {
		testing.expectf(
			t,
			false,
			"expected broadcast of type %v, but next broadcast was %v",
			typeid_of(M),
			cap.type_id,
			loc = loc,
		)
		return {}
	}
	result := (cast(^M)cap.data)^
	free(cap.data)
	ordered_remove(&h.broadcast_capture, 0)
	return result
}

expect_renamed :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> ti.Captured_Rename {
	if len(h.rename_capture) == 0 {
		testing.expectf(t, false, "expected rename, but none captured", loc = loc)
		return {}
	}
	result := h.rename_capture[0]
	ordered_remove(&h.rename_capture, 0)
	return result
}

expect_subscribed_type :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	loc := #caller_location,
) -> ti.Captured_Subscribe {
	if len(h.subscribe_capture) == 0 {
		testing.expectf(t, false, "expected type subscription, but none captured", loc = loc)
		return {}
	}
	result := h.subscribe_capture[0]
	ordered_remove(&h.subscribe_capture, 0)
	return result
}

expect_subscribed_topic :: proc(
	h: ^Test_Harness($T),
	t: ^testing.T,
	topic: rawptr,
	loc := #caller_location,
) -> ti.Captured_Topic_Subscribe {
	if len(h.topic_subscribe_capture) == 0 {
		testing.expectf(t, false, "expected topic subscription, but none captured", loc = loc)
		return {}
	}
	cap := &h.topic_subscribe_capture[0]
	if cap.topic != topic {
		testing.expectf(
			t,
			false,
			"expected topic subscription to specific topic, but topic didn't match",
			loc = loc,
		)
		return {}
	}
	result := cap^
	ordered_remove(&h.topic_subscribe_capture, 0)
	return result
}
