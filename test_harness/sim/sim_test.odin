package sim

import "../../src/actod"
import "base:runtime"
import "core:testing"
import "core:time"

Ping :: struct {
	value: int,
}
Pong :: struct {
	value: int,
}

echo_state :: struct {
	name:       string,
	pings:      int,
	last_value: int,
}

echo_behaviour := actod.Actor_Behaviour(echo_state) {
	handle_message = handle_echo,
	init           = init_echo,
}

init_echo :: proc(s: ^echo_state) {}

handle_echo :: proc(s: ^echo_state, from: actod.PID, msg: any) {
	switch v in msg {
	case Ping:
		s.pings += 1
		s.last_value = v.value
		actod.send_message(from, Pong{value = v.value * 2})
	case Pong:
		s.last_value = v.value
	}
}

Increment :: struct {}

counter_state :: struct {
	name:  string,
	count: int,
	topic: ^actod.Topic,
}

counter_behaviour := actod.Actor_Behaviour(counter_state) {
	handle_message = handle_counter,
	init           = init_counter,
}

init_counter :: proc(s: ^counter_state) {
	if s.topic != nil {
		actod.subscribe_topic(s.topic)
	}
}

handle_counter :: proc(s: ^counter_state, from: actod.PID, msg: any) {
	switch v in msg {
	case Increment:
		s.count += 1
	}
}

timer_state :: struct {
	name:     string,
	ticks:    int,
	timer_id: u32,
}

timer_behaviour := actod.Actor_Behaviour(timer_state) {
	handle_message = handle_timer_msg,
	init           = init_timer_actor,
}

init_timer_actor :: proc(s: ^timer_state) {
	id, _ := actod.set_timer(1 * time.Second, repeat = true)
	s.timer_id = id
}

handle_timer_msg :: proc(s: ^timer_state, from: actod.PID, msg: any) {
	switch v in msg {
	case actod.Timer_Tick:
		if v.id == s.timer_id {
			s.ticks += 1
		}
	}
}

Forward :: struct {
	target: string,
	value:  int,
}

forwarder_state :: struct {
	name:      string,
	forwarded: int,
}

forwarder_behaviour := actod.Actor_Behaviour(forwarder_state) {
	handle_message = handle_forwarder,
	init           = init_forwarder,
}

init_forwarder :: proc(s: ^forwarder_state) {}

handle_forwarder :: proc(s: ^forwarder_state, from: actod.PID, msg: any) {
	switch v in msg {
	case Forward:
		actod.send_message_name(v.target, Ping{value = v.value})
		s.forwarded += 1
	}
}

Spawn_Child_Cmd :: struct {}

spawner_state :: struct {
	name:    string,
	spawned: int,
}

spawner_behaviour := actod.Actor_Behaviour(spawner_state) {
	handle_message = handle_spawner,
}

handle_spawner :: proc(s: ^spawner_state, from: actod.PID, msg: any) {
	switch v in msg {
	case Spawn_Child_Cmd:
		actod.spawn_child("child", echo_state{name = "spawned-child"}, echo_behaviour)
		s.spawned += 1
	}
}

@(init)
init_test_types :: proc "contextless" () {
	context = runtime.default_context()
	actod.register_message_type(Ping)
	actod.register_message_type(Pong)
	actod.register_message_type(Increment)
	actod.register_message_type(Forward)
	actod.register_message_type(Spawn_Child_Cmd)
}

@(test)
test_two_actors_exchange_messages :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	pid_a := spawn(&s, "alice", echo_state{name = "alice"}, echo_behaviour)
	pid_b := spawn(&s, "bob", echo_state{name = "bob"}, echo_behaviour)

	init_all(&s)

	send_from(&s, pid_a, pid_b, Ping{value = 5})

	testing.expect(t, step(&s), "expected step to deliver message")

	testing.expect(t, step(&s), "expected step to deliver Pong")

	alice := get_state(&s, "alice", echo_state)
	bob := get_state(&s, "bob", echo_state)

	testing.expect_value(t, alice.pings, 1)
	testing.expect_value(t, alice.last_value, 5)
	testing.expect_value(t, bob.last_value, 10) // Pong value = 5 * 2
}

@(test)
test_send_by_name :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "fwd", forwarder_state{name = "fwd"}, forwarder_behaviour)
	spawn(&s, "echo", echo_state{name = "echo"}, echo_behaviour)

	init_all(&s)

	send(&s, "fwd", Forward{target = "echo", value = 42})
	run_until_idle(&s)

	fwd := get_state(&s, "fwd", forwarder_state)
	echo := get_state(&s, "echo", echo_state)

	testing.expect_value(t, fwd.forwarded, 1)
	testing.expect_value(t, echo.pings, 1)
	testing.expect_value(t, echo.last_value, 42)
}

