package integration

import "../actod"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
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
	actod.subscribe_topic(&shared_topic)
}

topic_sub_handle :: proc(data: ^Topic_Sub_Data, from: actod.PID, msg: any) {
	switch _ in msg {
	case Topic_Price_Update:
		sync.atomic_add(data.received, 1)
	}
}

shared_topic: actod.Topic

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
		testing.expect(t, ok, "Should spawn subscriber")
		sub_pids[i] = pid
	}

	time.sleep(50 * time.Millisecond)

	testing.expectf(
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
	testing.expect(t, pub_ok, "Should spawn publisher")

	time.sleep(20 * time.Millisecond)

	actod.send_message(pub_pid, "go")

	for _ in 0 ..< 5000 {
		if sync.atomic_load(&received_count) >= SUBSCRIBER_COUNT {
			break
		}
		thread.yield()
	}

	final := sync.atomic_load(&received_count)
	testing.expectf(
		t,
		final == SUBSCRIBER_COUNT,
		"All %d subscribers should receive publish, got %d",
		SUBSCRIBER_COUNT,
		final,
	)

	for pid in sub_pids {
		actod.terminate_actor(pid)
	}
	actod.terminate_actor(pub_pid)
	actod.wait_for_pids(sub_pids[:])
	actod.wait_for_pids([]actod.PID{pub_pid})
}

test_topic_auto_cleanup :: proc(t: ^testing.T) {
	shared_topic = {}

	received_count: i32 = 0
	sub_data := Topic_Sub_Data {
		received = &received_count,
	}
	sub_pid, sub_ok := actod.spawn("topic_cleanup_sub", sub_data, Topic_Sub_Behaviour)
	testing.expect(t, sub_ok, "Should spawn subscriber")

	time.sleep(50 * time.Millisecond)

	testing.expect(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == 1,
		"Should have 1 topic subscriber",
	)

	actod.terminate_actor(sub_pid)
	actod.wait_for_pids([]actod.PID{sub_pid})

	testing.expectf(
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
	testing.expect(t, pub_ok, "Should spawn publisher")

	time.sleep(20 * time.Millisecond)

	actod.send_message(pub_pid, "go")
	time.sleep(50 * time.Millisecond)

	testing.expect(
		t,
		sync.atomic_load(&received_count) == 0,
		"No messages should be received after subscriber terminated",
	)

	actod.terminate_actor(pub_pid)
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
					actod.unsubscribe_topic(data.sub)
				}
			}
		},
	}

	sub_pid, sub_ok := actod.spawn(
		"topic_unsub_actor",
		Unsub_Data{received = &received_count},
		Unsub_Behaviour,
	)
	testing.expect(t, sub_ok, "Should spawn subscriber")

	time.sleep(50 * time.Millisecond)
	testing.expect(
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
	testing.expect(t, pub_ok, "Should spawn publisher")
	time.sleep(20 * time.Millisecond)

	actod.send_message(pub_pid, "go")
	for _ in 0 ..< 5000 {
		if sync.atomic_load(&received_count) >= 1 {
			break
		}
		thread.yield()
	}
	testing.expect(t, sync.atomic_load(&received_count) == 1, "Should receive first publish")

	actod.send_message(sub_pid, "unsub")
	time.sleep(50 * time.Millisecond)

	testing.expectf(
		t,
		sync.atomic_load_explicit(&shared_topic.count, .Acquire) == 0,
		"Count should be 0 after unsubscribe, got %d",
		sync.atomic_load_explicit(&shared_topic.count, .Acquire),
	)

	actod.send_message(pub_pid, "go")
	time.sleep(50 * time.Millisecond)

	testing.expectf(
		t,
		sync.atomic_load(&received_count) == 1,
		"Should still be 1 after unsubscribe, got %d",
		sync.atomic_load(&received_count),
	)

	actod.terminate_actor(sub_pid)
	actod.terminate_actor(pub_pid)
	actod.wait_for_pids([]actod.PID{sub_pid, pub_pid})
}
