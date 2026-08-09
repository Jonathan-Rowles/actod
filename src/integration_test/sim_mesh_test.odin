package integration

import "../actod"
import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"

@(private = "file")
g_mesh_counts: [4]int

Mesh_Counter_Data :: struct {
	slot: int,
}

Mesh_Counter_Behaviour :: actod.Actor_Behaviour(Mesh_Counter_Data) {
	handle_message = proc(data: ^Mesh_Counter_Data, from: actod.PID, msg: any) {
		if _, ok := msg.(Integration_Test_Message); ok {
			g_mesh_counts[data.slot] += 1
		}
	},
}

Mesh_Relay_Data :: struct {
	next_node: string,
}

Mesh_Relay_Behaviour :: actod.Actor_Behaviour(Mesh_Relay_Data) {
	handle_message = proc(data: ^Mesh_Relay_Data, from: actod.PID, msg: any) {
		if m, ok := msg.(Integration_Test_Message); ok {
			if m.id > 0 {
				_ = actod.send_remote_by_name(
					data.next_node,
					"mesh_relay",
					Integration_Test_Message{id = m.id - 1, payload = "hop"},
				)
			}
		}
	},
}

test_sim_mesh_basic :: proc(t: ^testing.T) {
	g_mesh_counts = {}

	mesh := actod.sim_mesh_create(3, base_port = 21000)
	defer actod.sim_mesh_destroy(mesh)

	for i in 0 ..< 3 {
		_ = actod.sim_mesh_bind(mesh, i)
		_, ok := actod.spawn("mc", Mesh_Counter_Data{slot = i}, Mesh_Counter_Behaviour)
		expect(t, ok, "counter spawn failed")
	}

	expect(t, actod.sim_mesh_connect_full(mesh), "full mesh connect did not settle")

	for i in 0 ..< 3 {
		_ = actod.sim_mesh_bind(mesh, i)
		for j in 0 ..< 3 {
			if j == i {
				continue
			}
			err := actod.send_remote_by_name(
				actod.sim_mesh_name(mesh, j),
				"mc",
				Integration_Test_Message{id = i, payload = "mesh"},
			)
			expect(t, err == .OK, "remote send failed")
		}
	}

	steps := actod.sim_mesh_run_until_idle(mesh)
	expect(t, steps > 0, "mesh pump did no work")

	for i in 0 ..< 3 {
		expect_value(t, g_mesh_counts[i], 2)
	}

	_ = actod.sim_mesh_bind(mesh, 0)
	_, sees_1 := actod.get_actor_pid("mc@mesh1")
	_, sees_2 := actod.get_actor_pid("mc@mesh2")
	expect(t, sees_1 && sees_2, "gossip did not converge on node 0")
}

@(private = "file")
run_mesh_trace_scenario :: proc(t: ^testing.T, seed: u64) -> []actod.Sim_Trace_Event {
	actod.sim_trace_enable(true)
	actod.sim_trace_reset()

	mesh := actod.sim_mesh_create(3, seed, base_port = 22000)

	relay_pids: [3]actod.PID
	for i in 0 ..< 3 {
		_ = actod.sim_mesh_bind(mesh, i)
		pid, ok := actod.spawn(
			"mesh_relay",
			Mesh_Relay_Data{next_node = actod.sim_mesh_name(mesh, (i + 1) % 3)},
			Mesh_Relay_Behaviour,
		)
		expect(t, ok, "relay spawn failed")
		relay_pids[i] = pid
	}

	for i in 0 ..< 3 {
		_ = actod.sim_mesh_bind(mesh, i)
		for _ in 0 ..< 2 {
			_ = actod.send_message(relay_pids[i], Integration_Test_Message{id = 5})
		}
	}

	_ = actod.sim_mesh_run_until_idle(mesh)
	actod.sim_mesh_advance_clock(mesh, 60 * time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)
	actod.sim_mesh_destroy(mesh)

	actod.sim_trace_enable(false)
	return slice.clone(actod.sim_trace_events())
}

