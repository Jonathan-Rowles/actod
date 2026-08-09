package integration

import "../actod"
import "core:testing"
import "core:time"

test_sim_regression_stale_gossip_after_restart :: proc(t: ^testing.T) {
	mesh := actod.sim_mesh_create(3, base_port = 29000)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 2)
	_, ok := actod.spawn("victim", Mesh_Counter_Data{slot = 3}, Mesh_Counter_Behaviour)
	expect(t, ok, "victim spawn failed")

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")
	_ = actod.sim_mesh_bind(mesh, 0)
	_, seen := actod.get_actor_pid("victim@mesh2")
	expect(t, seen, "victim gossip did not reach node 0")

	actod.sim_mesh_partition(mesh, 0, 1)

	actod.sim_mesh_crash(mesh, 2)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_restart(mesh, 2)
	actod.sim_mesh_partition(mesh, 1, 2)
	_ = actod.sim_mesh_bind(mesh, 2)
	_, ok2 := actod.spawn("victim", Mesh_Counter_Data{slot = 3}, Mesh_Counter_Behaviour)
	expect(t, ok2, "victim respawn failed")

	actod.sim_mesh_advance_clock(mesh, 5 * time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)
	_ = actod.sim_mesh_bind(mesh, 0)
	_, fresh := actod.get_actor_pid("victim@mesh2")
	expect(t, fresh, "fresh victim proxy did not re-sync to node 0 after restart")

	actod.sim_mesh_crash(mesh, 1)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, still := actod.get_actor_pid("victim@mesh2")
	expect(t, still, "stale terminate gossip evicted the restarted node's fresh proxy")
}

test_sim_regression_relay_heals_lost_broadcast :: proc(t: ^testing.T) {
	mesh := actod.sim_mesh_create(3, base_port = 30000)
	defer actod.sim_mesh_destroy(mesh)
	defer actod.frame_tap_clear()

	_ = actod.sim_mesh_bind(mesh, 2)
	victim_pid, ok := actod.spawn("heal_target", Mesh_Counter_Data{slot = 3}, Mesh_Counter_Behaviour)
	expect(t, ok, "spawn failed")

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")
	_ = actod.sim_mesh_bind(mesh, 0)
	_, seen := actod.get_actor_pid("heal_target@mesh2")
	expect(t, seen, "spawn gossip did not reach node 0")

	_ = actod.sim_mesh_bind(mesh, 2)
	node0_id, known := actod.get_node_by_name("mesh0")
	expect(t, known, "node 0 unknown at node 2")
	actod.frame_tap_add(
		actod.Frame_Fault_Rule {
			dir       = .Out,
			action    = .Drop,
			type_hash = actod.frame_tap_type_hash(actod.Actor_Terminated_Broadcast),
			node      = actod.sim_mesh_node(mesh, 2),
			peer      = node0_id,
			count     = 1,
		},
	)

	_ = actod.terminate_actor(victim_pid)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, ghost := actod.get_actor_pid("heal_target@mesh2")
	expect(t, !ghost, "relay did not heal the dropped terminate broadcast; ghost proxy remains on node 0")
}

test_sim_regression_relay_cannot_resurrect :: proc(t: ^testing.T) {
	mesh := actod.sim_mesh_create(3, base_port = 34000)
	defer actod.sim_mesh_destroy(mesh)
	defer actod.frame_tap_clear()

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	actod.sim_mesh_partition(mesh, 0, 1)
	_ = actod.sim_mesh_bind(mesh, 1)
	node0_id, known := actod.get_node_by_name("mesh0")
	expect(t, known, "node 0 unknown at node 1")
	actod.frame_tap_add(
		actod.Frame_Fault_Rule {
			dir       = .Out,
			action    = .Drop,
			type_hash = actod.frame_tap_type_hash(actod.Actor_Terminated_Broadcast),
			node      = actod.sim_mesh_node(mesh, 1),
			peer      = node0_id,
			count     = 1,
		},
	)

	_ = actod.sim_mesh_bind(mesh, 2)
	victim_pid, ok := actod.spawn("short_lived", Mesh_Counter_Data{slot = 3}, Mesh_Counter_Behaviour)
	expect(t, ok, "spawn failed")
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, seen := actod.get_actor_pid("short_lived@mesh2")
	expect(t, seen, "spawn gossip did not reach node 0 directly")

	_ = actod.sim_mesh_bind(mesh, 2)
	_ = actod.terminate_actor(victim_pid)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, gone := actod.get_actor_pid("short_lived@mesh2")
	expect(t, !gone, "terminate gossip did not reach node 0 directly")

	actod.sim_mesh_heal(mesh, 0, 1)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, resurrected := actod.get_actor_pid("short_lived@mesh2")
	expect(t, !resurrected, "delayed relayed spawn resurrected the terminated actor's proxy")
}

