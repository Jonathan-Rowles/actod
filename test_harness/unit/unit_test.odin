package unit

import "../../src/actod"
import "../ti"
import "base:runtime"
import "core:testing"
import "core:time"

Test_Ping :: struct {
	value: int,
}
Test_Pong :: struct {
	value: int,
}
Test_Publish_Cmd :: struct {
	value: int,
}
Test_Spawn_Cmd :: struct {}
Test_Terminate_Cmd :: struct {}
Test_Broadcast_Cmd :: struct {
	value: int,
}
Test_Rename_Cmd :: struct {
	new_name: string,
}
Test_Subscribe_Type_Cmd :: struct {}
Test_Subscribe_Topic_Cmd :: struct {}
Test_Send_Parent_Cmd :: struct {
	value: int,
}
Test_Send_Children_Cmd :: struct {
	value: int,
}

@(init)
init_harness_test_types :: proc "contextless" () {
	context = runtime.default_context()
	actod.register_message_type(Test_Ping)
	actod.register_message_type(Test_Pong)
	actod.register_message_type(Test_Publish_Cmd)
	actod.register_message_type(Test_Spawn_Cmd)
	actod.register_message_type(Test_Terminate_Cmd)
	actod.register_message_type(Test_Broadcast_Cmd)
	actod.register_message_type(Test_Rename_Cmd)
	actod.register_message_type(Test_Subscribe_Type_Cmd)
	actod.register_message_type(Test_Subscribe_Topic_Cmd)
	actod.register_message_type(Test_Send_Parent_Cmd)
	actod.register_message_type(Test_Send_Children_Cmd)
}

test_topic: actod.Topic

test_state :: struct {
	init_called:      bool,
	terminate_called: bool,
	pings:            int,
	last_value:       int,
}

test_behaviour := actod.Actor_Behaviour(test_state) {
	handle_message = handle_test_msg,
	init           = init_test,
	terminate      = terminate_test,
}

init_test :: proc(s: ^test_state) {
	s.init_called = true
}

terminate_test :: proc(s: ^test_state) {
	s.terminate_called = true
}

handle_test_msg :: proc(s: ^test_state, from: actod.PID, msg: any) {
	switch v in msg {
	case Test_Ping:
		s.pings += 1
		s.last_value = v.value
		actod.send_message(from, Test_Pong{value = v.value * 2})
	case Test_Publish_Cmd:
		actod.publish(&test_topic, Test_Pong{value = v.value})
	case Test_Spawn_Cmd:
		actod.spawn_child("spawned-child", test_state{}, test_behaviour)
	case Test_Terminate_Cmd:
		actod.self_terminate(.NORMAL)
	case Test_Broadcast_Cmd:
		actod.broadcast(Test_Pong{value = v.value})
	case Test_Rename_Cmd:
		actod.self_rename(v.new_name)
	case Test_Subscribe_Type_Cmd:
		actod.subscribe_type(actod.Actor_Type(1))
	case Test_Subscribe_Topic_Cmd:
		actod.subscribe_topic(&test_topic)
	case Test_Send_Parent_Cmd:
		actod.send_message_to_parent(Test_Pong{value = v.value})
	case Test_Send_Children_Cmd:
		actod.send_message_to_children(Test_Pong{value = v.value})
	}
}

supervisor_state :: struct {
	child_started_pid:    actod.PID,
	child_terminated_pid: actod.PID,
	term_reason:          actod.Termination_Reason,
	will_restart:         bool,
	restarted_old:        actod.PID,
	restarted_new:        actod.PID,
	restart_count:        int,
	max_restarts_pid:     actod.PID,
}

supervisor_behaviour := actod.Actor_Behaviour(supervisor_state) {
	handle_message = proc(_: ^supervisor_state, _: actod.PID, _: any) {},
	on_child_started = proc(s: ^supervisor_state, pid: actod.PID) {
		s.child_started_pid = pid
	},
	on_child_terminated = proc(
		s: ^supervisor_state,
		pid: actod.PID,
		reason: actod.Termination_Reason,
		will_restart: bool,
	) {
		s.child_terminated_pid = pid
		s.term_reason = reason
		s.will_restart = will_restart
	},
	on_child_restarted = proc(
		s: ^supervisor_state,
		old_pid: actod.PID,
		new_pid: actod.PID,
		restart_count: int,
	) {
		s.restarted_old = old_pid
		s.restarted_new = new_pid
		s.restart_count = restart_count
	},
	on_max_restarts_exceeded = proc(s: ^supervisor_state, pid: actod.PID) {
		s.max_restarts_pid = pid
	},
}

