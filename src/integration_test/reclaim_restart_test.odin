package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

RESTART_WARMUP_ACTORS :: 8

restart_warmup_handled: int

Restart_Warmup :: struct {}

restart_warmup_behaviour := actod.Actor_Behaviour(Restart_Warmup) {
	handle_message = proc(d: ^Restart_Warmup, from: actod.PID, msg: any) {
		sync.atomic_add(&restart_warmup_handled, 1)
	},
}

every_warmup_actor_handled :: proc(_: rawptr) -> bool {
	return sync.atomic_load(&restart_warmup_handled) >= RESTART_WARMUP_ACTORS
}

retire_list_empty :: proc(_: rawptr) -> bool {
	return retired_actor_count() == 0
}

claim_main_reclaim_slot_after_every_worker :: proc(t: ^testing.T) {
	sync.atomic_store(&restart_warmup_handled, 0)
	for i in 0 ..< RESTART_WARMUP_ACTORS {
		pid, ok := actod.spawn(
			"restart_warmup",
			Restart_Warmup{},
			restart_warmup_behaviour,
			actod.make_actor_config(home_worker = i % DEFAULT_TEST_WORKERS),
		)
		if !expect(t, ok, "spawn restart_warmup") do return
		expect_value(t, actod.send_message(pid, Integration_Test_Message{}), actod.Send_Error.OK)
	}
	expect(
		t,
		poll_until(every_warmup_actor_handled, nil, 2 * time.Second),
		"every warmup actor handled its message, so every worker holds a reclaim slot",
	)
	actod.reclaim_pin()
	actod.reclaim_unpin()
}

restart_node_with_one_worker :: proc() {
	actod.shutdown_node()
	opts := actod.make_node_config(
		worker_count = 1,
		actor_config = actod.make_actor_config(
			logging = actod.make_log_config(level = test_log_level()),
		),
	)
	actod.node_init("reclaim_restart_b", opts)
	wait_for_node()
}

test_reclaim_pin_survives_node_restart :: proc(t: ^testing.T) {
	claim_main_reclaim_slot_after_every_worker(t)
	restart_node_with_one_worker()

	pid, ok := actod.spawn("restart_target", Shutdown_Probe{}, shutdown_probe_behaviour)
	if !expect(t, ok, "spawn restart_target on the restarted node") do return

	actod.reclaim_pin()
	expect(
		t,
		actod.reclaim_pin_visible_to_scanner(),
		"the main thread pin is visible to the scanner after a node restart",
	)
	actor_ptr, _ := actod.get(&actod.NODE.actor_registry, pid)
	if !expect(t, actor_ptr != nil, "the pinned main thread read the target pointer") {
		actod.reclaim_unpin()
		return
	}

	expect(t, actod.terminate_actor(pid, .SHUTDOWN), "terminate restart_target")
	expect(
		t,
		poll_until(retire_list_nonempty, nil, 2 * time.Second),
		"the terminated target was retired behind the main thread pin",
	)
	_ = actod.send_message(pid, Integration_Test_Message{})

	for _ in 0 ..< 10 {
		actod.reclaim_scan()
		time.sleep(10 * time.Millisecond)
	}
	target_still_retired := expectf(
		t,
		retired_actor_count() > 0,
		"the scanner freed the target under the main thread pin (%d retired entries left)",
		retired_actor_count(),
	)
	expect(
		t,
		actod.reclaim_pin_visible_to_scanner(),
		"the main thread pin is still visible after the reap",
	)
	if target_still_retired do expect_value(t, (cast(^actod.Actor)actor_ptr).pid, pid)

	actod.reclaim_unpin()
	actod.reclaim_scan()
	expect(
		t,
		poll_until(retire_list_empty, nil, 2 * time.Second),
		"the target was freed once the main thread released its pin",
	)
}
