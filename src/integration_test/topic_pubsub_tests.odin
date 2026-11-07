package integration

import "../actod"
import "core:fmt"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

Topic_Price_Update :: struct {
	symbol: u64,
	bid:    f64,
	ask:    f64,
}

Topic_Sub_Data :: struct {
	received: ^i32,
}

Topic_Sub_Behaviour :: actod.Actor_Behaviour(Topic_Sub_Data) {
	init           = topic_sub_init,
	handle_message = topic_sub_handle,
}

topic_sub_init :: proc(data: ^Topic_Sub_Data) {
	_, _ = actod.subscribe_topic(&shared_topic)
}

topic_sub_handle :: proc(data: ^Topic_Sub_Data, from: actod.PID, msg: any) {
	switch _ in msg {
	case Topic_Price_Update:
		sync.atomic_add(data.received, 1)
	}
}

shared_topic: actod.Topic

Topic_Count_Probe :: struct {
	topic:    ^actod.Topic,
	expected: u32,
}

topic_count_is :: proc(state: rawptr) -> bool {
	probe := cast(^Topic_Count_Probe)state
	return sync.atomic_load_explicit(&probe.topic.count, .Acquire) == probe.expected
}

wait_for_topic_count :: proc(topic: ^actod.Topic, expected: u32) {
	probe := Topic_Count_Probe {
		topic    = topic,
		expected = expected,
	}
	_ = poll_until(topic_count_is, &probe, 2 * time.Second)
}

test_topic_publish :: proc(t: ^testing.T) {
	shared_topic = {}

	received_count: i32 = 0
	SUBSCRIBER_COUNT :: 5

	sub_pids: [SUBSCRIBER_COUNT]actod.PID
	for i in 0 ..< SUBSCRIBER_COUNT {
		pid, ok := actod.spawn(
			fmt.tprintf("topic_sub_%d", i),
			Topic_Sub_Data{received = &received_count},
			Topic_Sub_Behaviour,
		)
		expect(t, ok, "Should spawn subscriber")
		sub_pids[i] = pid
	}

	wait_for_topic_count(&shared_topic, SUBSCRIBER_COUNT)

	expectf(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == SUBSCRIBER_COUNT,
		"Should have %d topic subscribers, got %d",
		SUBSCRIBER_COUNT,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire),
	)

	Pub_Data :: struct {
		topic: ^actod.Topic,
	}

	Pub_Behaviour :: actod.Actor_Behaviour(Pub_Data) {
		handle_message = proc(data: ^Pub_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case string:
				actod.publish(data.topic, Topic_Price_Update{symbol = 1, bid = 100.5, ask = 101.0})
			}
		},
	}

	pub_pid, pub_ok := actod.spawn(
		"topic_publisher",
		Pub_Data{topic = &shared_topic},
		Pub_Behaviour,
	)
	expect(t, pub_ok, "Should spawn publisher")

	_ = actod.send_message(pub_pid, "go")

	for wait_start := time.tick_now(); time.tick_since(wait_start) < INTEGRATION_TEST_TIMEOUT; {
		if sync.atomic_load(&received_count) >= SUBSCRIBER_COUNT {
			break
		}
		time.sleep(time.Millisecond)
	}

	final := sync.atomic_load(&received_count)
	expectf(
		t,
		final == SUBSCRIBER_COUNT,
		"All %d subscribers should receive publish, got %d",
		SUBSCRIBER_COUNT,
		final,
	)

	for pid in sub_pids {
		_ = actod.terminate_actor(pid)
	}
	_ = actod.terminate_actor(pub_pid)
	actod.wait_for_pids(sub_pids[:])
	actod.wait_for_pids([]actod.PID{pub_pid})
}

lists_exactly :: proc(listed: []actod.PID, want: []actod.PID) -> bool {
	if len(listed) != len(want) do return false
	for pid in want {
		if !slice.contains(listed, pid) do return false
	}
	return true
}

