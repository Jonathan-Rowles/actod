package actod

import pq "core:container/priority_queue"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
begin_timer_test :: proc() {
	sync.mutex_lock(&timer_registry.lock)
	timer_registry.heap = {}
	timer_registry.heap.less = timer_heap_less
	timer_registry.heap.swap = timer_heap_swap
	timer_registry.index_map = {}
}

@(private = "file")
finish_timer_test :: proc() {
	delete(timer_registry.heap.queue)
	timer_registry.heap = {}
	delete(timer_registry.index_map)
	timer_registry.index_map = {}
	sync.mutex_unlock(&timer_registry.lock)
}

@(private = "file")
make_time :: proc(nsec: i64) -> time.Time {
	return time.Time{_nsec = nsec}
}

@(private = "file")
add_timer :: proc(
	id: u32,
	owner: PID,
	next_fire: time.Time,
	interval: time.Duration,
	repeat: bool,
) {
	entry := Timer_Entry {
		id        = id,
		owner     = owner,
		interval  = interval,
		next_fire = next_fire,
		repeat    = repeat,
	}
	key := Timer_Key{id, owner}
	timer_registry.index_map[key] = pq.len(timer_registry.heap)
	pq.push(&timer_registry.heap, entry)
}

@(private = "file")
verify_index_map :: proc(t: ^testing.T) {
	for i in 0 ..< pq.len(timer_registry.heap) {
		entry := timer_registry.heap.queue[i]
		key := Timer_Key{entry.id, entry.owner}
		idx, ok := timer_registry.index_map[key]
		testing.expect(t, ok, "entry should be in index_map")
		testing.expect_value(t, idx, i)
	}
}

@(test)
test_heap_ordering_earliest_first :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	add_timer(1, 100, make_time(3000), time.Second, false)
	add_timer(2, 100, make_time(1000), time.Second, false)
	add_timer(3, 100, make_time(2000), time.Second, false)

	top := pq.peek(timer_registry.heap)
	testing.expect_value(t, top.id, u32(2))

	entry, _ := pq.pop_safe(&timer_registry.heap)
	testing.expect_value(t, entry.id, u32(2))

	entry, _ = pq.pop_safe(&timer_registry.heap)
	testing.expect_value(t, entry.id, u32(3))

	entry, _ = pq.pop_safe(&timer_registry.heap)
	testing.expect_value(t, entry.id, u32(1))
}

@(test)
test_index_map_tracks_positions :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	add_timer(1, 100, make_time(3000), time.Second, false)
	add_timer(2, 100, make_time(1000), time.Second, false)
	add_timer(3, 100, make_time(2000), time.Second, false)

	verify_index_map(t)
}

@(test)
test_cancel_by_key :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	add_timer(1, 100, make_time(1000), time.Second, false)
	add_timer(2, 100, make_time(2000), time.Second, false)
	add_timer(3, 100, make_time(3000), time.Second, false)

	key := Timer_Key{2, 100}
	if idx, ok := timer_registry.index_map[key]; ok {
		pq.remove(&timer_registry.heap, idx)
		delete_key(&timer_registry.index_map, key)
	}

	testing.expect_value(t, pq.len(timer_registry.heap), 2)
	testing.expect(
		t,
		!(key in timer_registry.index_map),
		"cancelled timer should not be in index_map",
	)

	top := pq.peek(timer_registry.heap)
	testing.expect_value(t, top.id, u32(1))

	verify_index_map(t)
}

@(test)
test_duplicate_detection :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	add_timer(1, 100, make_time(1000), time.Second, false)

	key := Timer_Key{1, 100}
	testing.expect(t, key in timer_registry.index_map, "timer should exist")
}

@(test)
test_repeating_timer_repush :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	add_timer(1, 100, make_time(1000), time.Second, true)
	add_timer(2, 100, make_time(2000), time.Second, false)
	add_timer(3, 100, make_time(3000), time.Second, false)

	entry, _ := pq.pop_safe(&timer_registry.heap)
	delete_key(&timer_registry.index_map, Timer_Key{entry.id, entry.owner})
	testing.expect_value(t, entry.id, u32(1))

	entry.next_fire = time.time_add(entry.next_fire, entry.interval)

	timer_registry.index_map[Timer_Key{entry.id, entry.owner}] = pq.len(timer_registry.heap)
	pq.push(&timer_registry.heap, entry)

	top := pq.peek(timer_registry.heap)
	testing.expect_value(t, top.id, u32(2))

	verify_index_map(t)
}

@(test)
test_drift_free_repeat :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	interval := 100 * time.Millisecond
	scheduled_fire := make_time(1_000_000_000)
	add_timer(1, 100, scheduled_fire, interval, true)

	entry, _ := pq.pop_safe(&timer_registry.heap)
	delete_key(&timer_registry.index_map, Timer_Key{entry.id, entry.owner})

	entry.next_fire = time.time_add(entry.next_fire, entry.interval)

	expected := make_time(1_100_000_000)
	testing.expect_value(t, entry.next_fire, expected)
}

@(test)
test_catchup_when_behind :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	interval := 100 * time.Millisecond
	scheduled_fire := make_time(1_000_000_000)
	add_timer(1, 100, scheduled_fire, interval, true)

	entry, _ := pq.pop_safe(&timer_registry.heap)
	delete_key(&timer_registry.index_map, Timer_Key{entry.id, entry.owner})

	now := make_time(1_500_000_000)

	entry.next_fire = time.time_add(entry.next_fire, entry.interval)
	if time.diff(now, entry.next_fire) <= 0 {
		entry.next_fire = time.time_add(now, entry.interval)
	}

	expected := make_time(1_600_000_000)
	testing.expect_value(t, entry.next_fire, expected)
}

@(test)
test_same_id_different_owners :: proc(t: ^testing.T) {
	begin_timer_test()
	defer finish_timer_test()

	add_timer(1, 100, make_time(2000), time.Second, false)
	add_timer(1, 200, make_time(1000), time.Second, false)

	testing.expect_value(t, pq.len(timer_registry.heap), 2)
	testing.expect(
		t,
		(Timer_Key{1, 100}) in timer_registry.index_map,
		"owner 100 timer should exist",
	)
	testing.expect(
		t,
		(Timer_Key{1, 200}) in timer_registry.index_map,
		"owner 200 timer should exist",
	)

	key := Timer_Key{1, 200}
	idx := timer_registry.index_map[key]
	pq.remove(&timer_registry.heap, idx)
	delete_key(&timer_registry.index_map, key)

	testing.expect_value(t, pq.len(timer_registry.heap), 1)
	testing.expect(
		t,
		(Timer_Key{1, 100}) in timer_registry.index_map,
		"owner 100 timer should still exist",
	)

	verify_index_map(t)
}
