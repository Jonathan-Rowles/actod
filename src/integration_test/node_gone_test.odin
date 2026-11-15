package integration

import "../actod"
import "base:runtime"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
g_gone_type: actod.Actor_Type

@(private = "file")
g_gone_broadcasts_seen: int

@(private = "file")
g_gone_sends_seen: int

@(private = "file")
g_gone_left_for_a_replacement: int

@(private = "file")
g_gone_hook_peer: actod.Node_ID

@(private = "file")
g_gone_take_over_while_closing: actod.PID

@(private = "file")
g_gone_mark_gone_while_taking_over: bool

@(private = "file")
watch_gone_log :: proc(
	level: log.Level,
	text: string,
	location: runtime.Source_Code_Location,
) {
	if strings.contains(text, "leaving buffered slots for the replacement") {
		sync.atomic_add(&g_gone_left_for_a_replacement, 1)
	}
	if g_gone_take_over_while_closing != 0 &&
	   strings.contains(text, "on disconnect") {
		sync.atomic_store(
			cast(^u64)&actod.NODE.connection_actors[g_gone_hook_peer],
			u64(g_gone_take_over_while_closing),
		)
		g_gone_take_over_while_closing = 0
	}
	if g_gone_mark_gone_while_taking_over &&
	   strings.contains(text, "Replacing outgoing with incoming") {
		actod.NODE.node_registry[g_gone_hook_peer].gone = true
		g_gone_mark_gone_while_taking_over = false
	}
}

Gone_Publisher_Data :: struct {}

@(private = "file")
g_gone_publisher_behaviour: actod.Actor_Behaviour(Gone_Publisher_Data)

Gone_Subscriber_Data :: struct {}

Gone_Subscriber_Behaviour :: actod.Actor_Behaviour(Gone_Subscriber_Data) {
	init = proc(data: ^Gone_Subscriber_Data) {
		_, _ = actod.subscribe_type(g_gone_type)
	},
	handle_message = proc(
		data: ^Gone_Subscriber_Data,
		from: actod.PID,
		msg: any,
	) {
		if m, ok := msg.(Integration_Test_Message); ok {
			if m.payload == "broadcast" do g_gone_broadcasts_seen += 1
			if m.payload == "send" do g_gone_sends_seen += 1
		}
	},
}

@(private = "file")
Gone_Mesh :: struct {
	mesh:      ^actod.Sim_Mesh,
	publisher: actod.PID,
	peer:      actod.Node_ID,
}

@(private = "file")
gone_mesh_create :: proc(
	t: ^testing.T,
	base_port: int,
	watch_log := false,
	higher_port_dials := false,
	nodes := 2,
) -> (
	Gone_Mesh,
	bool,
) {
	g_gone_broadcasts_seen = 0
	g_gone_sends_seen = 0
	sync.atomic_store(&g_gone_left_for_a_replacement, 0)
	g_gone_take_over_while_closing = 0
	g_gone_mark_gone_while_taking_over = false
	g_gone_type, _ = actod.register_actor_type("gone_publisher")
	g_gone_publisher_behaviour = actod.Actor_Behaviour(Gone_Publisher_Data) {
		actor_type = g_gone_type,
		handle_message = proc(
			data: ^Gone_Publisher_Data,
			from: actod.PID,
			msg: any,
		) {
			if m, ok := msg.(Integration_Test_Message); ok {
				actod.broadcast(
					Integration_Test_Message{id = m.id, payload = "broadcast"},
				)
			}
		},
	}

	g: Gone_Mesh
	g.mesh = actod.sim_mesh_create(
		nodes,
		base_port = base_port,
		log_level = test_log_level(),
	)

	_ = actod.sim_mesh_bind(g.mesh, 1)
	_, subscribed := actod.spawn(
		"gone_subscriber",
		Gone_Subscriber_Data{},
		Gone_Subscriber_Behaviour,
	)
	expect(t, subscribed, "subscriber spawn failed")

	_ = actod.sim_mesh_bind(g.mesh, 0)
	publisher, published := actod.spawn(
		"gone_publisher",
		Gone_Publisher_Data{},
		g_gone_publisher_behaviour,
	)
	expect(t, published, "publisher spawn failed")
	g.publisher = publisher
	if watch_log {
		actod.NODE.config.actor_config.logging.level = .Info
		actod.NODE.config.actor_config.logging.custom_logger = watch_gone_log
	}

	if higher_port_dials {
		_ = actod.sim_mesh_bind(g.mesh, 1)
		lower, known_lower := actod.get_node_by_name(
			actod.sim_mesh_name(g.mesh, 0),
		)
		expect(t, known_lower, "node 1 does not know node 0")
		_ = actod.get_or_create_connection(lower)
		for _ in 0 ..< 4 {
			actod.sim_mesh_advance_clock(g.mesh, 3 * time.Second)
			_ = actod.sim_mesh_run_until_idle(g.mesh)
		}
	} else if !actod.sim_mesh_connect_full(g.mesh) {
		expect(t, false, "mesh connect did not settle")
		return g, false
	}

	_ = actod.sim_mesh_bind(g.mesh, 0)
	peer, known := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, known, "node 0 does not know node 1")
	g.peer = peer
	expect(
		t,
		gone_remote_subscribers(g) > 0,
		"node 0 never learned node 1's subscription",
	)
	return g, known
}

