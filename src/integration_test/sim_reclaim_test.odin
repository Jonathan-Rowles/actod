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

test_sim_sender_parked_on_another_workers_full_mailbox_holds_no_reclaim_pin :: proc(t: ^testing.T) {
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
	expect(t, actod.send_message(flooder, Integration_Test_Message{id = 0, payload = "go"}) == .OK, "send failed")

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
