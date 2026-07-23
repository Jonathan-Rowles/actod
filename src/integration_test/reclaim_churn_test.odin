package integration

import "../actod"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

RECLAIM_NUM_SLOTS :: 64
RECLAIM_EXTERNAL_SENDERS :: 4
RECLAIM_SENDER_ACTORS :: 4
RECLAIM_TARGET_WORKER :: 0
RECLAIM_RUN :: 1500 * time.Millisecond

Reclaim_Ping :: struct {
	n: u64,
}

Reclaim_Tick :: struct {}

Reclaim_Target :: struct {
	received: u64,
}

Reclaim_Sender :: struct {
	sent: u64,
}

reclaim_slots: [RECLAIM_NUM_SLOTS]u64
reclaim_stop: bool
reclaim_total_sent: u64
reclaim_total_terminations: u64

reclaim_target_behaviour := actod.Actor_Behaviour(Reclaim_Target) {
	handle_message = proc(d: ^Reclaim_Target, from: actod.PID, msg: any) {
		if _, ok := msg.(Reclaim_Ping); ok {
			d.received += 1
		}
	},
}

reclaim_sender_behaviour := actod.Actor_Behaviour(Reclaim_Sender) {
	handle_message = proc(d: ^Reclaim_Sender, from: actod.PID, msg: any) {
		if _, ok := msg.(Reclaim_Tick); ok {
			if sync.atomic_load_explicit(&reclaim_stop, .Acquire) {
				return
			}
			for slot in 0 ..< RECLAIM_NUM_SLOTS {
				pid := actod.PID(sync.atomic_load_explicit(&reclaim_slots[slot], .Acquire))
				if pid != 0 {
					actod.send_message(pid, Reclaim_Ping{n = d.sent})
					d.sent += 1
				}
			}
			sync.atomic_add(&reclaim_total_sent, RECLAIM_NUM_SLOTS)
			actod.send_self(Reclaim_Tick{})
		}
	},
}

reclaim_target_config :: proc() -> actod.Actor_Config {
	return actod.make_actor_config(
		home_worker = RECLAIM_TARGET_WORKER,
		logging = actod.make_log_config(level = .Fatal),
	)
}

reclaim_spawn_target :: proc(slot: int, seq: ^u64) {
	name := fmt.tprintf("reclaim_target_%d_%d", slot, seq^)
	seq^ += 1
	pid, ok := actod.spawn(name, Reclaim_Target{}, reclaim_target_behaviour, reclaim_target_config())
	if ok {
		sync.atomic_store_explicit(&reclaim_slots[slot], u64(pid), .Release)
	} else {
		sync.atomic_store_explicit(&reclaim_slots[slot], 0, .Release)
	}
}

reclaim_external_sender_proc :: proc(_: rawptr) {
	sent: u64
	for !sync.atomic_load_explicit(&reclaim_stop, .Acquire) {
		for slot in 0 ..< RECLAIM_NUM_SLOTS {
			pid := actod.PID(sync.atomic_load_explicit(&reclaim_slots[slot], .Acquire))
			if pid == 0 {
				continue
			}
			for _ in 0 ..< 4 {
				actod.send_message(pid, Reclaim_Ping{n = sent})
				sent += 1
			}
		}
	}
	sync.atomic_add(&reclaim_total_sent, sent)
}

reclaim_reaper_proc :: proc(_: rawptr) {
	seq: u64
	terminations: u64
	for !sync.atomic_load_explicit(&reclaim_stop, .Acquire) {
		for slot in 0 ..< RECLAIM_NUM_SLOTS {
			pid := actod.PID(sync.atomic_load_explicit(&reclaim_slots[slot], .Acquire))
			if pid == 0 {
				reclaim_spawn_target(slot, &seq)
				continue
			}
			actod.terminate_actor(pid, .SHUTDOWN)
			terminations += 1
			reclaim_spawn_target(slot, &seq)
		}
	}
	sync.atomic_store_explicit(&reclaim_total_terminations, terminations, .Release)
}

test_reclaim_churn_under_termination :: proc(t: ^testing.T) {
	sync.atomic_store(&reclaim_stop, false)
	sync.atomic_store(&reclaim_total_sent, 0)
	sync.atomic_store(&reclaim_total_terminations, 0)
	for slot in 0 ..< RECLAIM_NUM_SLOTS {
		sync.atomic_store(&reclaim_slots[slot], 0)
	}

	seq: u64
	for slot in 0 ..< RECLAIM_NUM_SLOTS {
		reclaim_spawn_target(slot, &seq)
	}

	for i in 0 ..< RECLAIM_SENDER_ACTORS {
		pid, ok := actod.spawn(
			fmt.tprintf("reclaim_sender_%d", i),
			Reclaim_Sender{},
			reclaim_sender_behaviour,
			actod.make_actor_config(
				home_worker = RECLAIM_TARGET_WORKER,
				logging = actod.make_log_config(level = .Fatal),
			),
		)
		if ok {
			actod.send_message(pid, Reclaim_Tick{})
		}
	}

	externals: [RECLAIM_EXTERNAL_SENDERS]^thread.Thread
	for i in 0 ..< RECLAIM_EXTERNAL_SENDERS {
		externals[i] = thread.create_and_start_with_data(nil, reclaim_external_sender_proc)
	}
	reaper := thread.create_and_start_with_data(nil, reclaim_reaper_proc)

	time.sleep(RECLAIM_RUN)
	sync.atomic_store(&reclaim_stop, true)

	thread.join(reaper)
	thread.destroy(reaper)
	for i in 0 ..< RECLAIM_EXTERNAL_SENDERS {
		thread.join(externals[i])
		thread.destroy(externals[i])
	}

	expect(
		t,
		sync.atomic_load(&reclaim_total_sent) > 0,
		"churn should have sent messages",
	)
	expect(
		t,
		sync.atomic_load(&reclaim_total_terminations) > 0,
		"churn should have terminated actors",
	)
}