test_sim_mesh_determinism :: proc(t: ^testing.T) {
	first := run_mesh_trace_scenario(t, 42)
	defer delete(first)
	other := run_mesh_trace_scenario(t, 7)
	defer delete(other)

	expect(t, len(first) > 100, "trace suspiciously short")
	expect(t, !slice.equal(first, other), "different seeds should produce different traces")

	kind_counts: [actod.Sim_Trace_Kind]int
	for event in first {
		kind_counts[event.kind] += 1
	}
	for count, kind in kind_counts {
		expect(t, count > 0, fmt.tprintf("trace kind %v never recorded in the scenario", kind))
	}

	for _ in 0 ..< 3 {
		replay := run_mesh_trace_scenario(t, 42)
		expect(t, slice.equal(first, replay), "same seed must replay the identical trace")
		delete(replay)
	}
}

test_sim_mesh_partition_heal :: proc(t: ^testing.T) {
	g_mesh_counts = {}

	mesh := actod.sim_mesh_create(2, base_port = 23000)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 1)
	_, ok := actod.spawn("mc", Mesh_Counter_Data{slot = 0}, Mesh_Counter_Behaviour)
	expect(t, ok, "counter spawn failed")

	_ = actod.sim_mesh_bind(mesh, 0)
	_ = actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{})
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[0], 1)

	actod.sim_mesh_partition(mesh, 0, 1)

	_ = actod.sim_mesh_bind(mesh, 0)
	for _ in 0 ..< 3 {
		_ = actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{})
	}
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[0], 1)

	actod.sim_mesh_heal(mesh, 0, 1)
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[0], 4)
}

@(private = "file")
g_sup_child_terms: int

Sup_Parent_Data :: struct {}

Sup_Parent_Behaviour :: actod.Actor_Behaviour(Sup_Parent_Data) {
	handle_message = proc(data: ^Sup_Parent_Data, from: actod.PID, msg: any) {},
	on_child_terminated = proc(
		data: ^Sup_Parent_Data,
		child_pid: actod.PID,
		reason: actod.Termination_Reason,
		will_restart: bool,
	) {
		g_sup_child_terms += 1
	},
}

Sup_Child_Data :: struct {}

Sup_Child_Behaviour :: actod.Actor_Behaviour(Sup_Child_Data) {
	handle_message = proc(data: ^Sup_Child_Data, from: actod.PID, msg: any) {},
}

spawn_sim_sup_child :: proc(name: string, parent: actod.PID) -> (actod.PID, bool) {
	return actod.spawn(
		name,
		Sup_Child_Data{},
		Sup_Child_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
		parent,
	)
}

test_sim_mesh_remote_spawn_supervision :: proc(t: ^testing.T) {
	g_sup_child_terms = 0
	_ = actod.register_spawn_func("sim_sup_child", spawn_sim_sup_child)

	mesh := actod.sim_mesh_create(2, base_port = 26000)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	parent_pid, parent_ok := actod.spawn("sup_parent", Sup_Parent_Data{}, Sup_Parent_Behaviour)
	expect(t, parent_ok, "parent spawn failed")

	child_pid, spawned := actod.spawn_remote("sim_sup_child", "rc", "mesh1", parent_pid)
	expect(t, spawned, "remote spawn over the virtual transport failed")
	if !spawned {
		return
	}
	expect(t, !actod.is_local_pid(child_pid), "remote child should not be local")
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 1)
	local_child, on_b := actod.get_actor_pid("rc")
	expect(t, on_b, "child not running on node B")
	_ = actod.terminate_actor(local_child)
	_ = actod.sim_mesh_run_until_idle(mesh)

	expect_value(t, g_sup_child_terms, 1)
}

