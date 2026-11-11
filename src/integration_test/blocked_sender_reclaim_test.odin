package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

BLOCKED_SENDER_SENDER_WORKER :: 1
BLOCKED_SENDER_SENDS :: 2000
BLOCKED_SENDER_MIN_SAMPLES :: 20
BLOCKED_SENDER_RECEIVE_DELAY :: 50 * time.Microsecond
BLOCKED_SENDER_SAMPLE_INTERVAL :: time.Millisecond
BLOCKED_SENDER_BUDGET :: 10 * time.Second

Blocked_Sender_Start :: struct {
	to: actod.PID,
}

Blocked_Sender_Probe :: struct {
	slot:     int,
	sending:  bool,
	finished: bool,
	failed:   int,
}

blocked_sender_probe: Blocked_Sender_Probe

spin_for :: proc(d: time.Duration) {
	start := time.tick_now()
	for time.tick_since(start) < d {}
}

Blocked_Sender_Receiver :: struct {}

Blocked_Sender :: struct {}

blocked_sender_receiver_behaviour := actod.Actor_Behaviour(
	Blocked_Sender_Receiver,
) {
	handle_message = proc(
		d: ^Blocked_Sender_Receiver,
		from: actod.PID,
		msg: any,
	) {
		if _, ok := msg.(u64); ok do spin_for(BLOCKED_SENDER_RECEIVE_DELAY)
	},
}

blocked_sender_behaviour := actod.Actor_Behaviour(Blocked_Sender) {
	handle_message = proc(d: ^Blocked_Sender, from: actod.PID, msg: any) {
		start, ok := msg.(Blocked_Sender_Start)
		if !ok do return
		sync.atomic_store(
			&blocked_sender_probe.slot,
			actod.reclaim_slot_of_this_thread(),
		)
		sync.atomic_store(&blocked_sender_probe.sending, true)
		failed := 0
		for i in 0 ..< BLOCKED_SENDER_SENDS {
			if actod.send_message(start.to, u64(i)) != .OK do failed += 1
		}
		sync.atomic_store(&blocked_sender_probe.failed, failed)
		sync.atomic_store(&blocked_sender_probe.sending, false)
		sync.atomic_store(&blocked_sender_probe.finished, true)
	},
}

test_blocked_cross_worker_sender_releases_reclaim_slot :: proc(t: ^testing.T) {
	blocked_sender_probe = Blocked_Sender_Probe {
		slot = -1,
	}

	receiver, receiver_ok := actod.spawn(
		"blocked_sender_receiver",
		Blocked_Sender_Receiver{},
		blocked_sender_receiver_behaviour,
		actod.make_actor_config(
			use_dedicated_os_thread = true,
			logging = actod.make_log_config(level = test_log_level()),
		),
	)
	if !expect(t, receiver_ok, "spawn the receiver") do return
	defer _ = actod.terminate_actor(receiver, .SHUTDOWN)

	sender, sender_ok := actod.spawn(
		"blocked_sender",
		Blocked_Sender{},
		blocked_sender_behaviour,
		actod.make_actor_config(
			home_worker = BLOCKED_SENDER_SENDER_WORKER,
			logging = actod.make_log_config(level = test_log_level()),
		),
	)
	if !expect(t, sender_ok, "spawn the sender") do return
	defer _ = actod.terminate_actor(sender, .SHUTDOWN)

	if !expect(t, actod.send_message(sender, Blocked_Sender_Start{to = receiver}) == .OK, "start the sender") do return

	sending_started := poll_until(
		atomic_flag_raised,
		&blocked_sender_probe.sending,
		BLOCKED_SENDER_BUDGET,
		10 * time.Microsecond,
	)
	if !expect(t, sending_started, "the sender started its sends") do return

	slot := sync.atomic_load(&blocked_sender_probe.slot)
	if !expectf(t, slot >= 0, "the sender's worker holds a reclaim slot, got index %d", slot) do return

	samples := 0
	held_samples := 0
	max_lag: u64
	previous_epoch: u64
	sampling_start := time.tick_now()
	for sync.atomic_load(&blocked_sender_probe.sending) {
		if time.tick_since(sampling_start) > scaled_timeout(BLOCKED_SENDER_BUDGET) do break
		actod.reclaim_scan()
		slot_epoch := sync.atomic_load(
			&actod.NODE.reclaim.slots[slot].active_epoch,
		)
		global_epoch := sync.atomic_load(&actod.NODE.reclaim.epoch)
		samples += 1
		if slot_epoch != 0 {
			if slot_epoch == previous_epoch do held_samples += 1
			max_lag = max(max_lag, global_epoch - slot_epoch)
		}
		previous_epoch = slot_epoch
		spin_for(BLOCKED_SENDER_SAMPLE_INTERVAL)
	}

	finished := poll_until(
		atomic_flag_raised,
		&blocked_sender_probe.finished,
		BLOCKED_SENDER_BUDGET,
	)
	expect(t, finished, "the sender finished its sends")
	expectf(
		t,
		samples >= BLOCKED_SENDER_MIN_SAMPLES,
		"the sender was blocked for only %d samples, wanted at least %d",
		samples,
		BLOCKED_SENDER_MIN_SAMPLES,
	)
	expectf(
		t,
		held_samples * 2 < samples,
		"the blocked sender's worker held one reclaim epoch for %d of %d samples, the global epoch ran up to %d ahead of it",
		held_samples,
		samples,
		max_lag,
	)
	expectf(
		t,
		sync.atomic_load(&blocked_sender_probe.failed) == 0,
		"%d of %d sends failed",
		sync.atomic_load(&blocked_sender_probe.failed),
		BLOCKED_SENDER_SENDS,
	)
}
