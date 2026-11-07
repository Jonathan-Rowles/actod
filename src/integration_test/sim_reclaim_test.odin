package integration

import "../actod"
import "core:sync"
import "core:testing"

SIM_FLOOD_COUNT :: 64

@(private = "file")
g_flood_received: int

@(private = "file")
g_flood_started: bool

@(private = "file")
g_flood_finished: bool

@(private = "file")
g_flood_slots_held_after_sends: int

Sim_Flood_Sink_Data :: struct {}

Sim_Flood_Sink_Behaviour :: actod.Actor_Behaviour(Sim_Flood_Sink_Data) {
	handle_message = proc(data: ^Sim_Flood_Sink_Data, from: actod.PID, msg: any) {
		if _, ok := msg.(Integration_Test_Message); ok do g_flood_received += 1
	},
}

Sim_Flooder_Data :: struct {
	sink: actod.PID,
}

Sim_Flooder_Behaviour :: actod.Actor_Behaviour(Sim_Flooder_Data) {
	handle_message = proc(data: ^Sim_Flooder_Data, from: actod.PID, msg: any) {
		if _, ok := msg.(Integration_Test_Message); !ok do return
		g_flood_started = true
		for i in 0 ..< SIM_FLOOD_COUNT {
			_ = actod.send_message(data.sink, Integration_Test_Message{id = i, payload = "flood"})
		}
		g_flood_slots_held_after_sends = reclaim_slots_held()
		g_flood_finished = true
	},
}

@(private = "file")
reclaim_slots_held :: proc() -> int {
	held := sync.atomic_load(&actod.NODE.reclaim.overflow_active)
	slots := min(sync.atomic_load(&actod.NODE.reclaim.slot_count), actod.MAX_RECLAIM_SLOTS)
	for i in 0 ..< slots {
		if sync.atomic_load(&actod.NODE.reclaim.slots[i].active_epoch) != 0 do held += 1
	}
	return held
}

test_sim_sender_parked_on_another_workers_full_mailbox_holds_no_reclaim_pin :: proc(
	t: ^testing.T,
) {
	g_flood_received = 0
	g_flood_started = false
	g_flood_finished = false
	g_flood_slots_held_after_sends = 0

	sink, sink_ok := actod.spawn(
		"sim_flood_sink",
		Sim_Flood_Sink_Data{},
		Sim_Flood_Sink_Behaviour,
		actod.make_actor_config(home_worker = 1),
	)
	expect(t, sink_ok, "sink spawn failed")
	flooder, flooder_ok := actod.spawn(
		"sim_flooder",
		Sim_Flooder_Data{sink = sink},
		Sim_Flooder_Behaviour,
		actod.make_actor_config(home_worker = 0),
	)
	expect(t, flooder_ok, "flooder spawn failed")
	expect(
		t,
		actod.send_message(flooder, Integration_Test_Message{id = 0, payload = "go"}) == .OK,
		"send failed",
	)

	steps_parked := 0
	steps_parked_holding_a_slot := 0
	for actod.sim_pump() {
		if !g_flood_started || g_flood_finished do continue
		steps_parked += 1
		if reclaim_slots_held() > 0 do steps_parked_holding_a_slot += 1
	}

	expect(t, steps_parked > 0, "the flooder never parked on the sink's full mailbox")
	expect_value(t, steps_parked_holding_a_slot, 0)
	expect_value(t, g_flood_slots_held_after_sends, 1)
	expect_value(t, g_flood_received, SIM_FLOOD_COUNT)
}


test_sim_pin_held_across_bind_protects_other_node :: proc(t: ^testing.T) {
	node_a := actod.NODE

	node_b := actod.sim_create_node()
	_ = actod.sim_bind_node(node_b)
	opts := actod.make_node_config(
		worker_count = 2,
		sim_mode = true,
		actor_config = actod.make_actor_config(
			logging = actod.make_log_config(level = test_log_level()),
		),
	)
	actod.node_init("sim_reclaim_b", opts)
	pid, ok := actod.spawn("sim_reclaim_target", Shutdown_Probe{}, shutdown_probe_behaviour)
	_ = actod.sim_run_until_idle()

	_ = actod.sim_bind_node(node_a)
	actod.reclaim_pin()
	expect(
		t,
		actod.reclaim_pin_visible_to_scanner(),
		"the main thread pin is visible to node A's scanner",
	)

	_ = actod.sim_bind_node(node_b)
	if !expect(t, ok, "spawn sim_reclaim_target on node B") {
		actod.reclaim_unpin()
		return
	}
	expect(
		t,
		actod.reclaim_pin_visible_to_scanner(),
		"the pin taken in node A is visible to node B's scanner",
	)
	actor_ptr, _ := actod.get(&actod.NODE.actor_registry, pid)
	expect(t, actor_ptr != nil, "the pinned main thread read the target pointer in node B")

	expect(t, actod.terminate_actor(pid, .SHUTDOWN), "terminate sim_reclaim_target")
	_ = actod.sim_run_until_idle()
	for _ in 0 ..< 10 {
		actod.reclaim_scan()
	}
	target_still_retired := expectf(
		t,
		retired_actor_count() > 0,
		"node B's scanner freed the target under the main thread pin (%d retired entries left)",
		retired_actor_count(),
	)
	if target_still_retired && actor_ptr != nil do expect_value(t, (cast(^actod.Actor)actor_ptr).pid, pid)

	actod.reclaim_unpin()
	actod.reclaim_scan()
	expect_value(t, retired_actor_count(), 0)

	actod.node_shutdown()
	_ = actod.sim_bind_node(node_a)
	actod.sim_destroy_node(node_b)

	pid_a, ok_a := actod.spawn("sim_reclaim_target_a", Shutdown_Probe{}, shutdown_probe_behaviour)
	if !expect(t, ok_a, "spawn sim_reclaim_target_a on node A") do return
	_ = actod.sim_run_until_idle()
	expect(t, actod.terminate_actor(pid_a, .SHUTDOWN), "terminate sim_reclaim_target_a")
	_ = actod.sim_run_until_idle()
	actod.reclaim_scan()
	expectf(
		t,
		retired_actor_count() == 0,
		"node A still holds the pin released in node B (%d retired entries left)",
		retired_actor_count(),
	)
}
