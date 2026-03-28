package actod

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"

@(test)
test_mpsc_basic_operations :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 16)
	init_mpsc(&queue)

	{
		ok := mpsc_push(&queue, 42)
		testing.expect(t, ok, "Should be able to push to empty queue")

		value: int
		ok = mpsc_pop(&queue, &value)
		testing.expect(t, ok, "Should be able to pop from non-empty queue")
		testing.expect_value(t, value, 42)
	}

	{
		value: int
		ok := mpsc_pop(&queue, &value)
		testing.expect(t, !ok, "Should not be able to pop from empty queue")

		empty := mpsc_is_empty(&queue)
		testing.expect(t, empty, "Queue should be empty")
	}

	{
		for i := 0; i < 10; i += 1 {
			ok := mpsc_push(&queue, i)
			testing.expect(t, ok, fmt.tprintf("Should push item %d", i))
		}

		for i := 0; i < 10; i += 1 {
			value: int
			ok := mpsc_pop(&queue, &value)
			testing.expect(t, ok, fmt.tprintf("Should pop item %d", i))
			testing.expect_value(t, value, i)
		}
	}
}

@(test)
test_mpsc_capacity :: proc(t: ^testing.T) {
	CAPACITY :: 8
	queue: MPSC_Queue(int, CAPACITY)
	init_mpsc(&queue)

	for i := 0; i < CAPACITY; i += 1 {
		ok := mpsc_push(&queue, i)
		testing.expect(t, ok, fmt.tprintf("Should push item %d within capacity", i))
	}

	ok := mpsc_push(&queue, CAPACITY)
	if ok {
		value: int
		mpsc_pop(&queue, &value)
		ok = mpsc_push(&queue, CAPACITY)
		ok = mpsc_push(&queue, CAPACITY + 1)
		testing.expect(t, !ok, "Should not be able to push beyond capacity")
	}

	count := 0
	value: int
	for mpsc_pop(&queue, &value) {
		testing.expect(t, value == count, fmt.tprintf("Expected value %d, got %d", count, value))
		count += 1
	}

	testing.expect(t, count >= CAPACITY, "Should have popped at least CAPACITY items")
}

@(test)
test_mpsc_peek :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 8)
	init_mpsc(&queue)

	{
		value: int
		ok := mpsc_peek(&queue, &value)
		testing.expect(t, !ok, "Peek should fail on empty queue")
	}

	{
		mpsc_push(&queue, 100)
		mpsc_push(&queue, 200)

		value: int
		ok := mpsc_peek(&queue, &value)
		testing.expect(t, ok, "Peek should succeed on non-empty queue")
		testing.expect_value(t, value, 100)

		ok = mpsc_peek(&queue, &value)
		testing.expect(t, ok, "Second peek should succeed")
		testing.expect_value(t, value, 100)

		ok = mpsc_pop(&queue, &value)
		testing.expect(t, ok, "Pop should succeed after peek")
		testing.expect_value(t, value, 100)

		ok = mpsc_peek(&queue, &value)
		testing.expect(t, ok, "Peek should see next item")
		testing.expect_value(t, value, 200)
	}
}

@(test)
test_mpsc_batch_operations :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 64)
	init_mpsc(&queue)

	ITEM_COUNT :: 50
	for i := 0; i < ITEM_COUNT; i += 1 {
		ok := mpsc_push(&queue, i)
		testing.expect(t, ok, fmt.tprintf("Should push item %d", i))
	}

	batch1: [20]int
	batch2: [20]int
	batch3: [20]int

	count1 := mpsc_pop_batch(&queue, batch1[:])
	count2 := mpsc_pop_batch(&queue, batch2[:])
	count3 := mpsc_pop_batch(&queue, batch3[:])

	total := count1 + count2 + count3
	testing.expect(
		t,
		total == ITEM_COUNT,
		fmt.tprintf("Should pop all items: expected %d, got %d", ITEM_COUNT, total),
	)

	expected := 0

	for i := 0; i < count1; i += 1 {
		testing.expect_value(t, batch1[i], expected)
		expected += 1
	}

	for i := 0; i < count2; i += 1 {
		testing.expect_value(t, batch2[i], expected)
		expected += 1
	}

	for i := 0; i < count3; i += 1 {
		testing.expect_value(t, batch3[i], expected)
		expected += 1
	}

	testing.expect_value(t, expected, ITEM_COUNT)
}

