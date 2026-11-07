package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

OBSERVER_LEAK_CHATTERS :: 4
OBSERVER_LEAK_INTERVAL :: time.Millisecond
OBSERVER_LEAK_WARMUP_TICKS :: 200
OBSERVER_LEAK_MEASURED_TICKS :: 2000
OBSERVER_LEAK_TICK_BUDGET :: 20 * time.Second
OBSERVER_LEAK_SETTLE :: 50 * time.Millisecond
OBSERVER_ARENA_SLACK_BYTES :: 4096
OBSERVER_HEAP_SLACK_ALLOCATIONS :: 64

Observer_Leak_Chatter :: struct {
	peer: actod.PID,
}

Observer_Leak_Peer :: struct {
	peer: actod.PID,
}

Observer_Memory :: struct {
	arena_bytes:      int,
	heap_allocations: int,
}

observer_leak_chatter_behaviour := actod.Actor_Behaviour(Observer_Leak_Chatter) {
	handle_message = observer_leak_chatter_handle_message,
}

observer_leak_chatter_handle_message :: proc(
	data: ^Observer_Leak_Chatter,
	from: actod.PID,
	msg: any,
) {
	switch m in msg {
	case Observer_Leak_Peer:
		data.peer = m.peer
		_, _ = actod.set_timer(OBSERVER_LEAK_INTERVAL, true)
	case actod.Timer_Tick:
		if data.peer != {} do _ = actod.send_message(data.peer, u64(1))
	}
}

@(private = "file")
observer_actor :: proc() -> ^actod.Actor {
	a, ok := actod.get_actor_from_pointer(
		actod.get(&actod.NODE.actor_registry, actod.NODE.observer_pid),
		true,
	)
	return a if ok else nil
}

@(private = "file")
observer_collection_count :: proc() -> int {
	observer := observer_actor()
	if observer == nil do return 0
	return sync.atomic_load(&(cast(^actod.Observer_Data)observer.data).collection_count)
}

@(private = "file")
observer_reached_tick :: proc(state: rawptr) -> bool {
	return observer_collection_count() >= (cast(^int)state)^
}

@(private = "file")
observer_mailbox_empty :: proc(state: rawptr) -> bool {
	observer := observer_actor()
	return observer != nil && actod.mpsc_size(&observer.mailbox) == 0
}

@(private = "file")
observer_arena_bytes_outside_message_pool :: proc() -> int {
	observer := observer_actor()
	if observer == nil do return 0
	arena_used := int(observer.arena.primary.total_used + observer.arena.overflow.total_used)
	pool_pages := sync.atomic_load(&observer.pool.allocated_count)
	return arena_used - pool_pages * observer.pool.page_size
}

@(private = "file")
settle_observer :: proc(t: ^testing.T) -> Observer_Memory {
	_ = actod.send_message(actod.NODE.observer_pid, actod.Set_Collection_Interval{})
	time.sleep(OBSERVER_LEAK_SETTLE)
	expect(
		t,
		poll_until(observer_mailbox_empty, nil, 2 * time.Second),
		"observer mailbox never drained after collection was paused",
	)
	time.sleep(OBSERVER_LEAK_SETTLE)
	return {
		arena_bytes = observer_arena_bytes_outside_message_pool(),
		heap_allocations = actod.system_allocator_live_allocations(),
	}
}

@(private = "file")
run_observer_until_tick :: proc(t: ^testing.T, target_tick: int) -> bool {
	_ = actod.send_message(
		actod.NODE.observer_pid,
		actod.Set_Collection_Interval{interval = OBSERVER_LEAK_INTERVAL},
	)
	target := target_tick
	reached := poll_until(observer_reached_tick, &target, OBSERVER_LEAK_TICK_BUDGET)
	expectf(t, reached, "observer never reached collection tick %d", target_tick)
	return reached
}

test_observer_memory_flat_across_collection_ticks :: proc(t: ^testing.T) {
	chatters: [OBSERVER_LEAK_CHATTERS]actod.PID
	for &pid in chatters {
		spawned: bool
		pid, spawned = actod.spawn(
			"observer-leak-chatter",
			Observer_Leak_Chatter{},
			observer_leak_chatter_behaviour,
		)
		expect(t, spawned, "failed to spawn chatter")
		if !spawned do return
	}

	_, started := actod.start_observer()
	expect(t, started, "failed to start observer")
	if !started do return

	for pid, i in chatters {
		_ = actod.send_message(pid, Observer_Leak_Peer{peer = chatters[(i + 1) % len(chatters)]})
	}

	if !run_observer_until_tick(t, OBSERVER_LEAK_WARMUP_TICKS) do return
	baseline := settle_observer(t)
	baseline_tick := observer_collection_count()

	if !run_observer_until_tick(t, baseline_tick + OBSERVER_LEAK_MEASURED_TICKS) do return
	after := settle_observer(t)
	measured_ticks := observer_collection_count() - baseline_tick

	expectf(
		t,
		after.arena_bytes - baseline.arena_bytes <= OBSERVER_ARENA_SLACK_BYTES,
		"observer arena grew by %d bytes outside its message pool over %d collection ticks",
		after.arena_bytes - baseline.arena_bytes,
		measured_ticks,
	)
	expectf(
		t,
		after.heap_allocations - baseline.heap_allocations <= OBSERVER_HEAP_SLACK_ALLOCATIONS,
		"system heap holds %d more live allocations after %d collection ticks",
		after.heap_allocations - baseline.heap_allocations,
		measured_ticks,
	)

	actod.stop_observer()
	for pid in chatters do _ = actod.terminate_actor(pid)
}