@(test)
test_topic_publish_fans_out :: proc(t: ^testing.T) {
	topic: actod.Topic

	s := create()
	defer destroy(&s)

	spawn(&s, "c1", counter_state{name = "c1", topic = &topic}, counter_behaviour)
	spawn(&s, "c2", counter_state{name = "c2", topic = &topic}, counter_behaviour)
	spawn(&s, "c3", counter_state{name = "c3", topic = &topic}, counter_behaviour)

	init_all(&s)

	publish(&s, &topic, Increment{})
	run_until_idle(&s)

	c1 := get_state(&s, "c1", counter_state)
	c2 := get_state(&s, "c2", counter_state)
	c3 := get_state(&s, "c3", counter_state)

	testing.expect_value(t, c1.count, 1)
	testing.expect_value(t, c2.count, 1)
	testing.expect_value(t, c3.count, 1)
}

@(test)
test_timer_fires_on_advance :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "tmr", timer_state{name = "tmr"}, timer_behaviour)
	init_all(&s)

	tm := get_state(&s, "tmr", timer_state)
	testing.expect_value(t, tm.ticks, 0)

	advance_time(&s, 1 * time.Second)
	run_until_idle(&s)

	tm = get_state(&s, "tmr", timer_state)
	testing.expect_value(t, tm.ticks, 1)
}

@(test)
test_repeat_timer_fires_multiple :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "tmr", timer_state{name = "tmr"}, timer_behaviour)
	init_all(&s)

	advance_time(&s, 3 * time.Second)
	run_until_idle(&s)

	tm := get_state(&s, "tmr", timer_state)
	testing.expect_value(t, tm.ticks, 3)
}

@(test)
test_run_until_idle_processes_chain :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	pid_a := spawn(&s, "alice", echo_state{name = "alice"}, echo_behaviour)
	pid_b := spawn(&s, "bob", echo_state{name = "bob"}, echo_behaviour)

	init_all(&s)

	send_from(&s, pid_a, pid_b, Ping{value = 7})

	run_until_idle(&s)

	alice := get_state(&s, "alice", echo_state)
	bob := get_state(&s, "bob", echo_state)

	testing.expect_value(t, alice.pings, 1)
	testing.expect_value(t, bob.last_value, 14)
}

@(test)
test_step_returns_false_when_empty :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	testing.expect(t, !step(&s), "expected false when queue empty")
}

@(test)
test_spawn_captured :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "spawner", spawner_state{name = "spawner"}, spawner_behaviour)
	init_all(&s)

	send(&s, "spawner", Spawn_Child_Cmd{})
	run_until_idle(&s)

	sp := get_state(&s, "spawner", spawner_state)
	testing.expect_value(t, sp.spawned, 1)

	captured, ok := find_spawn(&s, echo_state)
	testing.expect(t, ok, "expected spawn to be captured")
	testing.expect_value(t, captured.name, "child")
}

@(test)
test_external_send_by_name :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "echo", echo_state{name = "echo"}, echo_behaviour)
	init_all(&s)

	send(&s, "echo", Ping{value = 99})
	run_until_idle(&s)

	echo := get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 1)
	testing.expect_value(t, echo.last_value, 99)
}

@(test)
test_pending_messages :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	testing.expect_value(t, pending_messages(&s), 0)

	send(&s, "counter", Increment{})
	testing.expect_value(t, pending_messages(&s), 1)

	send(&s, "counter", Increment{})
	testing.expect_value(t, pending_messages(&s), 2)

	step(&s)
	testing.expect_value(t, pending_messages(&s), 1)
}

@(test)
test_dead_actor_messages_dropped :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	pid := spawn(&s, "echo", echo_state{name = "echo"}, echo_behaviour)
	init_all(&s)

	actor := find_actor_by_pid(&s, u64(pid))
	actor.alive = false

	send(&s, "echo", Ping{value = 1})
	testing.expect(t, step(&s), "step should return true even for dead actor")

	echo := get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 0)
}

@(test)
test_multiple_topics :: proc(t: ^testing.T) {
	topic_a: actod.Topic
	topic_b: actod.Topic

	s := create()
	defer destroy(&s)

	spawn(&s, "c1", counter_state{name = "c1", topic = &topic_a}, counter_behaviour)
	spawn(&s, "c2", counter_state{name = "c2", topic = &topic_b}, counter_behaviour)

	init_all(&s)

	publish(&s, &topic_a, Increment{})
	run_until_idle(&s)

	c1 := get_state(&s, "c1", counter_state)
	c2 := get_state(&s, "c2", counter_state)

	testing.expect_value(t, c1.count, 1)
	testing.expect_value(t, c2.count, 0)
}

@(test)
test_fault_drop_prevents_delivery :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "echo", echo_state{name = "echo"}, echo_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "echo", msg_type = typeid_of(Ping)},
			action = .Drop,
			remaining = -1,
		},
	)

	send(&s, "echo", Ping{value = 42})
	run_until_idle(&s)

	echo := get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 0)
}

@(test)
test_fault_drop_remaining_limit :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Drop,
			remaining = 2, // drop first 2, allow rest
		},
	)

	for _ in 0 ..< 5 {
		send(&s, "counter", Increment{})
	}
	run_until_idle(&s)

	c := get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 3) // 5 sent - 2 dropped = 3 delivered
}

