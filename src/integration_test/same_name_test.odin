package integration

import actod "../actod"
import "core:sync"
import "core:testing"
import "core:time"
import "same_name/left"
import "same_name/right"

LEFT_REFRESH_LABEL :: "left refresh, long enough to leave the inline slot and travel in a pool page"
RIGHT_REFRESH_LABEL :: "right refresh, long enough to leave the inline slot and travel in a pool page"

Same_Name_Counts :: struct {
	left_ok:   u64,
	right_ok:  u64,
	corrupted: u64,
}

same_name_counts: Same_Name_Counts

Same_Name_Receiver :: struct {}

same_name_receiver_handle :: proc(data: ^Same_Name_Receiver, from: actod.PID, msg: any) {
	switch m in msg {
	case left.Refresh:
		if m.label == LEFT_REFRESH_LABEL do sync.atomic_add(&same_name_counts.left_ok, 1)
		else do sync.atomic_add(&same_name_counts.corrupted, 1)
	case right.Refresh:
		if m.seq == 7 && m.label == RIGHT_REFRESH_LABEL do sync.atomic_add(&same_name_counts.right_ok, 1)
		else do sync.atomic_add(&same_name_counts.corrupted, 1)
	}
}

same_name_receiver_behaviour := actod.Actor_Behaviour(Same_Name_Receiver) {
	handle_message = same_name_receiver_handle,
}

@(init)
register_same_name_messages :: proc "contextless" () {
	actod.register_message_type(left.Refresh)
	actod.register_message_type(right.Refresh)
}

test_same_type_name_in_two_packages :: proc(t: ^testing.T) {
	reset_test_state()
	same_name_counts = {}

	left_info, left_found := actod.get_type_info_ptr(left.Refresh)
	right_info, right_found := actod.get_type_info_ptr(right.Refresh)
	expect(t, left_found, "left.Refresh is registered")
	expect(t, right_found, "right.Refresh is registered")
	if !left_found || !right_found do return

	expect(t, left_info != right_info, "the two Refresh types get two registry entries")
	expectf(t, left_info.name == "left.Refresh", "left name is %s", left_info.name)
	expectf(t, right_info.name == "right.Refresh", "right name is %s", right_info.name)
	expect(t, left_info.type_hash != right_info.type_hash, "the wire hashes differ")

	by_left_hash, _ := actod.get_type_info_by_hash(left_info.type_hash)
	by_right_hash, _ := actod.get_type_info_by_hash(right_info.type_hash)
	expect(t, by_left_hash == left_info, "the left hash finds the left entry")
	expect(t, by_right_hash == right_info, "the right hash finds the right entry")

	pid, ok := actod.spawn("same-name-receiver", Same_Name_Receiver{}, same_name_receiver_behaviour)
	expect(t, ok, "spawn receiver")
	if !ok do return

	expect(t, actod.send_message(pid, left.Refresh{label = LEFT_REFRESH_LABEL}) == .OK, "send left")
	expect(t, actod.send_message(pid, right.Refresh{seq = 7, label = RIGHT_REFRESH_LABEL}) == .OK, "send right")

	delivered := poll_until(proc(state: rawptr) -> bool {
		counts := cast(^Same_Name_Counts)state
		return sync.atomic_load(&counts.left_ok) + sync.atomic_load(&counts.right_ok) + sync.atomic_load(&counts.corrupted) >= 2
	}, &same_name_counts, INTEGRATION_TEST_TIMEOUT, time.Millisecond)
	expect(t, delivered, "both messages are handled")
	expect(t, sync.atomic_load(&same_name_counts.left_ok) == 1, "left.Refresh arrives intact at its own case")
	expect(t, sync.atomic_load(&same_name_counts.right_ok) == 1, "right.Refresh arrives intact at its own case")
	expect(t, sync.atomic_load(&same_name_counts.corrupted) == 0, "no Refresh arrives with the other's layout")

	_ = actod.terminate_actor(pid)
}