test_sim_mesh_discovery :: proc(t: ^testing.T) {
	g_mesh_counts = {}

	mesh := actod.sim_mesh_create(3, base_port = 27000, register_peers = false)
	defer actod.sim_mesh_destroy(mesh)

	actod.sim_mesh_register(mesh, 0, 1)
	actod.sim_mesh_register(mesh, 1, 0)
	actod.sim_mesh_register(mesh, 1, 2)
	actod.sim_mesh_register(mesh, 2, 1)

	for i in 0 ..< 3 {
		_ = actod.sim_mesh_bind(mesh, i)
		_, ok := actod.spawn("mc", Mesh_Counter_Data{slot = i}, Mesh_Counter_Behaviour)
		expect(t, ok, "counter spawn failed")
	}

	_ = actod.sim_mesh_bind(mesh, 0)
	_ = actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{})
	_ = actod.sim_mesh_bind(mesh, 2)
	_ = actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{})
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[1], 2)

	_ = actod.sim_mesh_bind(mesh, 2)
	_, knows_a := actod.get_node_by_name("mesh0")
	expect(t, knows_a, "node directory gossip did not teach C about A")
	_, sees_a_actor := actod.get_actor_pid("mc@mesh0")
	expect(t, sees_a_actor, "spawn gossip did not propagate A's actor to C")

	err := actod.send_remote_by_name("mesh0", "mc", Integration_Test_Message{})
	expect(t, err == .OK, "send to gossip-discovered node failed")
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[0], 1)
}

test_sim_mesh_pool_scale_up :: proc(t: ^testing.T) {
	g_mesh_counts = {}

	mesh := actod.sim_mesh_create(2, base_port = 28000)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 1)
	_, ok := actod.spawn("mc", Mesh_Counter_Data{slot = 0}, Mesh_Counter_Behaviour)
	expect(t, ok, "counter spawn failed")

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	_ = actod.sim_mesh_bind(mesh, 0)
	peer_id, known := actod.get_node_by_name("mesh1")
	expect(t, known, "peer not registered")
	conn_pid := actod.NODE.connection_actors[peer_id]
	expect(t, conn_pid != 0, "no connection actor for peer")
	_ = actod.send_message(conn_pid, actod.Scale_Up_Request{})
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	pool := actod.get_connection_pool(peer_id)
	expect(t, pool != nil, "no pool on requester")
	expect_value(t, int(actod.pool_active_count(pool)), 2)

	_ = actod.sim_mesh_bind(mesh, 1)
	back_id, back_known := actod.get_node_by_name("mesh0")
	expect(t, back_known, "requester not registered on peer")
	peer_pool := actod.get_connection_pool(back_id)
	expect(t, peer_pool != nil, "no pool on peer")
	expect_value(t, int(actod.pool_active_count(peer_pool)), 2)

	_ = actod.sim_mesh_bind(mesh, 0)
	for i in 0 ..< 6 {
		err := actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{id = i})
		expect(t, err == .OK, "send over scaled pool failed")
	}
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[0], 6)
}

test_sim_mesh_crash_restart :: proc(t: ^testing.T) {
	g_mesh_counts = {}

	mesh := actod.sim_mesh_create(2, base_port = 24000)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 1)
	_, ok := actod.spawn("mc", Mesh_Counter_Data{slot = 0}, Mesh_Counter_Behaviour)
	expect(t, ok, "counter spawn failed")

	_ = actod.sim_mesh_bind(mesh, 0)
	_ = actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{})
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[0], 1)
	_ = actod.sim_mesh_bind(mesh, 0)
	_, visible := actod.get_actor_pid("mc@mesh1")
	expect(t, visible, "gossip did not reach node 0 before the crash")

	actod.sim_mesh_crash(mesh, 1)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, dangling := actod.get_actor_pid("mc@mesh1")
	expect(t, !dangling, "remote actor proxy not evicted after crash")

	_ = actod.sim_mesh_restart(mesh, 1)
	_ = actod.sim_mesh_bind(mesh, 1)
	_, ok2 := actod.spawn("mc", Mesh_Counter_Data{slot = 1}, Mesh_Counter_Behaviour)
	expect(t, ok2, "counter respawn failed")

	actod.sim_mesh_advance_clock(mesh, 5 * time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	for _ in 0 ..< 2 {
		_ = actod.send_remote_by_name("mesh1", "mc", Integration_Test_Message{})
	}
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_mesh_counts[1], 2)

	_ = actod.sim_mesh_bind(mesh, 0)
	_, gossip_restored := actod.get_actor_pid("mc@mesh1")
	expect(t, gossip_restored, "gossip did not re-converge after restart")
}
