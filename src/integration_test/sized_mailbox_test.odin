package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

Sized_Mailbox_Data :: struct {
	received: ^[dynamic]int,
	done:     ^bool,
}

Sized_Mailbox_Behaviour :: actod.Actor_Behaviour(Sized_Mailbox_Data) {
	handle_message = sized_mailbox_handle_message,
}

sized_mailbox_handle_message :: proc(data: ^Sized_Mailbox_Data, from: actod.PID, msg: any) {
	switch v in msg {
	case int:
		if v == -1 {
			sync.atomic_store(data.done, true)
			return
		}
		append(data.received, v)
	}
}

test_spawn_sized_mailbox :: proc(t: ^testing.T) {
	reset_test_state()

	received := make([dynamic]int)
	defer delete(received)
	done := false

	tiny_pid, tiny_spawned := actod.spawn(
		"tiny-mailbox-actor",
		Sized_Mailbox_Data{received = &received, done = &done},
		Sized_Mailbox_Behaviour,
		64,
	)
	expect(t, tiny_spawned, "Failed to spawn actor with a 64-slot mailbox")
	if !tiny_spawned {
		return
	}

	flood := 10_000
	dropped := 0
	for i in 0 ..< flood {
		if actod.send_message(tiny_pid, i) != .OK {
			dropped += 1
		}
	}
	expect(t, dropped == 0, "backpressure must block, not drop, while the receiver drains")

	expect(t, actod.send_message(tiny_pid, -1) == .OK, "Failed to send the drain sentinel")
	start := time.now()
	for !sync.atomic_load(&done) && time.diff(start, time.now()) < 5 * time.Second {
		time.sleep(10 * time.Millisecond)
	}
	expect(t, sync.atomic_load(&done), "actor never drained the flood")
	expect(t, len(received) == flood - dropped, "every accepted message must be delivered")

	inversions := 0
	for i in 1 ..< len(received) {
		if received[i] <= received[i - 1] {
			inversions += 1
		}
	}
	expect(t, inversions == 0, "messages through a sized mailbox must stay in send order")

	big_received := make([dynamic]int)
	defer delete(big_received)
	big_done := false

	big_pid, big_spawned := actod.spawn_sized(
		"big-mailbox-actor",
		Sized_Mailbox_Data{received = &big_received, done = &big_done},
		Sized_Mailbox_Behaviour,
		4096,
	)
	expect(t, big_spawned, "Failed to spawn actor with a 4096-slot mailbox")
	if !big_spawned {
		return
	}

	burst := 4000
	burst_dropped := 0
	for i in 0 ..< burst {
		if actod.send_message(big_pid, i) != .OK {
			burst_dropped += 1
		}
	}
	expect(t, burst_dropped == 0, "a burst below capacity must be accepted without errors")

	expect(t, actod.send_message(big_pid, -1) == .OK, "Failed to send the drain sentinel")
	start = time.now()
	for !sync.atomic_load(&big_done) && time.diff(start, time.now()) < 5 * time.Second {
		time.sleep(10 * time.Millisecond)
	}
	expect(t, sync.atomic_load(&big_done), "actor never drained the burst")
	expect(t, len(big_received) == burst, "every burst message must be delivered")

	_ = actod.send_message(tiny_pid, actod.Terminate{reason = .NORMAL})
	_ = actod.send_message(big_pid, actod.Terminate{reason = .NORMAL})
}
