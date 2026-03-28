package actod

import "core:sync"
import "core:testing"
import "core:thread"

@(private)
clear_type_subscribers :: proc(actor_type: Actor_Type) {
	list := &type_subscribers[actor_type]
	for i in 0 ..< MAX_SUBSCRIBERS_PER_TYPE {
		sync.atomic_store_explicit(cast(^u64)&list.subscribers[i], 0, .Release)
	}
	for node_id in 0 ..< MAX_NODES {
		sync.atomic_store_explicit(&list.remote_node_sub_count[node_id], 0, .Release)
	}
	sync.atomic_store_explicit(&list.local_count, 0, .Release)
	sync.atomic_store_explicit(&list.count, 0, .Release)
}

@(test)
test_add_subscriber :: proc(t: ^testing.T) {
	test_type := Actor_Type(50)
	defer clear_type_subscribers(test_type)

	test_pid := PID(0x0001_32_0001_000001)

	ok := add_subscriber(test_type, test_pid)
	testing.expect(t, ok, "add_subscriber should succeed")

	count := get_subscriber_count(test_type)
	testing.expect(t, count == 1, "subscriber count should be 1")

	stored := PID(
		sync.atomic_load_explicit(cast(^u64)&type_subscribers[test_type].subscribers[0], .Acquire),
	)
	testing.expect(t, stored == test_pid, "stored PID should match")
}

@(test)
test_add_subscriber_untyped_rejected :: proc(t: ^testing.T) {
	ok := add_subscriber(ACTOR_TYPE_UNTYPED, PID(1))
	testing.expect(t, !ok, "should reject ACTOR_TYPE_UNTYPED")
}

@(test)
test_add_subscriber_zero_pid_rejected :: proc(t: ^testing.T) {
	ok := add_subscriber(Actor_Type(51), PID(0))
	testing.expect(t, !ok, "should reject zero PID")
}

@(test)
test_remove_subscriber :: proc(t: ^testing.T) {
	test_type := Actor_Type(52)
	defer clear_type_subscribers(test_type)

	test_pid := PID(0x0001_34_0001_000002)

	ok := add_subscriber(test_type, test_pid)
	testing.expect(t, ok, "add should succeed")
	testing.expect(t, get_subscriber_count(test_type) == 1, "count should be 1")

	removed := remove_subscriber(test_type, test_pid)
	testing.expect(t, removed, "remove should succeed")
	testing.expect(t, get_subscriber_count(test_type) == 0, "count should be 0")

	stored := PID(
		sync.atomic_load_explicit(cast(^u64)&type_subscribers[test_type].subscribers[0], .Acquire),
	)
	testing.expect(t, stored == 0, "slot should be cleared")
}

@(test)
test_remove_subscriber_double_remove :: proc(t: ^testing.T) {
	test_type := Actor_Type(53)
	defer clear_type_subscribers(test_type)

	test_pid := PID(0x0001_35_0001_000003)

	add_subscriber(test_type, test_pid)
	remove_subscriber(test_type, test_pid)

	removed := remove_subscriber(test_type, test_pid)
	testing.expect(t, !removed, "double remove should return false")
}

@(test)
test_subscriber_count :: proc(t: ^testing.T) {
	test_type := Actor_Type(55)
	defer clear_type_subscribers(test_type)

	testing.expect(t, get_subscriber_count(test_type) == 0, "initial count should be 0")
	testing.expect(t, get_subscriber_count(ACTOR_TYPE_UNTYPED) == 0, "untyped count should be 0")

	pids: [5]PID
	for i in u64(1) ..= 5 {
		pids[i - 1] = PID(0x0001_37_0001_000000 | i)
		add_subscriber(test_type, pids[i - 1])
	}
	testing.expect(t, get_subscriber_count(test_type) == 5, "count should be 5")

	remove_subscriber(test_type, pids[0])
	remove_subscriber(test_type, pids[2])
	testing.expect(t, get_subscriber_count(test_type) == 3, "count should be 3 after removals")
}

@(test)
test_subscriber_list_full :: proc(t: ^testing.T) {
	test_type := Actor_Type(56)
	defer clear_type_subscribers(test_type)

	for i in u64(1) ..= MAX_SUBSCRIBERS_PER_TYPE {
		pid := PID(0x0001_38_0001_000000 | i)
		ok := add_subscriber(test_type, pid)
		testing.expect(t, ok, "add should succeed until full")
	}

	testing.expect(
		t,
		get_subscriber_count(test_type) == MAX_SUBSCRIBERS_PER_TYPE,
		"count should be MAX",
	)

	ok := add_subscriber(test_type, PID(0x0001_38_0001_FFFFFF))
	testing.expect(t, !ok, "add should fail when full")
}

