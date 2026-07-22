package integration

import "../actod"
import "core:testing"
import "core:time"

System_Backlog_Data :: struct {
	id: int,
}

System_Backlog_Behaviour :: actod.Actor_Behaviour(System_Backlog_Data) {
	handle_message = system_backlog_handle_message,
}

system_backlog_handle_message :: proc(data: ^System_Backlog_Data, from: actod.PID, msg: any) {
	if text, ok := msg.(string); ok && text == "block" {
		time.sleep(800 * time.Millisecond)
	}
}

test_system_mailbox_full_returns_error :: proc(t: ^testing.T) {
	reset_test_state()

	pid, spawned := actod.spawn(
		"system-backlog-actor",
		System_Backlog_Data{id = 1},
		System_Backlog_Behaviour,
	)
	testing.expect(t, spawned, "Failed to spawn actor")
	if !spawned {
		return
	}

	testing.expect(
		t,
		actod.send_message(pid, "block") == .OK,
		"Failed to send the blocking message",
	)
	time.sleep(100 * time.Millisecond)

	backlogged := 0
	for _ in 0 ..< actod.SYSTEM_MAILBOX_SIZE * 3 {
		if actod.send_message(pid, actod.Get_Stats{requester = 0}) == .RECEIVER_BACKLOGGED {
			backlogged += 1
		}
	}

	testing.expect(
		t,
		backlogged > 0,
		"Overflowing a system mailbox must return RECEIVER_BACKLOGGED, not panic in the sender",
	)

	time.sleep(1200 * time.Millisecond)

	_, alive := actod.get_actor_pid("system-backlog-actor")
	testing.expect(t, alive, "Actor must survive a system mailbox overflow")

	actod.send_message(pid, actod.Terminate{reason = .NORMAL})
}