@(test)
test_mpsc_spsc :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 32)
	init_mpsc(&queue)

	ITEM_COUNT :: 100
	done := false

	Producer_Context :: struct {
		queue: ^MPSC_Queue(int, 32),
		count: int,
		done:  ^bool,
	}

	ctx := Producer_Context {
		queue = &queue,
		count = ITEM_COUNT,
		done  = &done,
	}

	producer := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := cast(^Producer_Context)data
		for i := 0; i < ctx.count; i += 1 {
			for !mpsc_push(ctx.queue, i) {
				thread.yield()
			}
		}
		sync.atomic_store(ctx.done, true)
	})

	received := make([dynamic]int)
	defer delete(received)

	for len(received) < ITEM_COUNT {
		value: int
		if mpsc_pop(&queue, &value) {
			append(&received, value)
		} else if sync.atomic_load(&done) {
			for mpsc_pop(&queue, &value) {
				append(&received, value)
			}
			break
		} else {
			thread.yield()
		}
	}

	thread.join(producer)
	thread.destroy(producer)

	testing.expect(
		t,
		len(received) == ITEM_COUNT,
		fmt.tprintf("Expected %d items, got %d", ITEM_COUNT, len(received)),
	)

	for i, val in received {
		testing.expect_value(t, val, i)
	}
}

@(test)
test_mpsc_multiple_producers :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 256)
	init_mpsc(&queue)

	PRODUCER_COUNT :: 3
	ITEMS_PER_PRODUCER :: 50
	TOTAL_ITEMS :: PRODUCER_COUNT * ITEMS_PER_PRODUCER

	producers_done := 0

	Producer_Context :: struct {
		queue:       ^MPSC_Queue(int, 256),
		producer_id: int,
		item_count:  int,
		done_count:  ^int,
	}

	producers: [PRODUCER_COUNT]^thread.Thread
	contexts: [PRODUCER_COUNT]Producer_Context

	for i := 0; i < PRODUCER_COUNT; i += 1 {
		contexts[i] = Producer_Context {
			queue       = &queue,
			producer_id = i,
			item_count  = ITEMS_PER_PRODUCER,
			done_count  = &producers_done,
		}

		producers[i] = thread.create_and_start_with_data(&contexts[i], proc(data: rawptr) {
			ctx := cast(^Producer_Context)data
			base_value := ctx.producer_id * 1000

			for i := 0; i < ctx.item_count; i += 1 {
				value := base_value + i
				attempts := 0
				for !mpsc_push(ctx.queue, value) {
					thread.yield()
					attempts += 1
					if attempts > 10000 {
						fmt.printf(
							"Producer %d failed to push value %d after %d attempts\n",
							ctx.producer_id,
							value,
							attempts,
						)
						break
					}
				}
			}

			sync.atomic_add(ctx.done_count, 1)
		})
	}

	received := make(map[int]bool)
	defer delete(received)

	for len(received) < TOTAL_ITEMS {
		value: int
		if mpsc_pop(&queue, &value) {
			_, exists := received[value]
			if exists {
				testing.fail_now(t, fmt.tprintf("Duplicate value received: %d", value))
			}
			received[value] = true
		} else if sync.atomic_load(&producers_done) == PRODUCER_COUNT {
			for mpsc_pop(&queue, &value) {
				_, exists := received[value]
				if exists {
					testing.fail_now(t, fmt.tprintf("Duplicate value received: %d", value))
				}
				received[value] = true
			}
			break
		} else {
			thread.yield()
		}

	}

	for i := 0; i < PRODUCER_COUNT; i += 1 {
		thread.join(producers[i])
		thread.destroy(producers[i])
	}

	testing.expect(
		t,
		len(received) == TOTAL_ITEMS,
		fmt.tprintf("Expected %d items, got %d", TOTAL_ITEMS, len(received)),
	)

	for p := 0; p < PRODUCER_COUNT; p += 1 {
		base_value := p * 1000
		for i := 0; i < ITEMS_PER_PRODUCER; i += 1 {
			value := base_value + i
			_, exists := received[value]
			testing.expect(t, exists, fmt.tprintf("Missing value %d from producer %d", value, p))
		}
	}
}

