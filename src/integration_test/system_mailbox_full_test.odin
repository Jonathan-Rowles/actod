package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

System_Backlog_Data :: struct {
	id:       int,
	blocking: ^bool,
	pinged:   ^bool,
}

System_Backlog_Behaviour :: actod.Actor_Behaviour(System_Backlog_Data) {
	handle_message = system_backlog_handle_message,
}

system_backlog_handle_message :: proc(data: ^System_Backlog_Data, from: actod.PID, msg: any) {
	text, is_text := msg.(string)
	if !is_text do return
	switch text {
	case "block":
		sync.atomic_store(data.blocking, true)
		time.sleep(800 * time.Millisecond)
	case "ping":
		sync.atomic_store(data.pinged, true)
	}
}

test_system_mailbox_full_returns_error :: proc(t: ^testing.T) {
	reset_test_state()

	blocking := false
	pinged := false
	pid, spawned := actod.spawn(
		"system-backlog-actor",
		System_Backlog_Data{id = 1, blocking = &blocking, pinged = &pinged},
		System_Backlog_Behaviour,
	)
	expect(t, spawned, "Failed to spawn actor")
	if !spawned {
		return
	}

	expect(
		t,
		actod.send_message(pid, "block") == .OK,
		"Failed to send the blocking message",
	)
	expect(
		t,
		poll_until(atomic_flag_raised, &blocking, 2 * time.Second),
		"actor never entered the blocking handler",
	)

	backlogged := 0
	for _ in 0 ..< actod.SYSTEM_MAILBOX_SIZE * 3 {
		if actod.send_message(pid, actod.Get_Stats{requester = 0}) == .RECEIVER_BACKLOGGED {
			backlogged += 1
		}
	}

	expect(
		t,
		backlogged > 0,
		"Overflowing a system mailbox must return RECEIVER_BACKLOGGED, not panic in the sender",
	)

	expect(t, actod.send_message(pid, "ping") == .OK, "Failed to send the ping")
	expect(
		t,
		poll_until(atomic_flag_raised, &pinged, 3 * time.Second),
		"actor never handled a message after draining its system backlog",
	)

	_, alive := actod.get_actor_pid("system-backlog-actor")
	expect(t, alive, "Actor must survive a system mailbox overflow")

	_ = actod.send_message(pid, actod.Terminate{reason = .NORMAL})
}
