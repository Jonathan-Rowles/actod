package integration

import "../actod"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"

connection_actor_of :: proc(node_id: actod.Node_ID) -> ^actod.Actor {
	pid := actod.PID(
		sync.atomic_load(cast(^u64)&actod.NODE.connection_actors[node_id]),
	)
	if pid == 0 do return nil
	ptr, found := actod.get(&actod.NODE.actor_registry, pid)
	if !found || ptr == nil do return nil
	return cast(^actod.Actor)ptr
}

exhaust_arena :: proc(actor: ^actod.Actor) {
	for chunk := 64 * mem.Kilobyte; chunk > 0; chunk /= 2 {
		for {
			_, err := mem.alloc_bytes(chunk, 1, actor.allocator)
			if err != nil do break
		}
	}
}

test_sim_connection_reconnects_with_its_arena_exhausted :: proc(
	t: ^testing.T,
) {
	mesh := actod.sim_mesh_create(
		2,
		base_port = 37100,
		auth_password = "connection arena",
		log_level = test_log_level(),
	)
	defer actod.sim_mesh_destroy(mesh)

	if !expect(t, actod.sim_mesh_connect_full(mesh), "the mesh connected") do return

	_ = actod.sim_mesh_bind(mesh, 0)
	peer, known := actod.get_node_by_name(actod.sim_mesh_name(mesh, 1))
	if !expect(t, known, "node 0 knows node 1") do return
	actor := connection_actor_of(peer)
	if !expect(t, actor != nil, "node 0 holds a connection actor for node 1") do return
	closed := actod.send_message(
		actor.pid,
		actod.Close_Connection {
			reason = "the test closes it to make it reconnect",
		},
	)
	if !expect(t, closed == .OK, "the close reached the connection actor") do return
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	exhaust_arena(actor)
	actod.sim_mesh_advance_clock(mesh, 3 * time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	expect(
		t,
		connection_actor_of(peer) == actor,
		"the connection actor with an exhausted arena is still running after its reconnect",
	)
	ring := actod.get_connection_ring(peer)
	expect(
		t,
		ring != nil && sync.atomic_load(&ring.state) == .Ready,
		"the handshake buffers come from the system allocator, so an exhausted arena does not stop the reconnect",
	)
}

close_and_reconnect :: proc(
	t: ^testing.T,
	mesh: ^actod.Sim_Mesh,
	actor: ^actod.Actor,
) -> bool {
	_ = actod.sim_mesh_bind(mesh, 0)
	closed := actod.send_message(
		actor.pid,
		actod.Close_Connection {
			reason = "the test closes it to make it reconnect",
		},
	)
	if !expect(t, closed == .OK, "the close reached the connection actor") do return false
	_ = actod.sim_mesh_run_until_idle(mesh)
	actod.sim_mesh_advance_clock(mesh, 3 * time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)
	_ = actod.sim_mesh_bind(mesh, 0)
	return true
}

connection_arena_used :: proc(actor: ^actod.Actor) -> uint {
	return actor.arena.primary.total_used + actor.arena.overflow.total_used
}

RECONNECT_ARENA_ROUNDS :: 20

test_sim_reconnects_leave_the_connection_arena_where_it_was :: proc(
	t: ^testing.T,
) {
	mesh := actod.sim_mesh_create(
		4,
		base_port = 37110,
		auth_password = "connection arena",
		log_level = test_log_level(),
	)
	defer actod.sim_mesh_destroy(mesh)
	if !expect(t, actod.sim_mesh_connect_full(mesh), "the mesh connected") do return

	_ = actod.sim_mesh_bind(mesh, 0)
	peer, known := actod.get_node_by_name(actod.sim_mesh_name(mesh, 1))
	if !expect(t, known, "node 0 knows node 1") do return
	actor := connection_actor_of(peer)
	if !expect(t, actor != nil, "node 0 holds a connection actor for node 1") do return
	if !close_and_reconnect(t, mesh, actor) do return
	used_after_first := connection_arena_used(actor)

	for round in 0 ..< RECONNECT_ARENA_ROUNDS {
		if !close_and_reconnect(t, mesh, actor) do return
		ring := actod.get_connection_ring(peer)
		if !expectf(t, ring != nil && sync.atomic_load(&ring.state) == .Ready, "reconnect %d came up", round) do return
	}

	expectf(
		t,
		connection_arena_used(actor) == used_after_first,
		"%d reconnects with auth and a node directory grew the connection actor's arena from %d B to %d B",
		RECONNECT_ARENA_ROUNDS,
		used_after_first,
		connection_arena_used(actor),
	)
}