@(private = "file")
gone_remote_subscribers :: proc(g: Gone_Mesh) -> u32 {
	_ = actod.sim_mesh_bind(g.mesh, 0)
	return sync.atomic_load(
		&actod.NODE.type_subscribers[g_gone_type].remote_node_sub_count[g.peer],
	)
}

@(private = "file")
gone_staged_slots :: proc(g: Gone_Mesh) -> int {
	return gone_staged_slots_for(g, g.peer)
}

@(private = "file")
gone_staged_slots_for :: proc(g: Gone_Mesh, node: actod.Node_ID) -> int {
	_ = actod.sim_mesh_bind(g.mesh, 0)
	ring := actod.get_connection_ring(node)
	if ring == nil do return 0
	staged := 0
	for &slot in ring.send_slots[:ring.send_slot_count] {
		if sync.atomic_load(&slot.state) != .FREE do staged += 1
	}
	return staged
}

@(private = "file")
gone_broadcast :: proc(g: Gone_Mesh) {
	_ = actod.sim_mesh_bind(g.mesh, 0)
	_ = actod.send_message(g.publisher, Integration_Test_Message{id = 1})
	_ = actod.sim_mesh_run_until_idle(g.mesh)
}

@(private = "file")
expect_node_closed :: proc(t: ^testing.T, g: Gone_Mesh) {
	expect_value(t, gone_remote_subscribers(g), 0)
	gone_broadcast(g)
	expect_value(t, gone_staged_slots(g), 0)
	expect_value(t, g_gone_broadcasts_seen, 0)
}

test_sim_unregister_node_clears_its_subscriptions_and_ring :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38000)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	actod.sim_mesh_crash(g.mesh, 1)

	expect_node_closed(t, g)
}

@(private = "file")
gone_connection :: proc(g: Gone_Mesh) -> actod.PID {
	_ = actod.sim_mesh_bind(g.mesh, 0)
	return actod.PID(
		sync.atomic_load(cast(^u64)&actod.NODE.connection_actors[g.peer]),
	)
}

@(private = "file")
gone_stop_connection :: proc(t: ^testing.T, g: Gone_Mesh) {
	connection := gone_connection(g)
	expect(t, actod.terminate_actor(connection), "connection did not stop")
	_ = actod.sim_mesh_run_until_idle(g.mesh)
}

@(private = "file")
gone_stage_into_a_stopped_connection :: proc(t: ^testing.T, g: Gone_Mesh) {
	gone_stop_connection(t, g)
	actod.sim_mesh_crash(g.mesh, 1)
	gone_broadcast(g)
	expect(
		t,
		gone_staged_slots(g) > 0,
		"a broadcast to the stopped connection staged nothing",
	)
}

test_sim_unregister_node_while_it_redials_clears_the_ring_left_for_a_replacement :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38100)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	gone_stage_into_a_stopped_connection(t, g)
	expect(t, gone_connection(g) != 0, "nothing redials the stopped node")

	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	expect_value(t, gone_staged_slots(g), 0)
	expect_value(t, gone_connection(g), 0)
	expect_node_closed(t, g)
}

test_sim_unregister_node_with_no_connection_clears_the_ring_left_for_a_replacement :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38500)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	gone_stage_into_a_stopped_connection(t, g)
	gone_stop_connection(t, g)
	expect_value(t, gone_connection(g), 0)
	expect(t, gone_staged_slots(g) > 0, "stopping the redial reset the ring")

	_ = actod.sim_mesh_bind(g.mesh, 0)
	mirror := actod.pack_pid(actod.Handle{idx = 7, gen = 1}, g.peer)
	_, _ = actod.add_remote(
		&actod.NODE.actor_registry,
		mirror,
		"gone_mirror@mesh1",
	)
	_, mirrored := actod.get_actor_pid("gone_mirror@mesh1")
	expect(t, mirrored, "the mirrored actor was not registered")

	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	_, still_mirrored := actod.get_actor_pid("gone_mirror@mesh1")
	expect(t, !still_mirrored, "a gone node's mirrored actor is still found")
	expect_value(t, gone_staged_slots(g), 0)
	expect_node_not_found(t, g)
	expect_node_closed(t, g)
}