@(test)
test_clear_subscriptions_for_node :: proc(t: ^testing.T) {
	test_type := Actor_Type(57)
	defer clear_type_subscribers(test_type)

	remote_node := Node_ID(5)
	other_node := Node_ID(3)

	local_pid := PID(0x0001_39_0001_000001) // node 1

	add_subscriber(test_type, local_pid)

	list := &type_subscribers[test_type]
	sync.atomic_add_explicit(&list.remote_node_sub_count[remote_node], 1, .Release)
	sync.atomic_add_explicit(&list.count, 1, .Release)
	sync.atomic_add_explicit(&list.remote_node_sub_count[remote_node], 1, .Release)
	sync.atomic_add_explicit(&list.count, 1, .Release)
	sync.atomic_add_explicit(&list.remote_node_sub_count[other_node], 1, .Release)
	sync.atomic_add_explicit(&list.count, 1, .Release)

	testing.expect(t, get_subscriber_count(test_type) == 4, "should have 4 subscribers")

	clear_subscriptions_for_node(remote_node)

	testing.expect(t, get_subscriber_count(test_type) == 2, "should have 2 after clearing node 5")
	testing.expect(
		t,
		sync.atomic_load_explicit(&list.remote_node_sub_count[remote_node], .Acquire) == 0,
		"node 5 count should be 0",
	)
	testing.expect(
		t,
		sync.atomic_load_explicit(&list.remote_node_sub_count[other_node], .Acquire) == 1,
		"node 3 count should still be 1",
	)
}

@(test)
test_clear_type_subscribers :: proc(t: ^testing.T) {
	test_type := Actor_Type(200)

	add_subscriber(test_type, PID(0x0001_C8_0001_000001))
	add_subscriber(test_type, PID(0x0001_C8_0001_000002))

	testing.expect(t, get_subscriber_count(test_type) == 2, "should have 2")

	clear_type_subscribers(test_type)

	testing.expect(t, get_subscriber_count(test_type) == 0, "should be 0 after clear")
}

@(test)
test_slot_reuse_after_remove :: proc(t: ^testing.T) {
	test_type := Actor_Type(58)
	defer clear_type_subscribers(test_type)

	pid1 := PID(0x0001_3A_0001_000001)
	pid2 := PID(0x0001_3A_0001_000002)

	add_subscriber(test_type, pid1)
	remove_subscriber(test_type, pid1)

	ok := add_subscriber(test_type, pid2)
	testing.expect(t, ok, "should be able to add after remove")

	stored := PID(
		sync.atomic_load_explicit(cast(^u64)&type_subscribers[test_type].subscribers[0], .Acquire),
	)
	testing.expect(t, stored == pid2, "pid2 should be at slot 0")
}

@(test)
test_subscriber_compact_ordering :: proc(t: ^testing.T) {
	test_type := Actor_Type(61)
	defer clear_type_subscribers(test_type)

	pids: [5]PID
	for i in 0 ..< 5 {
		pids[i] = PID(0x0001_3D_0001_000000 | u64(i + 1))
		add_subscriber(test_type, pids[i])
	}
	testing.expect(t, get_subscriber_count(test_type) == 5, "count should be 5")

	remove_subscriber(test_type, pids[2])

	list := &type_subscribers[test_type]
	local_n := sync.atomic_load_explicit(&list.local_count, .Acquire)
	testing.expect(t, local_n == 4, "local_count should be 4")

	slot2 := PID(sync.atomic_load_explicit(cast(^u64)&list.subscribers[2], .Acquire))
	testing.expect(t, slot2 == pids[4], "last PID should fill the gap")

	for i in 0 ..< u32(4) {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&list.subscribers[i], .Acquire))
		testing.expect(t, pid != 0, "slots 0..3 should be non-zero")
	}
	slot4 := PID(sync.atomic_load_explicit(cast(^u64)&list.subscribers[4], .Acquire))
	testing.expect(t, slot4 == 0, "slot 4 should be cleared")
}

PUBSUB_TEST_THREADS :: 8

Pubsub_Thread_Context :: struct {
	test_type: Actor_Type,
	pid:       PID,
	barrier:   ^sync.Barrier,
	ok:        bool,
}