@(test)
test_fault_delay_holds_message :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "echo", echo_state{name = "echo"}, echo_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "echo", msg_type = typeid_of(Ping)},
			action = .Delay,
			delay_steps = 3,
			remaining = 1,
		},
	)

	send(&s, "echo", Ping{value = 10})

	step(&s)
	echo := get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 0)
	testing.expect_value(t, delayed_count(&s), 1)

	send(&s, "echo", Ping{value = 20})

	step(&s)
	echo = get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 1)
	testing.expect_value(t, echo.last_value, 20)

	step(&s)

	step(&s)
	echo = get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 2)
	testing.expect_value(t, echo.last_value, 10)
}

@(test)
test_fault_duplicate_delivers_twice :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Duplicate,
			remaining = 1,
		},
	)

	send(&s, "counter", Increment{})
	run_until_idle(&s)

	c := get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 2) // original + duplicate
}

@(test)
test_fault_first_match_wins :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Drop,
			remaining = -1,
		},
	)
	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Duplicate,
			remaining = -1,
		},
	)

	send(&s, "counter", Increment{})
	run_until_idle(&s)

	c := get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 0) // dropped, not duplicated

	testing.expect_value(t, s.faults[0].fired, 1)
	testing.expect_value(t, s.faults[1].fired, 0)
}

@(test)
test_fault_wildcard_match :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "echo", echo_state{name = "echo"}, echo_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule{match = Fault_Match{to_name = "echo"}, action = .Drop, remaining = -1},
	)

	send(&s, "echo", Ping{value = 1})
	run_until_idle(&s)

	echo := get_state(&s, "echo", echo_state)
	testing.expect_value(t, echo.pings, 0)
}

@(test)
test_fault_clear_removes_all :: proc(t: ^testing.T) {
	s := create()
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule{match = Fault_Match{to_name = "counter"}, action = .Drop, remaining = -1},
	)

	send(&s, "counter", Increment{})
	run_until_idle(&s)

	c := get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 0)

	clear_faults(&s)

	send(&s, "counter", Increment{})
	run_until_idle(&s)

	c = get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 1)
}

@(test)
test_probabilistic_fault_zero_always_fires :: proc(t: ^testing.T) {
	s := create_seeded(42)
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Drop,
			remaining = -1,
			probability = 0,
		},
	)

	for _ in 0 ..< 10 {
		send(&s, "counter", Increment{})
	}
	run_until_idle(&s)

	c := get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 0) // all dropped
	testing.expect_value(t, s.faults[0].fired, 10)
}

@(test)
test_probabilistic_fault_drops_some :: proc(t: ^testing.T) {
	s := create_seeded(12345)
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Drop,
			remaining = -1,
			probability = 0.5,
		},
	)

	N :: 100
	for _ in 0 ..< N {
		send(&s, "counter", Increment{})
	}
	run_until_idle(&s)

	c := get_state(&s, "counter", counter_state)
	dropped := s.faults[0].fired
	delivered := c.count

	testing.expect_value(t, dropped + delivered, N)
	testing.expectf(t, dropped > 20 && dropped < 80, "expected ~50 drops, got %d", dropped)
}

@(test)
test_same_seed_reproduces :: proc(t: ^testing.T) {
	run_trial :: proc(seed: u64) -> int {
		s := create_seeded(seed)
		defer destroy(&s)

		spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
		init_all(&s)

		add_fault(
			&s,
			Fault_Rule {
				match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
				action = .Drop,
				remaining = -1,
				probability = 0.5,
			},
		)

		for _ in 0 ..< 50 {
			send(&s, "counter", Increment{})
		}
		run_until_idle(&s)
		return get_state(&s, "counter", counter_state).count
	}

	a := run_trial(99999)
	b := run_trial(99999)
	testing.expect_value(t, a, b)
}

@(test)
test_different_seed_diverges :: proc(t: ^testing.T) {
	run_trial :: proc(seed: u64) -> int {
		s := create_seeded(seed)
		defer destroy(&s)

		spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
		init_all(&s)

		add_fault(
			&s,
			Fault_Rule {
				match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
				action = .Drop,
				remaining = -1,
				probability = 0.5,
			},
		)

		for _ in 0 ..< 50 {
			send(&s, "counter", Increment{})
		}
		run_until_idle(&s)
		return get_state(&s, "counter", counter_state).count
	}

	a := run_trial(1)
	b := run_trial(2)
	testing.expect(t, a != b, "expected different seeds to produce different results")
}

@(test)
test_probability_with_remaining :: proc(t: ^testing.T) {
	s := create_seeded(42)
	defer destroy(&s)

	spawn(&s, "counter", counter_state{name = "counter"}, counter_behaviour)
	init_all(&s)

	add_fault(
		&s,
		Fault_Rule {
			match = Fault_Match{to_name = "counter", msg_type = typeid_of(Increment)},
			action = .Drop,
			remaining = 3,
			probability = 0.5,
		},
	)

	for _ in 0 ..< 100 {
		send(&s, "counter", Increment{})
	}
	run_until_idle(&s)

	testing.expect_value(t, s.faults[0].fired, 3) // exactly 3 fired
	c := get_state(&s, "counter", counter_state)
	testing.expect_value(t, c.count, 97) // 100 - 3 = 97 delivered
}