test_topic_subscribers_listed_before_and_after_termination :: proc(t: ^testing.T) {
	shared_topic = {}

	received_count: i32 = 0
	SUBSCRIBER_COUNT :: 3

	sub_pids: [SUBSCRIBER_COUNT]actod.PID
	for i in 0 ..< SUBSCRIBER_COUNT {
		pid, ok := actod.spawn(
			fmt.tprintf("topic_listed_%d", i),
			Topic_Sub_Data{received = &received_count},
			Topic_Sub_Behaviour,
		)
		expect(t, ok, "Should spawn subscriber")
		sub_pids[i] = pid
	}

	wait_for_topic_count(&shared_topic, SUBSCRIBER_COUNT)

	listed: [actod.MAX_TOPIC_SUBSCRIBERS]actod.PID
	n := actod.get_topic_subscribers(&shared_topic, listed[:])
	expectf(
		t,
		lists_exactly(listed[:n], sub_pids[:]),
		"Should list every subscriber %v, got %v",
		sub_pids,
		listed[:n],
	)

	terminated := sub_pids[1]
	_ = actod.terminate_actor(terminated)
	actod.wait_for_pids([]actod.PID{terminated})

	survivors := []actod.PID{sub_pids[0], sub_pids[2]}
	n = actod.get_topic_subscribers(&shared_topic, listed[:])
	expectf(
		t,
		lists_exactly(listed[:n], survivors),
		"Should list only the survivors %v after %v terminated, got %v",
		survivors,
		terminated,
		listed[:n],
	)

	_ = actod.terminate_actor(sub_pids[0])
	_ = actod.terminate_actor(sub_pids[2])
	actod.wait_for_pids(survivors)
}

test_topic_auto_cleanup :: proc(t: ^testing.T) {
	shared_topic = {}

	received_count: i32 = 0
	sub_data := Topic_Sub_Data {
		received = &received_count,
	}
	sub_pid, sub_ok := actod.spawn("topic_cleanup_sub", sub_data, Topic_Sub_Behaviour)
	expect(t, sub_ok, "Should spawn subscriber")

	wait_for_topic_count(&shared_topic, 1)

	expect(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == 1,
		"Should have 1 topic subscriber",
	)

	_ = actod.terminate_actor(sub_pid)
	actod.wait_for_pids([]actod.PID{sub_pid})

	expectf(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == 0,
		"Subscriber count should be 0 after termination, got %d",
		sync.atomic_load_explicit(&shared_topic.count, .Acquire),
	)

	Pub_Data :: struct {
		topic: ^actod.Topic,
	}

	Pub_Behaviour :: actod.Actor_Behaviour(Pub_Data) {
		handle_message = proc(data: ^Pub_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case string:
				actod.publish(data.topic, Topic_Price_Update{symbol = 2, bid = 50.0, ask = 51.0})
			}
		},
	}

	pub_pid, pub_ok := actod.spawn(
		"topic_cleanup_pub",
		Pub_Data{topic = &shared_topic},
		Pub_Behaviour,
	)
	expect(t, pub_ok, "Should spawn publisher")

	_ = actod.send_message(pub_pid, "go")
	time.sleep(50 * time.Millisecond)

	expect(
		t,
		sync.atomic_load(&received_count) == 0,
		"No messages should be received after subscriber terminated",
	)

	_ = actod.terminate_actor(pub_pid)
	actod.wait_for_pids([]actod.PID{pub_pid})
}