@(test)
test_concurrent_subscribe :: proc(t: ^testing.T) {
	test_type := Actor_Type(59)
	defer clear_type_subscribers(test_type)

	barrier: sync.Barrier
	sync.barrier_init(&barrier, PUBSUB_TEST_THREADS)

	contexts := make([]Pubsub_Thread_Context, PUBSUB_TEST_THREADS)
	defer delete(contexts)

	for i in 0 ..< PUBSUB_TEST_THREADS {
		pid := PID(0x0001_3B_0001_000000 | u64(i + 1))
		contexts[i] = Pubsub_Thread_Context {
			test_type = test_type,
			pid       = pid,
			barrier   = &barrier,
		}
	}

	threads: [PUBSUB_TEST_THREADS]^thread.Thread
	for i in 0 ..< PUBSUB_TEST_THREADS {
		threads[i] = thread.create_and_start_with_data(&contexts[i], proc(data: rawptr) {
			ctx := cast(^Pubsub_Thread_Context)data
			sync.barrier_wait(ctx.barrier)
			ctx.ok = add_subscriber(ctx.test_type, ctx.pid)
		})
	}

	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	success_count := 0
	for i in 0 ..< PUBSUB_TEST_THREADS {
		if contexts[i].ok {
			success_count += 1
		}
	}

	testing.expectf(
		t,
		success_count == PUBSUB_TEST_THREADS,
		"all %d threads should succeed, got %d",
		PUBSUB_TEST_THREADS,
		success_count,
	)

	testing.expectf(
		t,
		get_subscriber_count(test_type) == PUBSUB_TEST_THREADS,
		"count should be %d, got %d",
		PUBSUB_TEST_THREADS,
		get_subscriber_count(test_type),
	)

	for i in 0 ..< u32(PUBSUB_TEST_THREADS) {
		pid := PID(
			sync.atomic_load_explicit(
				cast(^u64)&type_subscribers[test_type].subscribers[i],
				.Acquire,
			),
		)
		testing.expectf(t, pid != 0, "slot %d should be occupied", i)
	}
}


@(private)
clear_topic :: proc(topic: ^Topic) {
	for i in 0 ..< MAX_TOPIC_SUBSCRIBERS {
		sync.atomic_store_explicit(cast(^u64)&topic.subscribers[i], 0, .Release)
	}
	sync.atomic_store_explicit(&topic.count, 0, .Release)
}

@(test)
test_topic_add_remove :: proc(t: ^testing.T) {
	topic: Topic
	defer clear_topic(&topic)

	pid1 := PID(0x0001_32_0001_000001)
	pid2 := PID(0x0001_32_0001_000002)

	sync.atomic_store_explicit(cast(^u64)&topic.subscribers[0], u64(pid1), .Release)
	sync.atomic_store_explicit(cast(^u64)&topic.subscribers[1], u64(pid2), .Release)
	sync.atomic_store_explicit(&topic.count, 2, .Release)

	testing.expect(t, sync.atomic_load_explicit(&topic.count, .Acquire) == 2, "count should be 2")

	removed := topic_remove_subscriber(&topic, pid1)
	testing.expect(t, removed, "remove should succeed")
	testing.expect(t, sync.atomic_load_explicit(&topic.count, .Acquire) == 1, "count should be 1")

	slot0 := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[0], .Acquire))
	testing.expect(t, slot0 == pid2, "pid2 should be swapped to slot 0")

	slot1 := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[1], .Acquire))
	testing.expect(t, slot1 == 0, "old last slot should be cleared")
}

@(test)
test_topic_remove_last :: proc(t: ^testing.T) {
	topic: Topic
	defer clear_topic(&topic)

	pid1 := PID(0x0001_32_0001_000001)

	sync.atomic_store_explicit(cast(^u64)&topic.subscribers[0], u64(pid1), .Release)
	sync.atomic_store_explicit(&topic.count, 1, .Release)

	removed := topic_remove_subscriber(&topic, pid1)
	testing.expect(t, removed, "remove should succeed")
	testing.expect(t, sync.atomic_load_explicit(&topic.count, .Acquire) == 0, "count should be 0")

	slot0 := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[0], .Acquire))
	testing.expect(t, slot0 == 0, "slot should be cleared")
}

@(test)
test_topic_remove_nonexistent :: proc(t: ^testing.T) {
	topic: Topic
	defer clear_topic(&topic)

	pid1 := PID(0x0001_32_0001_000001)
	bogus := PID(0x0001_32_0001_FFFFFF)

	sync.atomic_store_explicit(cast(^u64)&topic.subscribers[0], u64(pid1), .Release)
	sync.atomic_store_explicit(&topic.count, 1, .Release)

	removed := topic_remove_subscriber(&topic, bogus)
	testing.expect(t, !removed, "remove of nonexistent PID should return false")
	testing.expect(
		t,
		sync.atomic_load_explicit(&topic.count, .Acquire) == 1,
		"count should be unchanged",
	)
}

@(test)
test_topic_remove_nil_topic :: proc(t: ^testing.T) {
	removed := topic_remove_subscriber(nil, PID(1))
	testing.expect(t, !removed, "nil topic should return false")
}

@(test)
test_topic_remove_zero_pid :: proc(t: ^testing.T) {
	topic: Topic
	removed := topic_remove_subscriber(&topic, PID(0))
	testing.expect(t, !removed, "zero PID should return false")
}

