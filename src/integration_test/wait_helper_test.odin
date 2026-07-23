package integration

import "../actod"
import "core:testing"
import "core:time"

test_wait_helpers_honor_timeout :: proc(t: ^testing.T) {
	nonexistent := actod_pid_never_valid()

	started := time.tick_now()
	result := wait_for_child_count(nonexistent, 1, 300)
	elapsed := time.tick_since(started)

	expect(t, !result, "waiting on a nonexistent parent must time out")
	expectf(
		t,
		elapsed >= 250 * time.Millisecond,
		"a 300ms wait must run for at least 250ms before giving up, returned after %v",
		elapsed,
	)
	expectf(
		t,
		elapsed < 2000 * time.Millisecond,
		"a 300ms wait must not spin far past its deadline, returned after %v",
		elapsed,
	)
}

actod_pid_never_valid :: proc() -> actod.PID {
	return actod.PID(0xFFFF_FFFF_FFFF_0000)
}