test_topic_unsubscribe :: proc(t: ^testing.T) {
	shared_topic = {}

	received_count: i32 = 0

	Unsub_Data :: struct {
		received: ^i32,
		sub:      actod.Topic_Subscription,
	}

	Unsub_Behaviour :: actod.Actor_Behaviour(Unsub_Data) {
		init = proc(data: ^Unsub_Data) {
			sub, ok := actod.subscribe_topic(&shared_topic)
			if ok {
				data.sub = sub
			}
		},
		handle_message = proc(data: ^Unsub_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Topic_Price_Update:
				sync.atomic_add(data.received, 1)
			case string:
				if m == "unsub" {
					_ = actod.unsubscribe_topic(data.sub)
				}
			}
		},
	}

	sub_pid, sub_ok := actod.spawn(
		"topic_unsub_actor",
		Unsub_Data{received = &received_count},
		Unsub_Behaviour,
	)
	expect(t, sub_ok, "Should spawn subscriber")

	wait_for_topic_count(&shared_topic, 1)
	expect(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == 1,
		"Should have 1 subscriber",
	)

	Pub_Data :: struct {
		topic: ^actod.Topic,
	}

	Pub_Behaviour :: actod.Actor_Behaviour(Pub_Data) {
		handle_message = proc(data: ^Pub_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case string:
				actod.publish(data.topic, Topic_Price_Update{symbol = 3, bid = 200.0, ask = 201.0})
			}
		},
	}

	pub_pid, pub_ok := actod.spawn(
		"topic_unsub_pub",
		Pub_Data{topic = &shared_topic},
		Pub_Behaviour,
	)
	expect(t, pub_ok, "Should spawn publisher")

	_ = actod.send_message(pub_pid, "go")
	for wait_start := time.tick_now(); time.tick_since(wait_start) < INTEGRATION_TEST_TIMEOUT; {
		if sync.atomic_load(&received_count) >= 1 {
			break
		}
		time.sleep(time.Millisecond)
	}
	expect(t, sync.atomic_load(&received_count) == 1, "Should receive first publish")

	_ = actod.send_message(sub_pid, "unsub")
	wait_for_topic_count(&shared_topic, 0)

	expectf(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == 0,
		"Count should be 0 after unsubscribe, got %d",
		sync.atomic_load_explicit(&shared_topic.count, .Acquire),
	)

	_ = actod.send_message(pub_pid, "go")
	time.sleep(50 * time.Millisecond)

	expectf(
		t,
		sync.atomic_load(&received_count) == 1,
		"Should still be 1 after unsubscribe, got %d",
		sync.atomic_load(&received_count),
	)

	_ = actod.terminate_actor(sub_pid)
	_ = actod.terminate_actor(pub_pid)
	actod.wait_for_pids([]actod.PID{sub_pid, pub_pid})
}

TOPIC_CHURN_WORKERS :: 4
TOPIC_CHURNERS :: 3
TOPIC_CHURN_PUBLISHER_WORKER :: TOPIC_CHURNERS
TOPIC_CHURN_ROUNDS :: 50
TOPIC_CHURN_CYCLES_PER_ROUND :: 2000
TOPIC_CHURN_PUBLISHES_PER_ROUND :: 64
TOPIC_CHURN_BUDGET :: 20 * time.Second

churn_topic: actod.Topic
topic_churners_done: int
topic_churn_failed_subscribes: int
topic_churn_failed_unsubscribes: int
topic_churn_stalled_rounds: int
topic_churn_publishing: bool

Topic_Churn_Round :: struct {
	round: int,
}

Topic_Churner :: struct {
	rounds_left: int,
}

topic_churner_behaviour := actod.Actor_Behaviour(Topic_Churner) {
	handle_message = topic_churner_handle,
}

topic_churner_handle :: proc(data: ^Topic_Churner, from: actod.PID, msg: any) {
	round, is_round := msg.(Topic_Churn_Round)
	if !is_round do return

	for _ in 0 ..< TOPIC_CHURN_CYCLES_PER_ROUND {
		sub, subscribed := actod.subscribe_topic(&churn_topic)
		if !subscribed {
			sync.atomic_add(&topic_churn_failed_subscribes, 1)
			continue
		}
		if !actod.unsubscribe_topic(sub) do sync.atomic_add(&topic_churn_failed_unsubscribes, 1)
	}

	data.rounds_left -= 1
	if data.rounds_left > 0 {
		if actod.send_self(Topic_Churn_Round{round = round.round + 1}) != .OK {
			sync.atomic_add(&topic_churn_stalled_rounds, 1)
		}
		return
	}

	if _, subscribed := actod.subscribe_topic(&churn_topic); !subscribed {
		sync.atomic_add(&topic_churn_failed_subscribes, 1)
	}
	sync.atomic_add(&topic_churners_done, 1)
}

Topic_Churn_Publisher :: struct {
	published: int,
}

topic_churn_publisher_behaviour := actod.Actor_Behaviour(Topic_Churn_Publisher) {
	handle_message = topic_churn_publisher_handle,
}

