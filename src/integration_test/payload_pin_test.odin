package integration

import "../actod"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

PAYLOAD_PIN_REPLACEMENT_SPAWNS :: 8
PAYLOAD_PIN_RECLAIM_ROUNDS :: 20
PAYLOAD_PIN_PARK_BUDGET :: 10 * time.Second

Held_Payload_Sender :: struct {
	to:             actod.PID,
	system:         bool,
	payload:        u64,
	result:         actod.Send_Error,
	looked_up:      sync.Sema,
	release:        sync.Sema,
	park_timed_out: bool,
}

held_payload_sender: ^Held_Payload_Sender

hold_payload_sender_after_lookup :: proc(to_pid: actod.PID) {
	sender := held_payload_sender
	if sender == nil || to_pid != sender.to do return
	sync.sema_post(&sender.looked_up)
	if !sync.sema_wait_with_timeout(&sender.release, scaled_timeout(PAYLOAD_PIN_PARK_BUDGET)) {
		sender.park_timed_out = true
	}
}

held_payload_sender_proc :: proc(data: rawptr) {
	sender := cast(^Held_Payload_Sender)data
	info, _ := actod.get_type_info_ptr(u64)
	payload := ([^]byte)(&sender.payload)[:size_of(u64)]
	if sender.system {
		sender.result = actod.send_system_from_payload(sender.to, 0, payload, info)
	} else {
		sender.result = actod.send_from_payload(sender.to, 0, payload, info)
	}
}

actor_is_retired_and_kept :: proc(actor_ptr: rawptr) -> bool {
	sync.mutex_lock(&actod.NODE.reclaim.retire_mutex)
	defer sync.mutex_unlock(&actod.NODE.reclaim.retire_mutex)
	for retired in actod.NODE.reclaim.retire_list {
		if retired.actor_ptr == actor_ptr do return true
	}
	return false
}

churn_replacement_actors :: proc(t: ^testing.T, round: int) {
	for i in 0 ..< PAYLOAD_PIN_REPLACEMENT_SPAWNS {
		name := fmt.tprintf("payload_pin_replacement_%d_%d", round, i)
		pid, ok := actod.spawn(name, Shutdown_Probe{}, shutdown_probe_behaviour)
		if !expect(t, ok, "spawn a replacement actor") do return
		expect(t, actod.terminate_actor(pid, .SHUTDOWN), "terminate a replacement actor")
	}
}

release_held_payload_sender :: proc(
	t: ^testing.T,
	sender: ^Held_Payload_Sender,
	sender_thread: ^^thread.Thread,
) {
	sync.sema_post(&sender.release)
	thread.join(sender_thread^)
	thread.destroy(sender_thread^)
	sender_thread^ = nil
	expectf(
		t,
		!sender.park_timed_out,
		"the parked sender gave up after %v without being released",
		scaled_timeout(PAYLOAD_PIN_PARK_BUDGET),
	)
}

hold_payload_send_across_target_reuse :: proc(t: ^testing.T, system: bool) {
	pid, ok := actod.spawn("payload_pin_target", Shutdown_Probe{}, shutdown_probe_behaviour)
	if !expect(t, ok, "spawn payload_pin_target") do return
	actor_ptr, _ := actod.get(&actod.NODE.actor_registry, pid)
	if !expect(t, actor_ptr != nil, "payload_pin_target is registered") do return

	sender := new(Held_Payload_Sender)
	defer free(sender)
	sender.to = pid
	sender.system = system
	sender.payload = 0xC0FFEE
	held_payload_sender = sender
	actod.payload_send_looked_up_hook = hold_payload_sender_after_lookup
	defer {
		actod.payload_send_looked_up_hook = nil
		held_payload_sender = nil
	}

	running := proc(state: rawptr) -> bool {
		actor_state := sync.atomic_load(&(cast(^actod.Actor)state).state)
		return actor_state == .RUNNING || actor_state == .IDLE
	}
	if !expect(t, poll_until(running, actor_ptr, 2 * time.Second), "payload_pin_target started") do return

	sender_thread := thread.create_and_start_with_data(sender, held_payload_sender_proc)
	defer if sender_thread != nil do release_held_payload_sender(t, sender, &sender_thread)
	if !expect(
		t,
		sync.sema_wait_with_timeout(&sender.looked_up, scaled_timeout(2 * time.Second)),
		"the sender reached the point between lookup and push",
	) {
		return
	}

	expect(t, actod.terminate_actor(pid, .SHUTDOWN), "terminate payload_pin_target")
	retired := proc(state: rawptr) -> bool {return actor_is_retired_and_kept(state)}
	if !expect(
		t,
		poll_until(retired, actor_ptr, 2 * time.Second),
		"payload_pin_target was retired and kept while the sender held it",
	) {
		return
	}

	for round in 0 ..< PAYLOAD_PIN_RECLAIM_ROUNDS {
		churn_replacement_actors(t, round)
		actod.reclaim_scan()
		time.sleep(5 * time.Millisecond)
		actod.reclaim_scan()
	}

	if !expectf(
		t,
		actor_is_retired_and_kept(actor_ptr),
		"payload_pin_target (system %v) was freed while a dedicated-thread sender held it between lookup and push",
		system,
	) {
		return
	}
	held := cast(^actod.Actor)actor_ptr
	expect_value(t, held.pid, pid)

	release_held_payload_sender(t, sender, &sender_thread)

	expectf(
		t,
		sender.result == .OK ||
		sender.result == .ACTOR_NOT_FOUND ||
		sender.result == .RECEIVER_BACKLOGGED,
		"the held payload send returned %v",
		sender.result,
	)

	freed := proc(state: rawptr) -> bool {
		actod.reclaim_scan()
		return !actor_is_retired_and_kept(state)
	}
	expect(
		t,
		poll_until(freed, actor_ptr, 2 * time.Second),
		"payload_pin_target was freed once the sender released its pin",
	)
}

test_payload_send_holds_reclaim_pin_across_target_reuse :: proc(t: ^testing.T) {
	hold_payload_send_across_target_reuse(t, false)
	hold_payload_send_across_target_reuse(t, true)
}