@(private = "file")
scale_up_pool :: proc(t: ^testing.T, mesh: ^actod.Sim_Mesh, i: int, peer_name: string) {
	_ = actod.sim_mesh_bind(mesh, i)
	peer_id, known := actod.get_node_by_name(peer_name)
	expect(t, known, "peer not registered")
	conn_pid := actod.NODE.connection_actors[peer_id]
	expect(t, conn_pid != 0, "no connection actor for peer")
	_ = actod.send_message(conn_pid, actod.Scale_Up_Request{})
	_ = actod.sim_mesh_run_until_idle(mesh)
	_ = actod.sim_mesh_bind(mesh, i)
	pool := actod.get_connection_pool(peer_id)
	expect(t, pool != nil && int(actod.pool_active_count(pool)) == 2, "scale-up did not complete")
}

test_sim_regression_pool_peer_crash :: proc(t: ^testing.T) {
	mesh := actod.sim_mesh_create(2, base_port = 31000)
	defer actod.sim_mesh_destroy(mesh)

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	scale_up_pool(t, mesh, 0, "mesh1")

	actod.sim_mesh_crash(mesh, 1)
	steps := actod.sim_mesh_run_until_idle(mesh, 200_000)
	expect(t, steps < 200_000, "sim service EOF-looped on the dead-peer pool ring")

	_ = actod.sim_mesh_restart(mesh, 1)
	actod.sim_mesh_advance_clock(mesh, 5 * time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect(t, actod.sim_mesh_connect_full(mesh), "mesh did not reconnect after peer restart")
	expect(t, actod.sim_mesh_settle_pools(mesh), "pools did not settle after peer restart")
}

test_sim_regression_idle_pool_ring_parks :: proc(t: ^testing.T) {
	mesh := actod.sim_mesh_create(2, base_port = 32000)
	defer actod.sim_mesh_destroy(mesh)

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	scale_up_pool(t, mesh, 0, "mesh1")

	expect(
		t,
		actod.sim_mesh_settle_pools(mesh),
		"never-used pool ring never became park-eligible; scale-down did not converge",
	)
}

@(private = "file")
g_reg_pub_type: actod.Actor_Type

@(private = "file")
g_reg_pub_seen: [2]map[int]int

@(private = "file")
g_reg_pub_behaviour: actod.Actor_Behaviour(Vopr_Pub_Data)

Reg_Sub_Data :: struct {
	slot: int,
}

Reg_Sub_Behaviour :: actod.Actor_Behaviour(Reg_Sub_Data) {
	init = proc(data: ^Reg_Sub_Data) {
		_, _ = actod.subscribe_type(g_reg_pub_type)
	},
	handle_message = proc(data: ^Reg_Sub_Data, from: actod.PID, msg: any) {
		if m, ok := msg.(Integration_Test_Message); ok {
			g_reg_pub_seen[data.slot][m.id] += 1
		}
	},
}

test_sim_regression_publish_during_scale_down :: proc(t: ^testing.T) {
	g_reg_pub_type, _ = actod.register_actor_type("reg_publisher")
	g_reg_pub_behaviour = actod.Actor_Behaviour(Vopr_Pub_Data) {
		actor_type = g_reg_pub_type,
		handle_message = proc(data: ^Vopr_Pub_Data, from: actod.PID, msg: any) {
			if m, ok := msg.(Vopr_Do_Publish); ok {
				actod.broadcast(Integration_Test_Message{id = m.pub_id, payload = "pub"})
			}
		},
	}
	for slot in 0 ..< 2 {
		g_reg_pub_seen[slot] = make(map[int]int)
	}
	defer for slot in 0 ..< 2 {
		delete(g_reg_pub_seen[slot])
	}

	mesh := actod.sim_mesh_create(2, base_port = 33000)
	defer actod.sim_mesh_destroy(mesh)

	pub_pids: [2]actod.PID
	for i in 0 ..< 2 {
		_ = actod.sim_mesh_bind(mesh, i)
		_, sub_ok := actod.spawn("reg_sub", Reg_Sub_Data{slot = i}, Reg_Sub_Behaviour)
		expect(t, sub_ok, "subscriber spawn failed")
		pub_pid, pub_ok := actod.spawn("reg_pub", Vopr_Pub_Data{}, g_reg_pub_behaviour)
		expect(t, pub_ok, "publisher spawn failed")
		pub_pids[i] = pub_pid
	}

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	scale_up_pool(t, mesh, 0, "mesh1")

	actod.sim_mesh_advance_clock(mesh, 30 * time.Second)
	_ = actod.sim_mesh_bind(mesh, 0)
	for id in 1 ..= 3 {
		_ = actod.send_message(pub_pids[0], Vopr_Do_Publish{pub_id = id})
	}
	_ = actod.sim_mesh_run_until_idle(mesh)

	expect(t, actod.sim_mesh_settle_pools(mesh), "pool scale-down did not settle")
	expect(t, actod.sim_mesh_connect_full(mesh), "mesh not fully connected after settle")

	for i in 0 ..< 2 {
		_ = actod.sim_mesh_bind(mesh, i)
		final_id := 100 + i
		_ = actod.send_message(pub_pids[i], Vopr_Do_Publish{pub_id = final_id})
		_ = actod.sim_mesh_run_until_idle(mesh)
		for j in 0 ..< 2 {
			expect_value(t, g_reg_pub_seen[j][final_id], 1)
		}
	}
}
