package integration

import "../actod"
import "base:intrinsics"
import "core:testing"

SPAWNER_FRAME_POISON :: 0xA5
SPAWNER_FRAME_BYTES :: 32 * 1024
STARTED_FLAG_ACTOR_NAME :: "started-flag-actor"

Started_Flag_Actor :: struct {
	initialised: bool,
}

started_flag_actor_init :: proc(data: ^Started_Flag_Actor) {
	data.initialised = true
}

started_flag_actor_handle :: proc(data: ^Started_Flag_Actor, from: actod.PID, msg: any) {
	if text, ok := msg.(string); ok && text == "panic" do panic("panic after the spawner returned")
}

Started_Flag_Actor_Behaviour :: actod.Actor_Behaviour(Started_Flag_Actor) {
	init           = started_flag_actor_init,
	handle_message = started_flag_actor_handle,
}

spawn_started_flag_actor :: #force_no_inline proc() -> (actod.PID, bool) {
	return actod.spawn(
		STARTED_FLAG_ACTOR_NAME,
		Started_Flag_Actor{},
		Started_Flag_Actor_Behaviour,
		actod.make_actor_config(logging = actod.make_log_config(level = test_log_level())),
	)
}

panic_actor_over_poisoned_frame :: #force_no_inline proc(
	pid: actod.PID,
) -> (
	changed_offset: int,
	gone: bool,
) {
	frame: [SPAWNER_FRAME_BYTES]u8
	for i in 0 ..< SPAWNER_FRAME_BYTES do intrinsics.volatile_store(&frame[i], SPAWNER_FRAME_POISON)

	if actod.send_message(pid, "panic") != .OK do return -1, false
	gone = wait_for_actor_invalid(pid, 2000)

	for i in 0 ..< SPAWNER_FRAME_BYTES {
		if intrinsics.volatile_load(&frame[i]) != SPAWNER_FRAME_POISON do return i, gone
	}
	return -1, gone
}

test_spawner_started_flag_not_written_after_return :: proc(t: ^testing.T) {
	pid, spawned := spawn_started_flag_actor()
	expect(t, spawned, "the actor with init must spawn")
	if !spawned do return

	changed_offset, gone := panic_actor_over_poisoned_frame(pid)
	expect(t, gone, "the panicking actor must leave the registry")
	expectf(
		t,
		changed_offset < 0,
		"a panic after spawn returned wrote into the stack the spawner had left, at byte %d of the poisoned frame",
		changed_offset,
	)
}
