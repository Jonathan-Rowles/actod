package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

Repeating_Timer_Data :: struct {
	tick_count:     int,
	expected_ticks: int,
	done:           ^sync.Sema,
	timer_id:       u32,
}

Repeating_Timer_Behaviour :: actod.Actor_Behaviour(Repeating_Timer_Data) {
	init           = repeating_timer_init,
	handle_message = repeating_timer_handle,
}

repeating_timer_init :: proc(data: ^Repeating_Timer_Data) {
	data.timer_id, _ = actod.set_timer(10 * time.Millisecond, true)
}

repeating_timer_handle :: proc(data: ^Repeating_Timer_Data, from: actod.PID, msg: any) {
	switch v in msg {
	case actod.Timer_Tick:
		if v.id == data.timer_id {
			data.tick_count += 1
			if data.tick_count >= data.expected_ticks && data.done != nil {
				sync.sema_post(data.done)
			}
		}
	}
}

test_timer_repeating :: proc(t: ^testing.T) {
	done: sync.Sema
	pid, spawn_ok := actod.spawn(
		"timer_test_repeating",
		Repeating_Timer_Data{expected_ticks = 3, done = &done},
		Repeating_Timer_Behaviour,
	)
	testing.expect(t, spawn_ok, "Failed to spawn test actor")
	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	success := sync.sema_wait_with_timeout(&done, 2 * time.Second)
	testing.expect(t, success, "Timer should fire at least 3 ticks")
}

One_Shot_Timer_Data :: struct {
	tick_count: int,
	done:       ^sync.Sema,
	timer_id:   u32,
}

One_Shot_Timer_Behaviour :: actod.Actor_Behaviour(One_Shot_Timer_Data) {
	init           = one_shot_timer_init,
	handle_message = one_shot_timer_handle,
}

one_shot_timer_init :: proc(data: ^One_Shot_Timer_Data) {
	data.timer_id, _ = actod.set_timer(10 * time.Millisecond, false)
}

one_shot_timer_handle :: proc(data: ^One_Shot_Timer_Data, from: actod.PID, msg: any) {
	switch v in msg {
	case actod.Timer_Tick:
		if v.id == data.timer_id {
			data.tick_count += 1
			if data.done != nil && data.tick_count == 1 {
				sync.sema_post(data.done)
			}
		}
	}
}

test_timer_one_shot :: proc(t: ^testing.T) {
	done: sync.Sema
	pid, spawn_ok := actod.spawn(
		"timer_test_oneshot",
		One_Shot_Timer_Data{done = &done},
		One_Shot_Timer_Behaviour,
	)
	testing.expect(t, spawn_ok, "Failed to spawn test actor")
	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	success := sync.sema_wait_with_timeout(&done, 2 * time.Second)
	testing.expect(t, success, "One-shot timer should fire once")

	time.sleep(50 * time.Millisecond)

	actor, got := actod.get_actor_from_pointer(actod.get(&actod.global_registry, pid))
	if got {
		data := cast(^One_Shot_Timer_Data)actor.data
		testing.expect(t, data.tick_count == 1, "One-shot timer should fire exactly once")
	}
}

Cancel_Timer_Data :: struct {
	tick_count: int,
	first_tick: ^sync.Sema,
	timer_id:   u32,
}

Cancel_Timer_Behaviour :: actod.Actor_Behaviour(Cancel_Timer_Data) {
	init           = cancel_timer_init,
	handle_message = cancel_timer_handle,
}

cancel_timer_init :: proc(data: ^Cancel_Timer_Data) {
	data.timer_id, _ = actod.set_timer(10 * time.Millisecond, true)
}

cancel_timer_handle :: proc(data: ^Cancel_Timer_Data, from: actod.PID, msg: any) {
	switch v in msg {
	case actod.Timer_Tick:
		if v.id == data.timer_id {
			data.tick_count += 1
			if data.first_tick != nil && data.tick_count == 1 {
				sync.sema_post(data.first_tick)
			}
		}
	case string:
		if v == "cancel" {
			actod.cancel_timer(data.timer_id)
		}
	}
}