test_sim_a_goodbye_clears_the_node_subscriptions_and_ring :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38200)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	_ = actod.sim_mesh_bind(g.mesh, 1)
	back, known := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 0))
	expect(t, known, "node 1 does not know node 0")
	actod.send_disconnect_to_ring(actod.get_connection_ring(back), "leaving")
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	expect_node_not_found(t, g)
	expect_node_closed(t, g)
}

test_sim_a_lost_link_keeps_what_was_staged_for_the_reconnect :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38400)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	actod.sim_mesh_partition(g.mesh, 0, 1)
	actod.sim_mesh_sever(g.mesh, 0, 1, deliver_error = true)
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	_ = actod.send_remote_by_name(
		actod.sim_mesh_name(g.mesh, 1),
		"gone_subscriber",
		Integration_Test_Message{id = 2, payload = "send"},
	)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect(
		t,
		gone_staged_slots(g) > 0,
		"a send while the link was down staged nothing",
	)
	expect_value(t, g_gone_sends_seen, 0)

	actod.sim_mesh_heal(g.mesh, 0, 1)
	actod.sim_mesh_advance_clock(g.mesh, 3 * time.Second)
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	expect_value(t, g_gone_sends_seen, 1)
	expect(
		t,
		gone_remote_subscribers(g) > 0,
		"the reconnect did not bring back node 1's subscription",
	)
	gone_broadcast(g)
	expect_value(t, g_gone_broadcasts_seen, 1)
}

@(private = "file")
expect_node_not_found :: proc(t: ^testing.T, g: Gone_Mesh) {
	_ = actod.sim_mesh_bind(g.mesh, 0)
	_, by_name := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, !by_name, "a gone node is still found by name")
	_, by_id := actod.get_node_info(g.peer)
	expect(t, !by_id, "a gone node is still found by id")
}

test_sim_an_unregistered_node_is_not_found_and_a_send_by_name_to_it_fails :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38600)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	actod.sim_mesh_crash(g.mesh, 1)

	expect_node_not_found(t, g)
	_ = actod.sim_mesh_bind(g.mesh, 0)
	sent := actod.send_remote_by_name(
		actod.sim_mesh_name(g.mesh, 1),
		"gone_subscriber",
		Integration_Test_Message{id = 2, payload = "send"},
	)
	expect(t, sent != .OK, "a send by name to a gone node was accepted")
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect_value(t, gone_staged_slots(g), 0)
}

test_sim_a_node_timed_out_is_not_redialled_once_the_partition_heals :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38700)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	actod.sim_mesh_partition(g.mesh, 0, 1)
	for _ in 0 ..< 4 {
		actod.sim_mesh_advance_clock(g.mesh, 30 * time.Second)
		_ = actod.sim_mesh_run_until_idle(g.mesh)
	}
	actod.sim_mesh_heal(g.mesh, 0, 1)
	for _ in 0 ..< 4 {
		actod.sim_mesh_advance_clock(g.mesh, 3 * time.Second)
		_ = actod.sim_mesh_run_until_idle(g.mesh)
	}

	expect_node_not_found(t, g)
	expect_node_closed(t, g)
}

test_sim_a_node_gone_by_goodbye_gets_its_old_id_when_it_connects_again :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38800)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	_ = actod.sim_mesh_bind(g.mesh, 1)
	back, known := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 0))
	expect(t, known, "node 1 does not know node 0")
	actod.send_disconnect_to_ring(actod.get_connection_ring(back), "leaving")
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect_node_not_found(t, g)

	_ = actod.sim_mesh_bind(g.mesh, 1)
	_, _ = actod.register_node(
		actod.sim_mesh_name(g.mesh, 0),
		{address = net.IP4_Loopback, port = g.mesh.ports[0]},
		.TCP_Custom_Protocol,
		connect = true,
	)
	for _ in 0 ..< 4 {
		actod.sim_mesh_advance_clock(g.mesh, 3 * time.Second)
		_ = actod.sim_mesh_run_until_idle(g.mesh)
	}

	_ = actod.sim_mesh_bind(g.mesh, 0)
	again, found := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, found, "node 1 is not found after it connected again")
	expect_value(t, again, g.peer)
	expect(
		t,
		gone_remote_subscribers(g) > 0,
		"node 1's subscription did not come back with it",
	)
	gone_broadcast(g)
	expect_value(t, g_gone_broadcasts_seen, 1)
}

