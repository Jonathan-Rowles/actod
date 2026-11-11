package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

Timer_Hold :: struct {
	interval:        time.Duration,
	repeat:          bool,
	cancel_after:    time.Duration,
	hold:            time.Duration,
	wait_for_filled: bool,
	arm_bystander:   bool,
}

Timer_Filler :: struct {}

Arm_Bystander_Timer :: struct {
	interval: time.Duration,
}

Timer_Victim_Probe :: struct {
	holding:            bool,
	filled:             bool,
	released:           bool,
	timer:              u32,
	cancelled:          u32,
	ticks:              int,
	ticks_after_cancel: int,
	fillers:            int,
	bystander:          actod.PID,
}

Timer_Bystander_Probe :: struct {
	timer:      u32,
	set_at_ns:  i64,
	tick_at_ns: i64,
}

TIMER_BYSTANDER_INTERVAL :: 20 * time.Millisecond
TIMER_BYSTANDER_BOUND :: 70 * time.Millisecond

Timer_Victim :: struct {
	probe: ^Timer_Victim_Probe,
}

Timer_Bystander :: struct {
	probe: ^Timer_Bystander_Probe,
}

timer_probe_now_ns :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now())
}

timer_victim_handle :: proc(d: ^Timer_Victim, from: actod.PID, msg: any) {
	p := d.probe
	switch m in msg {
	case Timer_Hold:
		sync.atomic_store(&p.holding, true)
		if m.wait_for_filled {
			_ = poll_until(
				atomic_flag_raised,
				&p.filled,
				2 * time.Second,
				time.Millisecond,
			)
		}
		id, _ := actod.set_timer(m.interval, m.repeat)
		sync.atomic_store(&p.timer, id)
		if m.arm_bystander {
			_ = actod.send_message(
				p.bystander,
				Arm_Bystander_Timer{interval = TIMER_BYSTANDER_INTERVAL},
			)
		}
		if m.cancel_after > 0 {
			time.sleep(m.cancel_after)
			_ = actod.cancel_timer(id)
			sync.atomic_store(&p.cancelled, id)
		}
		time.sleep(m.hold)
		sync.atomic_store(&p.released, true)
	case Timer_Filler:
		sync.atomic_add(&p.fillers, 1)
	case actod.Timer_Tick:
		if m.id == sync.atomic_load(&p.cancelled) {
			sync.atomic_add(&p.ticks_after_cancel, 1)
		} else if m.id == sync.atomic_load(&p.timer) {
			sync.atomic_add(&p.ticks, 1)
		}
	}
}

timer_bystander_handle :: proc(
	d: ^Timer_Bystander,
	from: actod.PID,
	msg: any,
) {
	p := d.probe
	switch m in msg {
	case Arm_Bystander_Timer:
		sync.atomic_store(&p.set_at_ns, timer_probe_now_ns())
		id, _ := actod.set_timer(m.interval, false)
		sync.atomic_store(&p.timer, id)
	case actod.Timer_Tick:
		if m.id == sync.atomic_load(&p.timer) do sync.atomic_store(&p.tick_at_ns, timer_probe_now_ns())
	}
}

spawn_timer_victim :: proc(
	name: string,
	probe: ^Timer_Victim_Probe,
) -> (
	actod.PID,
	bool,
) {
	return actod.spawn(
		name,
		Timer_Victim{probe = probe},
		actod.Actor_Behaviour(Timer_Victim) {
			handle_message = timer_victim_handle,
		},
		actod.make_actor_config(use_dedicated_os_thread = true),
	)
}

timer_victim_ticked :: proc(state: rawptr) -> bool {
	return sync.atomic_load(&(cast(^Timer_Victim_Probe)state).ticks) > 0
}

timer_bystander_ticked :: proc(state: rawptr) -> bool {
	return(
		sync.atomic_load(&(cast(^Timer_Bystander_Probe)state).tick_at_ns) !=
		0 \
	)
}

test_timer_tick_to_a_full_mailbox_arrives_once_after_the_hold :: proc(
	t: ^testing.T,
) {
	victim_probe: Timer_Victim_Probe
	bystander_probe: Timer_Bystander_Probe

	bystander, bystander_ok := actod.spawn(
		"timer-bystander",
		Timer_Bystander{probe = &bystander_probe},
		actod.Actor_Behaviour(Timer_Bystander) {
			handle_message = timer_bystander_handle,
		},
	)
	expect(t, bystander_ok, "failed to spawn the bystander")
	victim_probe.bystander = bystander

	victim, victim_ok := spawn_timer_victim("timer-victim", &victim_probe)
	expect(t, victim_ok, "failed to spawn the victim")
	if !victim_ok || !bystander_ok do return

	hold := Timer_Hold {
		hold            = 250 * time.Millisecond,
		wait_for_filled = true,
		arm_bystander   = true,
	}
	expect(
		t,
		actod.send_message(victim, hold) == .OK,
		"failed to send the hold",
	)
	expect(
		t,
		poll_until(
			atomic_flag_raised,
			&victim_probe.holding,
			2 * time.Second,
			time.Millisecond,
		),
		"victim never started holding",
	)

	accepted := 0
	for _ in 0 ..< actod.DEFAULT_MAIL_BOX_SIZE {
		if actod.send_message(victim, Timer_Filler{}) == .OK do accepted += 1
	}
	expect_value(t, accepted, actod.DEFAULT_MAIL_BOX_SIZE)
	sync.atomic_store(&victim_probe.filled, true)

	expect(
		t,
		poll_until(
			timer_bystander_ticked,
			&bystander_probe,
			2 * time.Second,
			time.Millisecond,
		),
		"the bystander's tick never arrived",
	)
	bystander_delay := time.Duration(
		sync.atomic_load(&bystander_probe.tick_at_ns) -
		sync.atomic_load(&bystander_probe.set_at_ns),
	)
	expect(
		t,
		bystander_delay < TIMER_BYSTANDER_BOUND,
		"a full mailbox held back another actor's tick",
	)

	expect(
		t,
		poll_until(
			timer_victim_ticked,
			&victim_probe,
			2 * time.Second,
			time.Millisecond,
		),
		"the tick to the full mailbox was lost",
	)
	expect(
		t,
		sync.atomic_load(&victim_probe.released),
		"the tick arrived before the hold ended",
	)
	time.sleep(50 * time.Millisecond)
	expect_value(t, sync.atomic_load(&victim_probe.ticks), 1)
	expect_value(
		t,
		sync.atomic_load(&victim_probe.fillers),
		actod.DEFAULT_MAIL_BOX_SIZE,
	)

	_ = actod.terminate_actor(victim)
	_ = actod.terminate_actor(bystander)
}