test_timer_cancel :: proc(t: ^testing.T) {
	first_tick: sync.Sema
	pid, spawn_ok := actod.spawn(
		"timer_test_cancel",
		Cancel_Timer_Data{first_tick = &first_tick},
		Cancel_Timer_Behaviour,
	)
	testing.expect(t, spawn_ok, "Failed to spawn test actor")
	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	success := sync.sema_wait_with_timeout(&first_tick, 2 * time.Second)
	testing.expect(t, success, "Timer should fire at least once")

	actod.send_message(pid, "cancel")

	time.sleep(30 * time.Millisecond)

	actor, got := actod.get_actor_from_pointer(actod.get(&actod.global_registry, pid))
	if got {
		count_after := (cast(^Cancel_Timer_Data)actor.data).tick_count
		time.sleep(100 * time.Millisecond)
		count_later := (cast(^Cancel_Timer_Data)actor.data).tick_count
		testing.expect(t, count_later - count_after <= 1, "Timer should stop firing after cancel")
	}
}


Multi_Timer_Data :: struct {
	tick_count: int,
	done:       ^sync.Sema,
}

Multi_Timer_Behaviour :: actod.Actor_Behaviour(Multi_Timer_Data) {
	init           = multi_timer_init,
	handle_message = multi_timer_handle,
}

multi_timer_init :: proc(data: ^Multi_Timer_Data) {
	actod.set_timer(10 * time.Millisecond, false)
	actod.set_timer(15 * time.Millisecond, false)
	actod.set_timer(20 * time.Millisecond, false)
	actod.set_timer(25 * time.Millisecond, false)
}

multi_timer_handle :: proc(data: ^Multi_Timer_Data, from: actod.PID, msg: any) {
	switch v in msg {
	case actod.Timer_Tick:
		data.tick_count += 1
		if data.tick_count >= 4 && data.done != nil {
			sync.sema_post(data.done)
		}
	}
}

test_timer_multiple :: proc(t: ^testing.T) {
	done: sync.Sema
	pid, spawn_ok := actod.spawn(
		"timer_test_multi",
		Multi_Timer_Data{done = &done},
		Multi_Timer_Behaviour,
	)
	testing.expect(t, spawn_ok, "Failed to spawn test actor")
	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	success := sync.sema_wait_with_timeout(&done, 2 * time.Second)
	testing.expect(t, success, "All four one-shot timers should fire")
}

Cleanup_Timer_Data :: struct {
	started: bool,
}

Cleanup_Timer_Behaviour :: actod.Actor_Behaviour(Cleanup_Timer_Data) {
	init           = cleanup_timer_init,
	handle_message = cleanup_timer_handle,
}

cleanup_timer_init :: proc(data: ^Cleanup_Timer_Data) {
	actod.set_timer(10 * time.Millisecond, true)
	actod.set_timer(20 * time.Millisecond, true)
	data.started = true
}

cleanup_timer_handle :: proc(data: ^Cleanup_Timer_Data, from: actod.PID, msg: any) {
	// no-op
}

test_timer_cleanup_on_termination :: proc(t: ^testing.T) {
	pid, spawn_ok := actod.spawn(
		"timer_cleanup_test",
		Cleanup_Timer_Data{},
		Cleanup_Timer_Behaviour,
	)
	testing.expect(t, spawn_ok, "Failed to spawn test actor")

	time.sleep(50 * time.Millisecond)

	actod.terminate_actor(pid)
	actod.wait_for_pids([]actod.PID{pid})

	done: sync.Sema
	verify_pid, verify_ok := actod.spawn(
		"timer_verify",
		Repeating_Timer_Data{expected_ticks = 1, done = &done},
		Repeating_Timer_Behaviour,
	)
	testing.expect(t, verify_ok, "Failed to spawn verify actor")
	defer {
		actod.terminate_actor(verify_pid)
		actod.wait_for_pids([]actod.PID{verify_pid})
	}

	success := sync.sema_wait_with_timeout(&done, 2 * time.Second)
	testing.expect(t, success, "Timer actor should still work after owner cleanup")
}