@(test)
test_create_destroy :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	s := get_state(&h)
	testing.expect(t, s != nil, "state should not be nil")
}

@(test)
test_init_invoked :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	init(&h)
	s := get_state(&h)
	testing.expect(t, s.init_called, "init should have been called")
}

@(test)
test_get_state_returns_live_pointer :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	s := get_state(&h)
	s.last_value = 42
	s2 := get_state(&h)
	testing.expect_value(t, s2.last_value, 42)
}

@(test)
test_expect_sent :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Ping{value = 5})
	pong := expect_sent(&h, t, Test_Pong)
	testing.expect_value(t, pong.value, 10)
}

@(test)
test_expect_sent_to :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Ping{value = 3}, from = actod.PID(50))
	pong := expect_sent_to(&h, t, actod.PID(50), Test_Pong)
	testing.expect_value(t, pong.value, 6)
}

@(test)
test_expect_sent_where :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Ping{value = 7})
	pong := expect_sent_where(&h, t, Test_Pong, proc(p: Test_Pong) -> bool {
		return p.value == 14
	})
	testing.expect_value(t, pong.value, 14)
}

@(test)
test_expect_no_sends :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	expect_no_sends(&h, t)
}

@(test)
test_sent_count :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	testing.expect_value(t, sent_count(&h), 0)
	send(&h, Test_Ping{value = 1})
	testing.expect_value(t, sent_count(&h), 1)
	send(&h, Test_Ping{value = 2})
	testing.expect_value(t, sent_count(&h), 2)
}

@(test)
test_clear_sent :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Ping{value = 1})
	send(&h, Test_Ping{value = 2})
	testing.expect_value(t, sent_count(&h), 2)
	clear_sent(&h)
	testing.expect_value(t, sent_count(&h), 0)
}

@(test)
test_find_sent_unordered :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Ping{value = 1})
	send(&h, Test_Ping{value = 2})
	testing.expect_value(t, sent_count(&h), 2)
	pong, idx, ok := find_sent(&h, Test_Pong)
	testing.expect(t, ok, "should find a Test_Pong")
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, pong.value, 2)
	testing.expect_value(t, sent_count(&h), 1)
}

@(test)
test_expect_published :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Publish_Cmd{value = 99})
	pong := expect_published(&h, t, Test_Pong)
	testing.expect_value(t, pong.value, 99)
}

@(test)
test_expect_published_to :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Publish_Cmd{value = 42})
	pong := expect_published_to(&h, t, &test_topic, Test_Pong)
	testing.expect_value(t, pong.value, 42)
}

@(test)
test_expect_no_publishes :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	expect_no_publishes(&h, t)
}

@(test)
test_expect_spawned :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Spawn_Cmd{})
	cap := expect_spawned(&h, t, test_state)
	testing.expect_value(t, cap.name, "spawned-child")
}

@(test)
test_expect_terminated :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Terminate_Cmd{})
	cap := expect_terminated(&h, t)
	testing.expect_value(t, cap.pid, u64(1))
}

@(test)
test_expect_terminated_pid :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Terminate_Cmd{})
	cap := expect_terminated_pid(&h, t, actod.PID(1))
	testing.expect_value(t, cap.reason, ti.Termination_Reason.NORMAL)
}

@(test)
test_expect_broadcast :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Broadcast_Cmd{value = 77})
	pong := expect_broadcast(&h, t, Test_Pong)
	testing.expect_value(t, pong.value, 77)
}

@(test)
test_expect_renamed :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Rename_Cmd{new_name = "new-actor-name"})
	cap := expect_renamed(&h, t)
	testing.expect_value(t, cap.new_name, "new-actor-name")
}

@(test)
test_expect_subscribed_type :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Subscribe_Type_Cmd{})
	cap := expect_subscribed_type(&h, t)
	testing.expect_value(t, cap.actor_type, u8(1))
}

@(test)
test_expect_subscribed_topic :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	send(&h, Test_Subscribe_Topic_Cmd{})
	cap := expect_subscribed_topic(&h, t, &test_topic)
	testing.expect(t, cap.topic == &test_topic, "topic should match")
}

