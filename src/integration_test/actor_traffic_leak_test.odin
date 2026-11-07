package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

TRAFFIC_LEAK_WARMUP_ROUNDS :: 2000
TRAFFIC_LEAK_MEASURED_ROUNDS :: 40000
TRAFFIC_LEAK_ROUND_BUDGET :: 20 * time.Second
TRAFFIC_LEAK_ARENA_SLACK_BYTES :: 4096
TRAFFIC_LEAK_SHORT_LIVED_CALLERS :: 4000
TRAFFIC_LEAK_PEER_ARENA_SLACK_BYTES :: 64 * 1024

Traffic_Leak_Start :: struct {
	peer:   actod.PID,
	rounds: u64,
}

Traffic_Leak_Rally :: struct {}

Traffic_Leak_Ping :: struct {}

Traffic_Leak_Caller :: struct {
	peer: actod.PID,
}

@(private = "file")
traffic_leak_rallies_finished: int

@(private = "file")
traffic_leak_pings_received: int

traffic_leak_caller_behaviour := actod.Actor_Behaviour(Traffic_Leak_Caller) {
	init           = traffic_leak_caller_init,
	handle_message = traffic_leak_caller_handle_message,
}

traffic_leak_caller_init :: proc(data: ^Traffic_Leak_Caller) {
	_ = actod.send_message(data.peer, Traffic_Leak_Ping{})
	_ = actod.self_terminate()
}

traffic_leak_caller_handle_message :: proc(data: ^Traffic_Leak_Caller, from: actod.PID, msg: any) {
}

traffic_leak_rally_behaviour := actod.Actor_Behaviour(Traffic_Leak_Rally) {
	handle_message = traffic_leak_rally_handle_message,
}

traffic_leak_rally_handle_message :: proc(data: ^Traffic_Leak_Rally, from: actod.PID, msg: any) {
	switch m in msg {
	case Traffic_Leak_Start:
		_ = actod.send_message(m.peer, m.rounds)
	case Traffic_Leak_Ping:
		sync.atomic_add(&traffic_leak_pings_received, 1)
	case u64:
		if m == 0 {
			sync.atomic_add(&traffic_leak_rallies_finished, 1)
			return
		}
		_ = actod.send_message(from, m - 1)
	}
}

@(private = "file")
traffic_leak_rallies_reached :: proc(state: rawptr) -> bool {
	return sync.atomic_load(&traffic_leak_rallies_finished) >= (cast(^int)state)^
}

@(private = "file")
traffic_leak_pings_reached :: proc(state: rawptr) -> bool {
	return sync.atomic_load(&traffic_leak_pings_received) >= (cast(^int)state)^
}

@(private = "file")
arena_bytes_outside_message_pool :: proc(pid: actod.PID) -> int {
	a, ok := actod.get_actor_from_pointer(actod.get(&actod.NODE.actor_registry, pid), true)
	if !ok do return 0
	arena_used := int(a.arena.primary.total_used + a.arena.overflow.total_used)
	pool_pages := sync.atomic_load(&a.pool.allocated_count)
	return arena_used - pool_pages * a.pool.page_size
}

@(private = "file")
run_traffic_rally :: proc(t: ^testing.T, server, receiver: actod.PID, rounds: u64) -> bool {
	target := sync.atomic_load(&traffic_leak_rallies_finished) + 1
	_ = actod.send_message(server, Traffic_Leak_Start{peer = receiver, rounds = rounds})
	finished := poll_until(traffic_leak_rallies_reached, &target, TRAFFIC_LEAK_ROUND_BUDGET)
	expectf(t, finished, "a rally of %d messages never finished", rounds)
	return finished
}

test_actor_traffic_memory_flat_while_observer_never_collects :: proc(t: ^testing.T) {
	_, started := actod.start_observer()
	expect(t, started, "failed to start observer")
	if !started do return

	server, server_spawned := actod.spawn(
		"traffic-leak-server",
		Traffic_Leak_Rally{},
		traffic_leak_rally_behaviour,
	)
	receiver, receiver_spawned := actod.spawn(
		"traffic-leak-receiver",
		Traffic_Leak_Rally{},
		traffic_leak_rally_behaviour,
	)
	expect(t, server_spawned && receiver_spawned, "failed to spawn the rally pair")
	if !server_spawned || !receiver_spawned do return

	if !run_traffic_rally(t, server, receiver, TRAFFIC_LEAK_WARMUP_ROUNDS) do return
	server_baseline := arena_bytes_outside_message_pool(server)
	receiver_baseline := arena_bytes_outside_message_pool(receiver)

	if !run_traffic_rally(t, server, receiver, TRAFFIC_LEAK_MEASURED_ROUNDS) do return
	server_growth := arena_bytes_outside_message_pool(server) - server_baseline
	receiver_growth := arena_bytes_outside_message_pool(receiver) - receiver_baseline

	expectf(
		t,
		server_growth <= TRAFFIC_LEAK_ARENA_SLACK_BYTES,
		"server arena grew by %d bytes outside its message pool over %d uncollected messages",
		server_growth,
		TRAFFIC_LEAK_MEASURED_ROUNDS,
	)
	expectf(
		t,
		receiver_growth <= TRAFFIC_LEAK_ARENA_SLACK_BYTES,
		"receiver arena grew by %d bytes outside its message pool over %d uncollected messages",
		receiver_growth,
		TRAFFIC_LEAK_MEASURED_ROUNDS,
	)

	receiver_before_callers := arena_bytes_outside_message_pool(receiver)
	pings_target :=
		sync.atomic_load(&traffic_leak_pings_received) + TRAFFIC_LEAK_SHORT_LIVED_CALLERS
	for _ in 0 ..< TRAFFIC_LEAK_SHORT_LIVED_CALLERS {
		_, caller_spawned := actod.spawn(
			"traffic-leak-caller",
			Traffic_Leak_Caller{peer = receiver},
			traffic_leak_caller_behaviour,
		)
		expect(t, caller_spawned, "failed to spawn a short-lived caller")
		if !caller_spawned do return
	}
	pinged := poll_until(traffic_leak_pings_reached, &pings_target, TRAFFIC_LEAK_ROUND_BUDGET)
	expectf(
		t,
		pinged,
		"the receiver never heard from all %d short-lived callers",
		TRAFFIC_LEAK_SHORT_LIVED_CALLERS,
	)
	if !pinged do return
	receiver_caller_growth := arena_bytes_outside_message_pool(receiver) - receiver_before_callers

	expectf(
		t,
		receiver_caller_growth <= TRAFFIC_LEAK_PEER_ARENA_SLACK_BYTES,
		"receiver arena grew by %d bytes outside its message pool after hearing from %d distinct short-lived callers",
		receiver_caller_growth,
		TRAFFIC_LEAK_SHORT_LIVED_CALLERS,
	)

	actod.stop_observer()
	_ = actod.terminate_actor(server)
	_ = actod.terminate_actor(receiver)
}
