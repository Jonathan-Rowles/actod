package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

BLOCKING_REAP_CHILD_NAME :: "blocking-reap-child"
BLOCKING_REAP_SENTINEL_NAME :: "blocking-reap-sentinel"
BLOCKING_REAP_SENTINEL_BUDGET :: 2 * time.Second

Blocking_Last_Touch :: struct {
	actor:               ^actod.Actor,
	pid:                 actod.PID,
	sentinel:            actod.PID,
	reached:             bool,
	sentinel_spawned:    bool,
	sentinel_terminated: bool,
	sentinel_reaped:     bool,
	live:                bool,
}

blocking_last_touch: Blocking_Last_Touch

blocking_reap_child_init :: proc(data: ^Blocking_Test_Data) {
	_ = actod.self_terminate()
}

Blocking_Reap_Child_Behaviour :: actod.Actor_Behaviour(Blocking_Test_Data) {
	init           = blocking_reap_child_init,
	handle_message = blocking_test_handle,
}

Blocking_Reap_Sentinel_Behaviour :: actod.Actor_Behaviour(Blocking_Test_Data) {
	handle_message = blocking_test_handle,
}

spawn_blocking_reap_child :: proc(
	_name: string,
	_parent: actod.PID,
) -> (
	actod.PID,
	bool,
) {
	return actod.spawn(
		BLOCKING_REAP_CHILD_NAME,
		Blocking_Test_Data{},
		Blocking_Reap_Child_Behaviour,
	)
}

blocking_actor_still_registered :: proc(touch: ^Blocking_Last_Touch) -> bool {
	registered, active := actod.get(&actod.NODE.actor_registry, touch.pid)
	return active && registered == rawptr(touch.actor)
}

blocking_reap_sentinel_reaped :: proc(state: rawptr) -> bool {
	_, active := actod.get(
		&actod.NODE.actor_registry,
		(cast(^Blocking_Last_Touch)state).sentinel,
	)
	return !active
}

hold_blocking_actor_at_last_touch :: proc(
	actor: ^actod.Actor,
	pid: actod.PID,
) {
	touch := &blocking_last_touch
	touch.actor = actor
	touch.pid = pid
	touch.reached = true
	touch.sentinel, touch.sentinel_spawned = actod.spawn(
		BLOCKING_REAP_SENTINEL_NAME,
		Blocking_Test_Data{},
		Blocking_Reap_Sentinel_Behaviour,
	)
	if !touch.sentinel_spawned do return
	touch.sentinel_terminated = actod.terminate_actor(touch.sentinel)
	if !touch.sentinel_terminated do return
	touch.sentinel_reaped = poll_until(
		blocking_reap_sentinel_reaped,
		touch,
		BLOCKING_REAP_SENTINEL_BUDGET,
		time.Millisecond,
	)
	touch.live = blocking_actor_still_registered(touch)
}

test_blocking_child_is_live_at_its_last_touch :: proc(t: ^testing.T) {
	reset_test_state()
	blocking_last_touch = {}
	actod.blocking_actor_last_touch_hook = hold_blocking_actor_at_last_touch
	defer actod.blocking_actor_last_touch_hook = nil

	restart_node_with("blocking-reap", nil, 3, spawn_blocking_reap_child)

	expect(
		t,
		blocking_last_touch.reached,
		"the blocking child must return through its last touch",
	)
	expect(
		t,
		blocking_last_touch.sentinel_spawned,
		"the sentinel must spawn from the main thread",
	)
	expect(
		t,
		blocking_last_touch.sentinel_terminated,
		"the sentinel must accept its termination",
	)
	expect(
		t,
		blocking_last_touch.sentinel_reaped,
		"the node must reap the sentinel within its budget",
	)
	expectf(
		t,
		blocking_last_touch.live,
		"the node reaped the blocking child %v while its loop had not yet returned",
		blocking_last_touch.pid,
	)
	expect(
		t,
		!sync.atomic_load(&actod.NODE.shutting_down),
		"a self-terminating blocking child must not shut the node down",
	)

	actod.shutdown_node()
	expect_value(t, actod.NODE.shutdown_leaked_actors, 0)
}