@(test)
test_register_pid_enables_name_send :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	register_pid(&h, "peer", actod.PID(50))
	pid, ok := h.pid_registry["peer"]
	testing.expect(t, ok, "peer should be registered")
	testing.expect_value(t, pid, u64(50))
}

@(test)
test_set_virtual_now :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	now := time.Time {
		_nsec = 5_000_000_000,
	}
	set_virtual_now(&h, now)
	testing.expect_value(t, h.intercept.virtual_now, now)
}

@(test)
test_advance_time :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	start := time.Time {
		_nsec = 1_000_000_000,
	}
	set_virtual_now(&h, start)
	advance_time(&h, 2 * time.Second)
	expected := time.Time {
		_nsec = 3_000_000_000,
	}
	testing.expect_value(t, h.intercept.virtual_now, expected)
}

timer_state :: struct {
	ticks:    int,
	timer_id: u32,
}

timer_behaviour := actod.Actor_Behaviour(timer_state) {
	handle_message = proc(s: ^timer_state, from: actod.PID, msg: any) {
		switch v in msg {
		case actod.Timer_Tick:
			if v.id == s.timer_id do s.ticks += 1
		}
	},
	init = proc(s: ^timer_state) {
		id, _ := actod.set_timer(1 * time.Second, repeat = true)
		s.timer_id = id
	},
}

@(test)
test_fire_timer_delivers_tick :: proc(t: ^testing.T) {
	h := create(timer_state{}, timer_behaviour)
	defer destroy(&h)
	init(&h)
	timer := expect_timer(&h, t)
	fire_timer(&h, timer.id)
	s := get_state(&h)
	testing.expect_value(t, s.ticks, 1)
}

@(test)
test_simulate_child_terminated :: proc(t: ^testing.T) {
	h := create(supervisor_state{}, supervisor_behaviour)
	defer destroy(&h)
	simulate_child_terminated(&h, actod.PID(10), .ABNORMAL, true)
	s := get_state(&h)
	testing.expect_value(t, s.child_terminated_pid, actod.PID(10))
	testing.expect_value(t, s.term_reason, actod.Termination_Reason.ABNORMAL)
	testing.expect(t, s.will_restart, "will_restart should be true")
}

@(test)
test_simulate_child_started :: proc(t: ^testing.T) {
	h := create(supervisor_state{}, supervisor_behaviour)
	defer destroy(&h)
	simulate_child_started(&h, actod.PID(20))
	s := get_state(&h)
	testing.expect_value(t, s.child_started_pid, actod.PID(20))
}

@(test)
test_simulate_child_restarted :: proc(t: ^testing.T) {
	h := create(supervisor_state{}, supervisor_behaviour)
	defer destroy(&h)
	simulate_child_restarted(&h, actod.PID(30), actod.PID(31), 3)
	s := get_state(&h)
	testing.expect_value(t, s.restarted_old, actod.PID(30))
	testing.expect_value(t, s.restarted_new, actod.PID(31))
	testing.expect_value(t, s.restart_count, 3)
}

@(test)
test_simulate_max_restarts :: proc(t: ^testing.T) {
	h := create(supervisor_state{}, supervisor_behaviour)
	defer destroy(&h)
	simulate_max_restarts(&h, actod.PID(40))
	s := get_state(&h)
	testing.expect_value(t, s.max_restarts_pid, actod.PID(40))
}

@(test)
test_send_to_parent :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	set_parent(&h, actod.PID(200))
	send(&h, Test_Send_Parent_Cmd{value = 11})
	pong := expect_sent_to(&h, t, actod.PID(200), Test_Pong)
	testing.expect_value(t, pong.value, 11)
}

@(test)
test_send_to_children :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	add_child(&h, actod.PID(300))
	add_child(&h, actod.PID(301))
	send(&h, Test_Send_Children_Cmd{value = 22})
	testing.expect_value(t, sent_count(&h), 2)
	pong1 := expect_sent_to(&h, t, actod.PID(300), Test_Pong)
	testing.expect_value(t, pong1.value, 22)
	pong2 := expect_sent_to(&h, t, actod.PID(301), Test_Pong)
	testing.expect_value(t, pong2.value, 22)
}

@(test)
test_terminate_callback :: proc(t: ^testing.T) {
	h := create(test_state{}, test_behaviour)
	defer destroy(&h)
	terminate(&h)
	s := get_state(&h)
	testing.expect(t, s.terminate_called, "terminate should have been called")
}