@(test)
test_topic_compact_ordering :: proc(t: ^testing.T) {
	topic: Topic
	defer clear_topic(&topic)

	pids: [5]PID
	for i in 0 ..< 5 {
		pids[i] = PID(0x0001_32_0001_000000 | u64(i + 1))
		sync.atomic_store_explicit(cast(^u64)&topic.subscribers[i], u64(pids[i]), .Release)
	}
	sync.atomic_store_explicit(&topic.count, 5, .Release)

	topic_remove_subscriber(&topic, pids[2])
	testing.expect(t, sync.atomic_load_explicit(&topic.count, .Acquire) == 4, "count should be 4")

	slot2 := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[2], .Acquire))
	testing.expect(t, slot2 == pids[4], "last PID should fill the gap")

	for i in 0 ..< u32(4) {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[i], .Acquire))
		testing.expect(t, pid != 0, "slots 0..3 should be non-zero")
	}
	slot4 := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[4], .Acquire))
	testing.expect(t, slot4 == 0, "slot 4 should be cleared")
}

@(test)
test_topic_double_remove :: proc(t: ^testing.T) {
	topic: Topic
	defer clear_topic(&topic)

	pid1 := PID(0x0001_32_0001_000001)
	sync.atomic_store_explicit(cast(^u64)&topic.subscribers[0], u64(pid1), .Release)
	sync.atomic_store_explicit(&topic.count, 1, .Release)

	topic_remove_subscriber(&topic, pid1)
	removed := topic_remove_subscriber(&topic, pid1)
	testing.expect(t, !removed, "double remove should return false")
	testing.expect(
		t,
		sync.atomic_load_explicit(&topic.count, .Acquire) == 0,
		"count should stay 0",
	)
}

TOPIC_TEST_THREADS :: 8

@(test)
test_topic_concurrent_subscribe :: proc(t: ^testing.T) {
	topic: Topic
	defer clear_topic(&topic)

	barrier: sync.Barrier
	sync.barrier_init(&barrier, TOPIC_TEST_THREADS)

	Topic_Thread_Ctx :: struct {
		topic:   ^Topic,
		pid:     PID,
		barrier: ^sync.Barrier,
		ok:      bool,
	}

	contexts := make([]Topic_Thread_Ctx, TOPIC_TEST_THREADS)
	defer delete(contexts)

	for i in 0 ..< TOPIC_TEST_THREADS {
		contexts[i] = Topic_Thread_Ctx {
			topic   = &topic,
			pid     = PID(0x0001_32_0001_000000 | u64(i + 1)),
			barrier = &barrier,
		}
	}

	threads: [TOPIC_TEST_THREADS]^thread.Thread
	for i in 0 ..< TOPIC_TEST_THREADS {
		threads[i] = thread.create_and_start_with_data(&contexts[i], proc(data: rawptr) {
			ctx := cast(^Topic_Thread_Ctx)data
			sync.barrier_wait(ctx.barrier)

			for {
				idx := sync.atomic_load_explicit(&ctx.topic.count, .Acquire)
				if idx >= MAX_TOPIC_SUBSCRIBERS {
					return
				}
				slot := cast(^u64)&ctx.topic.subscribers[idx]
				if _, swapped := sync.atomic_compare_exchange_strong_explicit(
					slot,
					0,
					u64(ctx.pid),
					.Acq_Rel,
					.Acquire,
				); swapped {
					sync.atomic_add_explicit(&ctx.topic.count, 1, .Release)
					ctx.ok = true
					return
				}
			}
		})
	}

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	success := 0
	for i in 0 ..< TOPIC_TEST_THREADS {
		if contexts[i].ok do success += 1
	}

	testing.expectf(
		t,
		success == TOPIC_TEST_THREADS,
		"all %d should succeed, got %d",
		TOPIC_TEST_THREADS,
		success,
	)
	testing.expectf(
		t,
		sync.atomic_load_explicit(&topic.count, .Acquire) == TOPIC_TEST_THREADS,
		"count should be %d, got %d",
		TOPIC_TEST_THREADS,
		sync.atomic_load_explicit(&topic.count, .Acquire),
	)

	for i in 0 ..< u32(TOPIC_TEST_THREADS) {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[i], .Acquire))
		testing.expectf(t, pid != 0, "slot %d should be occupied", i)
	}
}

@(test)
test_clear_node_does_not_affect_local :: proc(t: ^testing.T) {
	test_type := Actor_Type(60)
	defer clear_type_subscribers(test_type)

	saved := current_node_id
	current_node_id = 1
	defer {current_node_id = saved}

	local_pid := PID(0x0001_3C_0001_000001)
	add_subscriber(test_type, local_pid)

	clear_subscriptions_for_node(Node_ID(1)) // should be no-op (local)
	testing.expect(
		t,
		get_subscriber_count(test_type) == 1,
		"local subscriptions should not be cleared",
	)
}
