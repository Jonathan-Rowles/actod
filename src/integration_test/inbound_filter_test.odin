package integration

import "../actod"
import "core:fmt"
import "core:net"
import "core:testing"

@(private = "file")
g_offered_controls: bit_set[actod.Inbound_Control]

@(private = "file")
g_offered_lifecycle: [dynamic]typeid

@(private = "file")
g_remote_spawns: int

@(private = "file")
refuse_all_but_heartbeat :: proc(message: actod.Inbound_Message) -> bool {
	if message.control != .None {
		g_offered_controls += {message.control}
		return message.control == .Heartbeat
	}
	if message.lifecycle {
		append(&g_offered_lifecycle, message.type_id)
		return false
	}
	return true
}

@(private = "file")
offered_lifecycle :: proc(type_id: typeid) -> bool {
	for offered in g_offered_lifecycle {
		if offered == type_id do return true
	}
	return false
}

@(private = "file")
count_remote_spawn :: proc(name: string, parent_pid: actod.PID) -> (actod.PID, bool) {
	g_remote_spawns += 1
	return actod.spawn(name, Mesh_Counter_Data{}, Mesh_Counter_Behaviour)
}

test_sim_inbound_filter_judges_every_control_and_lifecycle_frame :: proc(t: ^testing.T) {
	g_offered_controls = {}
	g_offered_lifecycle = make([dynamic]typeid)
	defer delete(g_offered_lifecycle)
	g_remote_spawns = 0

	watched_type, type_ok := actod.register_actor_type("inbound_filter_watched")
	expect(t, type_ok, "watched actor type registered")
	expect(
		t,
		actod.register_spawn_func("inbound_filter_spawn", count_remote_spawn),
		"spawn func registered",
	)

	mesh := actod.sim_mesh_create(2, base_port = 35000, log_level = test_log_level())
	defer actod.sim_mesh_destroy(mesh)

	actod.sim_mesh_node(mesh, 0).config.network.inbound_filter = refuse_all_but_heartbeat

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	_ = actod.sim_mesh_bind(mesh, 0)
	peer_id, peer_known := actod.get_node_by_name(actod.sim_mesh_name(mesh, 1))
	expect(t, peer_known, "the guarded node knows the peer")
	count_before := actod.get_subscriber_count(watched_type)

	_ = actod.sim_mesh_bind(mesh, 1)
	guarded_id, guarded_known := actod.get_node_by_name(actod.sim_mesh_name(mesh, 0))
	expect(t, guarded_known, "the peer knows the guarded node")
	ring := actod.get_connection_ring(guarded_id)
	expect(t, ring != nil, "the peer has a ring to the guarded node")
	watched_hash, _ := actod.get_actor_type_hash(watched_type)
	actod.send_lifecycle_message(
		ring,
		actod.Subscribe_Remote{type_name_hash = watched_hash, count = max(u32)},
	)
	actod.send_lifecycle_message(
		ring,
		actod.Unsubscribe_Remote{type_name_hash = watched_hash, count = 1},
	)
	actod.send_lifecycle_message(
		ring,
		actod.Remote_Spawn_Request {
			request_id = 7,
			spawn_func_name_hash = actod.fnv1a_hash("inbound_filter_spawn"),
			actor_name = "spawned_by_peer",
		},
	)
	actod.send_lifecycle_message(ring, actod.Remote_Spawn_Response{request_id = 7, success = true})
	actod.announce_node_to_peers(
		"ghost",
		net.Endpoint{address = net.IP4_Loopback, port = 35999},
		0,
	)
	gossiped, gossip_spawned := actod.spawn(
		"gossiped",
		Mesh_Counter_Data{},
		Mesh_Counter_Behaviour,
	)
	expect(t, gossip_spawned, "the peer spawned an actor to gossip")
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	expect_value(t, actod.get_subscriber_count(watched_type), count_before)
	expect_value(t, actod.NODE.type_subscribers[watched_type].remote_node_sub_count[peer_id], 0)
	expect_value(t, g_remote_spawns, 0)
	_, spawned_by_peer := actod.get_actor_pid("spawned_by_peer")
	expect(t, !spawned_by_peer, "a refused remote spawn request spawned an actor")
	_, ghost_known := actod.get_node_by_name("ghost")
	expect(t, !ghost_known, "a refused node directory registered a node")
	_, gossip_seen := actod.get_actor_pid(fmt.tprintf("gossiped@%s", actod.sim_mesh_name(mesh, 1)))
	expect(t, !gossip_seen, "a refused spawn broadcast mirrored the peer's actor")
	expect(
		t,
		!actod.NODE.lifecycle_stream_peers[peer_id],
		"a refused lifecycle stream request made the peer a stream peer",
	)

	_ = actod.sim_mesh_bind(mesh, 1)
	_ = actod.terminate_actor(gossiped, .NORMAL)
	_ = actod.sim_mesh_run_until_idle(mesh)

	actod.sim_mesh_advance_clock(
		mesh,
		actod.sim_mesh_node(mesh, 1).config.network.heartbeat_interval,
	)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 1)
	actod.send_disconnect_to_ring(actod.get_connection_ring(guarded_id), "peer asks to leave")
	_ = actod.sim_mesh_run_until_idle(mesh)

	for type_id in ([]typeid{actod.Subscribe_Remote, actod.Unsubscribe_Remote, actod.Remote_Spawn_Request, actod.Remote_Spawn_Response, actod.Actor_Spawned_Broadcast, actod.Actor_Terminated_Broadcast}) {
		expect(t, offered_lifecycle(type_id), "a lifecycle frame was not offered to the filter")
	}
	expect_value(
		t,
		g_offered_controls,
		bit_set[actod.Inbound_Control] {
			.Heartbeat,
			.Node_Directory,
			.Disconnect,
			.Lifecycle_Stream,
		},
	)
}