test_timer_tick_to_a_full_mailbox_is_not_sent_after_a_cancel :: proc(
	t: ^testing.T,
) {
	probe: Timer_Victim_Probe
	victim, victim_ok := spawn_timer_victim("timer-victim", &probe)
	expect(t, victim_ok, "failed to spawn the victim")
	if !victim_ok do return

	hold := Timer_Hold {
		cancel_after    = 30 * time.Millisecond,
		hold            = 50 * time.Millisecond,
		wait_for_filled = true,
	}
	expect(
		t,
		actod.send_message(victim, hold) == .OK,
		"failed to send the hold",
	)
	expect(
		t,
		poll_until(
			atomic_flag_raised,
			&probe.holding,
			2 * time.Second,
			time.Millisecond,
		),
		"victim never started holding",
	)
	for _ in 0 ..< actod.DEFAULT_MAIL_BOX_SIZE {
		_ = actod.send_message(victim, Timer_Filler{})
	}
	sync.atomic_store(&probe.filled, true)

	expect(
		t,
		poll_until(
			atomic_flag_raised,
			&probe.released,
			2 * time.Second,
			time.Millisecond,
		),
		"victim never ended its hold",
	)
	time.sleep(100 * time.Millisecond)
	expect_value(
		t,
		sync.atomic_load(&probe.fillers),
		actod.DEFAULT_MAIL_BOX_SIZE,
	)
	expect_value(t, sync.atomic_load(&probe.ticks_after_cancel), 0)

	_ = actod.terminate_actor(victim)
}


Timer_Wake_Probe :: struct {
	timer:                u32,
	ticks:                int,
	counting:             bool,
	wakes:                int,
	wakes_under_the_lock: int,
}

Timer_Wake_Owner :: struct {
	probe: ^Timer_Wake_Probe,
}

timer_wake_owner_init :: proc(d: ^Timer_Wake_Owner) {
	id, _ := actod.set_timer(2 * time.Millisecond, true)
	sync.atomic_store(&d.probe.timer, id)
}

timer_wake_owner_handle :: proc(
	d: ^Timer_Wake_Owner,
	from: actod.PID,
	msg: any,
) {
	if tick, ok := msg.(actod.Timer_Tick);
	   ok && tick.id == sync.atomic_load(&d.probe.timer) {
		sync.atomic_add(&d.probe.ticks, 1)
		sync.atomic_store(&d.probe.counting, true)
	}
}

timer_wake_owner_wake :: proc "contextless" (d: ^Timer_Wake_Owner) {
	if !sync.atomic_load(&d.probe.counting) do return
	sync.atomic_add(&d.probe.wakes, 1)
	if sync.mutex_try_lock(&actod.NODE.timer_registry.lock) {
		sync.mutex_unlock(&actod.NODE.timer_registry.lock)
	} else {
		sync.atomic_add(&d.probe.wakes_under_the_lock, 1)
	}
}

timer_wake_owner_ticked_enough :: proc(state: rawptr) -> bool {
	return sync.atomic_load(&(cast(^Timer_Wake_Probe)state).wakes) >= 10
}

test_timer_wakes_its_owner_outside_the_registry_lock :: proc(t: ^testing.T) {
	probe: Timer_Wake_Probe
	owner, ok := actod.spawn(
		"timer-wake-owner",
		Timer_Wake_Owner{probe = &probe},
		actod.Actor_Behaviour(Timer_Wake_Owner) {
			handle_message = timer_wake_owner_handle,
			init = timer_wake_owner_init,
			on_wake = timer_wake_owner_wake,
		},
		actod.make_actor_config(use_dedicated_os_thread = true),
	)
	expect(t, ok, "failed to spawn the timer owner")
	if !ok do return

	expect(
		t,
		poll_until(
			timer_wake_owner_ticked_enough,
			&probe,
			2 * time.Second,
			time.Millisecond,
		),
		"the timer owner was not woken by its ticks",
	)
	expect_value(t, sync.atomic_load(&probe.wakes_under_the_lock), 0)

	_ = actod.terminate_actor(owner)
}