@(test)
test_mpsc_concurrent_stress :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 128)
	init_mpsc(&queue)

	TARGET_ITEMS :: 100000
	stop_flag := false

	total_pushed := 0
	total_popped := 0

	Producer_Stress_Context :: struct {
		queue:   ^MPSC_Queue(int, 128),
		stop:    ^bool,
		counter: ^int,
	}

	ctx := Producer_Stress_Context {
		queue   = &queue,
		stop    = &stop_flag,
		counter = &total_pushed,
	}

	producer := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := cast(^Producer_Stress_Context)data

		value := 0
		for value < TARGET_ITEMS && !sync.atomic_load(ctx.stop) {
			if mpsc_push(ctx.queue, value) {
				sync.atomic_add(ctx.counter, 1)
				value += 1
			} else {
				thread.yield()
			}
		}
	})

	for total_popped < TARGET_ITEMS {
		value: int
		if mpsc_pop(&queue, &value) {
			total_popped += 1
		} else if sync.atomic_load(&stop_flag) {
			break
		} else {
			thread.yield()
		}
	}

	sync.atomic_store(&stop_flag, true)
	thread.join(producer)
	thread.destroy(producer)

	value: int
	for mpsc_pop(&queue, &value) {
		total_popped += 1
	}

	pushed := sync.atomic_load(&total_pushed)

	testing.expect(
		t,
		total_popped == pushed,
		fmt.tprintf("Mismatch: pushed %d, popped %d", pushed, total_popped),
	)

	testing.expect(t, total_popped > 0, "Should have processed some items")

	fmt.printf("Concurrent stress test: processed %d items\n", total_popped)
}

@(test)
test_mpsc_state_functions :: proc(t: ^testing.T) {
	queue: MPSC_Queue(int, 8)
	init_mpsc(&queue)

	testing.expect(t, mpsc_is_empty(&queue), "New queue should be empty")

	mpsc_push(&queue, 1)
	testing.expect(t, !mpsc_is_empty(&queue), "Queue with item should not be empty")

	for i := 0; i < 7; i += 1 {
		mpsc_push(&queue, i)
	}

	ok := mpsc_push(&queue, 99)
	if !ok {
		fmt.println("Queue appears to be full at 8 items")
	}

	value: int
	count := 0
	for mpsc_pop(&queue, &value) {
		count += 1
	}

	testing.expect(t, mpsc_is_empty(&queue), "Queue should be empty after draining")
	testing.expect(
		t,
		count >= 8,
		fmt.tprintf("Should have popped at least 8 items, got %d", count),
	)
}

@(test)
test_mpsc_data_integrity :: proc(t: ^testing.T) {
	Test_Struct :: struct {
		id:       u64,
		data:     [4]u32,
		checksum: u32,
	}

	make_checksum :: proc(s: ^Test_Struct) -> u32 {
		return u32(s.id) ~ s.data[0] ~ s.data[1] ~ s.data[2] ~ s.data[3]
	}

	queue: MPSC_Queue(Test_Struct, 32)
	init_mpsc(&queue)

	TEST_COUNT :: 20
	for i := 0; i < TEST_COUNT; i += 1 {
		item := Test_Struct {
			id   = u64(i),
			data = {u32(i), u32(i + 1), u32(i + 2), u32(i + 3)},
		}
		item.checksum = make_checksum(&item)

		ok := mpsc_push(&queue, item)
		testing.expect(t, ok, fmt.tprintf("Should push item %d", i))
	}

	for i := 0; i < TEST_COUNT; i += 1 {
		item: Test_Struct
		ok := mpsc_pop(&queue, &item)
		testing.expect(t, ok, fmt.tprintf("Should pop item %d", i))

		expected_checksum := make_checksum(&item)
		testing.expect(
			t,
			item.checksum == expected_checksum,
			fmt.tprintf("Checksum mismatch for item %d", i),
		)
		testing.expect_value(t, item.id, u64(i))
		testing.expect_value(t, item.data[0], u32(i))
		testing.expect_value(t, item.data[1], u32(i + 1))
		testing.expect_value(t, item.data[2], u32(i + 2))
		testing.expect_value(t, item.data[3], u32(i + 3))
	}
}