test_sim_an_unregistered_node_registered_again_gets_its_old_id :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 38900)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect_node_not_found(t, g)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	again, registered := actod.register_node(
		actod.sim_mesh_name(g.mesh, 1),
		{address = net.IP4_Loopback, port = g.mesh.ports[1]},
		.TCP_Custom_Protocol,
		connect = true,
	)
	expect(t, registered, "registering a gone node again was refused")
	expect_value(t, again, g.peer)
	for _ in 0 ..< 4 {
		actod.sim_mesh_advance_clock(g.mesh, 3 * time.Second)
		_ = actod.sim_mesh_run_until_idle(g.mesh)
	}

	expect(
		t,
		gone_remote_subscribers(g) > 0,
		"node 1's subscription did not come back with it",
	)
	gone_broadcast(g)
	expect_value(t, g_gone_broadcasts_seen, 1)
}

test_sim_an_unregistered_node_leaves_no_ring_for_a_replacement :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39000, watch_log = true)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	expect_value(t, gone_connection(g), 0)
	expect_value(t, sync.atomic_load(&g_gone_left_for_a_replacement), 0)
}

test_sim_a_node_timed_out_is_reached_again_when_the_lower_port_dials_the_higher :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39100, higher_port_dials = true)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	actod.sim_mesh_partition(g.mesh, 0, 1)
	for _ in 0 ..< 4 {
		actod.sim_mesh_advance_clock(g.mesh, 30 * time.Second)
		_ = actod.sim_mesh_run_until_idle(g.mesh)
	}
	actod.sim_mesh_heal(g.mesh, 0, 1)
	expect_node_not_found(t, g)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	again, registered := actod.register_node(
		actod.sim_mesh_name(g.mesh, 1),
		{address = net.IP4_Loopback, port = g.mesh.ports[1]},
		.TCP_Custom_Protocol,
		connect = true,
	)
	expect(t, registered, "registering a timed out node again was refused")
	expect_value(t, again, g.peer)
	for _ in 0 ..< 4 {
		actod.sim_mesh_advance_clock(g.mesh, 3 * time.Second)
		_ = actod.sim_mesh_run_until_idle(g.mesh)
	}

	_ = actod.sim_mesh_bind(g.mesh, 1)
	_, found := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 0))
	expect(t, found, "node 1 does not find node 0 after node 0 dialled it")
	expect(
		t,
		gone_remote_subscribers(g) > 0,
		"node 1's subscription did not come back once node 0 dialled it",
	)
	gone_broadcast(g)
	expect_value(t, g_gone_broadcasts_seen, 1)
}

test_sim_unregister_node_whose_connection_refuses_the_close_still_closes_the_node :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39200, watch_log = true)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	connection := gone_connection_actor(g)
	sync.atomic_store(&connection.state, actod.Actor_State.ZERO)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	actod.sim_mesh_crash(g.mesh, 1)

	expect_value(t, gone_connection(g), 0)
	expect_value(t, sync.atomic_load(&g_gone_left_for_a_replacement), 0)
	expect_node_not_found(t, g)
	expect_node_closed(t, g)
}

@(private = "file")
gone_connection_actor :: proc(g: Gone_Mesh) -> ^actod.Actor {
	_ = actod.sim_mesh_bind(g.mesh, 0)
	found, _ := actod.get(&actod.NODE.actor_registry, gone_connection(g))
	return cast(^actod.Actor)found
}

test_sim_unregister_node_whose_connection_does_not_stop_leaves_the_node_as_it_was :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39400)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	stuck := gone_connection(g)
	connection := gone_connection_actor(g)
	state := sync.atomic_load(&connection.state)
	sync.atomic_store(&connection.state, actod.Actor_State.STOPPING)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_bind(g.mesh, 0)
	sync.atomic_store(&connection.state, state)

	expect_value(t, gone_connection(g), stuck)
	_, found := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, found, "a node whose connection did not stop is not found")
	expect(
		t,
		gone_remote_subscribers(g) > 0,
		"a node whose connection did not stop lost its subscription",
	)
}