topic_churn_publisher_handle :: proc(data: ^Topic_Churn_Publisher, from: actod.PID, msg: any) {
	round, is_round := msg.(Topic_Churn_Round)
	if !is_round do return

	for _ in 0 ..< TOPIC_CHURN_PUBLISHES_PER_ROUND {
		actod.publish(&churn_topic, Topic_Price_Update{symbol = u64(round.round)})
		data.published += 1
	}

	if !sync.atomic_load(&topic_churn_publishing) do return
	if actod.send_self(Topic_Churn_Round{round = round.round + 1}) != .OK {
		sync.atomic_add(&topic_churn_stalled_rounds, 1)
	}
}

topic_churners_all_done :: proc(state: rawptr) -> bool {
	return sync.atomic_load(&topic_churners_done) == TOPIC_CHURNERS
}

test_topic_churn_keeps_subscribers_dense :: proc(t: ^testing.T) {
	churn_topic = {}
	sync.atomic_store(&topic_churners_done, 0)
	sync.atomic_store(&topic_churn_failed_subscribes, 0)
	sync.atomic_store(&topic_churn_failed_unsubscribes, 0)
	sync.atomic_store(&topic_churn_stalled_rounds, 0)
	sync.atomic_store(&topic_churn_publishing, true)

	publisher, publisher_spawned := actod.spawn(
		"topic_churn_publisher",
		Topic_Churn_Publisher{},
		topic_churn_publisher_behaviour,
		actod.make_actor_config(home_worker = TOPIC_CHURN_PUBLISHER_WORKER),
	)
	if !expect(t, publisher_spawned, "failed to spawn the topic churn publisher") do return

	churners: [TOPIC_CHURNERS]actod.PID
	for w in 0 ..< TOPIC_CHURNERS {
		pid, spawned := actod.spawn(
			fmt.tprintf("topic_churner_%d", w),
			Topic_Churner{rounds_left = TOPIC_CHURN_ROUNDS},
			topic_churner_behaviour,
			actod.make_actor_config(home_worker = w),
		)
		if !expectf(t, spawned, "failed to spawn topic churner on worker %d", w) do return
		churners[w] = pid
	}

	expect(
		t,
		actod.send_message(publisher, Topic_Churn_Round{}) == .OK,
		"failed to start the publisher",
	)
	for pid in churners {
		expect(t, actod.send_message(pid, Topic_Churn_Round{}) == .OK, "failed to start a churner")
	}

	finished := poll_until(topic_churners_all_done, nil, TOPIC_CHURN_BUDGET)
	sync.atomic_store(&topic_churn_publishing, false)
	if !expectf(
		t,
		finished,
		"only %d of %d churners finished within %v, a subscribe is spinning on a slot outside the counted range",
		sync.atomic_load(&topic_churners_done),
		TOPIC_CHURNERS,
		TOPIC_CHURN_BUDGET,
	) {
		return
	}

	expect_value(t, sync.atomic_load(&topic_churn_failed_subscribes), 0)
	expect_value(t, sync.atomic_load(&topic_churn_failed_unsubscribes), 0)
	expect_value(t, sync.atomic_load(&topic_churn_stalled_rounds), 0)

	count := sync.atomic_load_explicit(&churn_topic.count, .Acquire)
	expectf(
		t,
		count == TOPIC_CHURNERS,
		"topic counts %d subscribers, want %d",
		count,
		TOPIC_CHURNERS,
	)

	for i in 0 ..< actod.MAX_TOPIC_SUBSCRIBERS {
		pid := actod.PID(
			sync.atomic_load_explicit(cast(^u64)&churn_topic.subscribers[i], .Acquire),
		)
		if u32(i) < count {
			expectf(t, pid != 0, "slot %d inside the counted range %d is zero", i, count)
		} else {
			expectf(
				t,
				pid == 0,
				"slot %d outside the counted range %d holds live pid %v",
				i,
				count,
				pid,
			)
		}
	}

	listed: [actod.MAX_TOPIC_SUBSCRIBERS]actod.PID
	n := actod.get_topic_subscribers(&churn_topic, listed[:])
	expectf(
		t,
		lists_exactly(listed[:n], churners[:]),
		"want every churner %v counted, got %v",
		churners,
		listed[:n],
	)

	for pid in churners {
		_ = actod.terminate_actor(pid)
	}
	_ = actod.terminate_actor(publisher)
	actod.wait_for_pids(churners[:])
	actod.wait_for_pids([]actod.PID{publisher})
}
