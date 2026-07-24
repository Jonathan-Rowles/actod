package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

Mailbox_Order_Data :: struct {
	received: ^[dynamic]int,
	done:     ^bool,
}

Mailbox_Order_Behaviour :: actod.Actor_Behaviour(Mailbox_Order_Data) {
	handle_message = mailbox_order_handle_message,
}

mailbox_order_handle_message :: proc(data: ^Mailbox_Order_Data, from: actod.PID, msg: any) {
	switch v in msg {
	case string:
		if v == "block" {
			time.sleep(300 * time.Millisecond)
		}
	case int:
		if v == -1 {
			sync.atomic_store(data.done, true)
			return
		}
		append(data.received, v)
	}
}

test_mailbox_overflow_preserves_send_order :: proc(t: ^testing.T) {
	reset_test_state()

	received := make([dynamic]int)
	defer delete(received)
	done := false

	pid, spawned := actod.spawn(
		"mailbox-order-actor",
		Mailbox_Order_Data{received = &received, done = &done},
		Mailbox_Order_Behaviour,
	)
	expect(t, spawned, "Failed to spawn actor")
	if !spawned {
		return
	}

	expect(t, actod.send_message(pid, "block") == .OK, "Failed to send the blocking message")
	time.sleep(50 * time.Millisecond)

	sent := 0
	for i in 0 ..< actod.DEFAULT_MAIL_BOX_SIZE * 2 {
		if actod.send_message(pid, i) == .OK {
			sent += 1
		}
	}
	expect(t, sent >= actod.DEFAULT_MAIL_BOX_SIZE, "the mailbox should accept a full load")

	time.sleep(500 * time.Millisecond)

	expect(t, actod.send_message(pid, -1) == .OK, "Failed to send the drain sentinel")
	start := time.now()
	for !sync.atomic_load(&done) && time.diff(start, time.now()) < 2 * time.Second {
		time.sleep(10 * time.Millisecond)
	}
	expect(t, sync.atomic_load(&done), "actor never drained the flood")

	inversions := 0
	for i in 1 ..< len(received) {
		if received[i] <= received[i - 1] {
			inversions += 1
		}
	}
	expect(t, inversions == 0, "an overflowed send must never overtake earlier sends from the same producer")

	actod.send_message(pid, actod.Terminate{reason = .NORMAL})
}