test_sim_a_goodbye_to_a_connection_no_longer_the_node_s_leaves_the_node_found :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39300)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	active := gone_connection(g)
	_ = actod.sim_mesh_bind(g.mesh, 0)
	sync.atomic_store(
		cast(^u64)&actod.NODE.connection_actors[g.peer],
		u64(g.publisher),
	)

	_ = actod.sim_mesh_bind(g.mesh, 1)
	back, known := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 0))
	expect(t, known, "node 1 does not know node 0")
	actod.send_disconnect_to_ring(actod.get_connection_ring(back), "leaving")
	_ = actod.sim_mesh_run_until_idle(g.mesh)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	sync.atomic_store(
		cast(^u64)&actod.NODE.connection_actors[g.peer],
		u64(active),
	)
	_, found := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, found, "a goodbye to a stale connection marked the node gone")
}

test_sim_a_node_unregistered_while_another_connection_takes_it_over_is_left_found :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39500, watch_log = true)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	actod.sim_mesh_partition(g.mesh, 0, 1)
	actod.sim_mesh_sever(g.mesh, 0, 1, deliver_error = true)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	_ = actod.sim_mesh_bind(g.mesh, 0)
	_ = actod.send_remote_by_name(
		actod.sim_mesh_name(g.mesh, 1),
		"gone_subscriber",
		Integration_Test_Message{id = 2, payload = "send"},
	)
	expect(
		t,
		gone_staged_slots(g) > 0,
		"a send while the link was down staged nothing",
	)

	g_gone_hook_peer = g.peer
	g_gone_take_over_while_closing = g.publisher
	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect_value(t, g_gone_take_over_while_closing, 0)

	expect_value(t, gone_connection(g), g.publisher)
	sync.atomic_store(cast(^u64)&actod.NODE.connection_actors[g.peer], 0)
	_, found := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, found, "closing a connection taken over marked the node gone")
}

test_sim_a_node_marked_gone_while_its_dial_takes_over_is_found_once_the_dial_holds_it :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39600, watch_log = true)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	actod.sim_mesh_crash(g.mesh, 1)
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect(
		t,
		gone_connection(g) != 0,
		"node 0 dropped its connection to node 1",
	)
	_ = actod.sim_mesh_restart(g.mesh, 1)

	_ = actod.sim_mesh_bind(g.mesh, 1)
	lower, known := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 0))
	expect(t, known, "the restarted node 1 does not know node 0")
	_ = actod.get_or_create_connection(lower)

	g_gone_hook_peer = g.peer
	g_gone_mark_gone_while_taking_over = true
	_ = actod.sim_mesh_run_until_idle(g.mesh)
	expect(
		t,
		!g_gone_mark_gone_while_taking_over,
		"node 1's dial did not take over node 0's own connection",
	)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	_, found := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 1))
	expect(t, found, "the dial that took the node over left it gone")
}

test_sim_unregister_node_with_no_connection_ends_its_lifecycle_stream_and_tells_the_other_stream_peers_its_actors_ended :: proc(
	t: ^testing.T,
) {
	g, ok := gone_mesh_create(t, 39700, nodes = 3)
	defer actod.sim_mesh_destroy(g.mesh)
	if !ok do return

	gone_stage_into_a_stopped_connection(t, g)
	gone_stop_connection(t, g)
	expect_value(t, gone_connection(g), 0)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	third, known := actod.get_node_by_name(actod.sim_mesh_name(g.mesh, 2))
	expect(t, known, "node 0 does not know node 2")
	expect(
		t,
		sync.atomic_load(&actod.NODE.lifecycle_stream_peers[third]),
		"node 2 does not stream node 0's lifecycle",
	)
	mirror := actod.pack_pid(actod.Handle{idx = 7, gen = 1}, g.peer)
	_, _ = actod.add_remote(
		&actod.NODE.actor_registry,
		mirror,
		"gone_mirror@mesh1",
	)
	sync.atomic_store(&actod.NODE.lifecycle_stream_peers[g.peer], true)
	staged_before := gone_staged_slots_for(g, third)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	actod.unregister_node(g.peer)

	_ = actod.sim_mesh_bind(g.mesh, 0)
	expect(
		t,
		!sync.atomic_load(&actod.NODE.lifecycle_stream_peers[g.peer]),
		"a gone node still streams this node's lifecycle",
	)
	expect(
		t,
		gone_staged_slots_for(g, third) > staged_before,
		"node 2 was not told the gone node's mirrored actor ended",
	)
}
