package integration

import "../../test_harness/ti"
import "../actod"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

@(private = "file")
g_sim_received: int

@(private = "file")
g_sim_forwarded: int

@(private = "file")
g_sim_last_from: actod.PID

Sim_Counter_Data :: struct {
	id: int,
}

Sim_Counter_Behaviour :: actod.Actor_Behaviour(Sim_Counter_Data) {
	handle_message = proc(data: ^Sim_Counter_Data, from: actod.PID, msg: any) {
		if _, ok := msg.(Integration_Test_Message); ok {
			g_sim_received += 1
			g_sim_last_from = from
		}
	},
}

Sim_Relay_Data :: struct {
	target: actod.PID,
}

Sim_Relay_Behaviour :: actod.Actor_Behaviour(Sim_Relay_Data) {
	handle_message = proc(data: ^Sim_Relay_Data, from: actod.PID, msg: any) {
		if m, ok := msg.(Integration_Test_Message); ok {
			_ = actod.send_message(data.target, m)
			g_sim_forwarded += 1
		}
	},
}

test_sim_pump_basic :: proc(t: ^testing.T) {
	g_sim_received = 0
	g_sim_forwarded = 0
	g_sim_last_from = 0

	for i in 0 ..< actod.NODE.worker_pool.worker_count {
		expect(
			t,
			actod.NODE.worker_pool.workers[i].thread == nil,
			"sim mode must not create worker threads",
		)
	}

	counter_pid, counter_ok := actod.spawn(
		"sim_counter",
		Sim_Counter_Data{},
		Sim_Counter_Behaviour,
	)
	expect(t, counter_ok, "counter spawn failed")

	relay_pid, relay_ok := actod.spawn(
		"sim_relay",
		Sim_Relay_Data{target = counter_pid},
		Sim_Relay_Behaviour,
		actod.make_actor_config(use_dedicated_os_thread = true),
	)
	expect(t, relay_ok, "relay spawn failed")

	message_count := 100
	for i in 0 ..< message_count {
		err := actod.send_message(relay_pid, Integration_Test_Message{id = i, payload = "sim"})
		expect(t, err == .OK, "send failed")
	}

	steps := actod.sim_run_until_idle()
	expect(t, steps > 0, "pump did no work")
	expect(t, actod.sim_pump() == false, "pump not idle after run_until_idle")

	expect_value(t, g_sim_forwarded, message_count)
	expect_value(t, g_sim_received, message_count)
	expect_value(t, g_sim_last_from, relay_pid)
}

@(private = "file")
g_sim_ticks: int

Sim_Timer_Data :: struct {
	timer_id: u32,
}

Sim_Timer_Behaviour :: actod.Actor_Behaviour(Sim_Timer_Data) {
	init = proc(data: ^Sim_Timer_Data) {
		data.timer_id, _ = actod.set_timer(100 * time.Millisecond, true)
	},
	handle_message = proc(data: ^Sim_Timer_Data, from: actod.PID, msg: any) {
		if v, ok := msg.(actod.Timer_Tick); ok && v.id == data.timer_id {
			g_sim_ticks += 1
		}
	},
}

test_sim_virtual_timer :: proc(t: ^testing.T) {
	g_sim_ticks = 0

	det: ti.Det_State
	det.virtual_now = time.now()
	det.virtual_tick_ns = 1
	ti.det = &det
	defer ti.det = nil

	_, ok := actod.spawn("sim_timer", Sim_Timer_Data{}, Sim_Timer_Behaviour)
	expect(t, ok, "timer actor spawn failed")

	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_ticks, 0)

	det.virtual_now = time.time_add(det.virtual_now, 150 * time.Millisecond)
	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_ticks, 1)

	det.virtual_now = time.time_add(det.virtual_now, 100 * time.Millisecond)
	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_ticks, 2)

	det.virtual_now = time.time_add(det.virtual_now, 1000 * time.Millisecond)
	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_ticks, 3)
}

@(private = "file")
g_sim_trace: [dynamic]int

Sim_Chain_Data :: struct {
	index: int,
	next:  actod.PID,
}

Sim_Chain_Behaviour :: actod.Actor_Behaviour(Sim_Chain_Data) {
	handle_message = proc(data: ^Sim_Chain_Data, from: actod.PID, msg: any) {
		if m, ok := msg.(Integration_Test_Message); ok {
			append(&g_sim_trace, data.index * 1000 + m.id)
			if m.id > 0 && data.next != 0 {
				_ = actod.send_message(data.next, Integration_Test_Message{id = m.id - 1})
			}
		}
	},
}

@(private = "file")
g_sim_scenario_runs: int

run_chain_scenario :: proc(t: ^testing.T, seed: u64) -> []int {
	g_sim_scenario_runs += 1
	reserve(&g_sim_trace, 256)
	clear(&g_sim_trace)
	actod.sim_seed(seed)
	defer actod.sim_seed(0)

	chain_len := 4
	pids := make([]actod.PID, chain_len)
	defer delete(pids)

	next: actod.PID = 0
	for i := chain_len - 1; i >= 0; i -= 1 {
		pid, ok := actod.spawn(
			fmt.tprintf("chain_%d_%d", g_sim_scenario_runs, i),
			Sim_Chain_Data{index = i, next = next},
			Sim_Chain_Behaviour,
			actod.make_actor_config(home_worker = i % 2),
		)
		expect(t, ok, "chain spawn failed")
		pids[i] = pid
		next = pid
	}

	for k in 0 ..< 8 {
		_ = actod.send_message(pids[k % chain_len], Integration_Test_Message{id = 3})
	}
	_ = actod.sim_run_until_idle()

	for pid in pids {
		_ = actod.terminate_actor(pid)
	}
	_ = actod.sim_run_until_idle()

	return slice.clone(g_sim_trace[:])
}

test_sim_seeded_determinism :: proc(t: ^testing.T) {
	first := run_chain_scenario(t, 42)
	third := run_chain_scenario(t, 7)
	defer delete(first)
	defer delete(third)
	defer delete(g_sim_trace)

	expect_value(t, len(first), 20)
	expect_value(t, len(third), len(first))
	expect(t, !slice.equal(first, third), "different seeds should interleave differently")

	for _ in 0 ..< 10 {
		replay := run_chain_scenario(t, 42)
		expect(t, slice.equal(first, replay), "same seed must replay the identical schedule")
		delete(replay)
	}
}

@(private = "file")
g_sim_node_a_count: int

@(private = "file")
g_sim_node_b_count: int

Sim_Iso_Data :: struct {
	counter: ^int,
}

Sim_Iso_Behaviour :: actod.Actor_Behaviour(Sim_Iso_Data) {
	handle_message = proc(data: ^Sim_Iso_Data, from: actod.PID, msg: any) {
		if _, ok := msg.(Integration_Test_Message); ok {
			data.counter^ += 1
		}
	},
}

test_sim_two_nodes :: proc(t: ^testing.T) {
	g_sim_node_a_count = 0
	g_sim_node_b_count = 0

	node_a := actod.NODE

	pid_a, ok_a := actod.spawn("iso", Sim_Iso_Data{counter = &g_sim_node_a_count}, Sim_Iso_Behaviour)
	expect(t, ok_a, "spawn on node A failed")
	for _ in 0 ..< 3 {
		_ = actod.send_message(pid_a, Integration_Test_Message{})
	}
	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_node_a_count, 3)

	node_b := actod.sim_create_node()
	previous := actod.sim_bind_node(node_b)
	expect(t, previous == node_a, "bind did not return the prior node")

	opts := actod.make_node_config(
		worker_count = 2,
		sim_mode = true,
		actor_config = actod.make_actor_config(logging = actod.make_log_config(level = .Error)),
	)
	actod.node_init("sim_node_b", opts)
	expect_value(t, actod.get_local_node_name(), "sim_node_b")

	pid_b, ok_b := actod.spawn("iso", Sim_Iso_Data{counter = &g_sim_node_b_count}, Sim_Iso_Behaviour)
	expect(t, ok_b, "spawn on node B failed")
	for _ in 0 ..< 5 {
		_ = actod.send_message(pid_b, Integration_Test_Message{})
	}
	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_node_b_count, 5)
	expect_value(t, g_sim_node_a_count, 3)

	actod.node_shutdown()
	_ = actod.sim_bind_node(node_a)
	actod.sim_destroy_node(node_b)

	for _ in 0 ..< 2 {
		_ = actod.send_message(pid_a, Integration_Test_Message{})
	}
	_ = actod.sim_run_until_idle()
	expect_value(t, g_sim_node_a_count, 5)
	expect_value(t, g_sim_node_b_count, 5)
}

@(private = "file")
g_vt_pong_received: int

@(private = "file")
g_vt_replies_received: int

VT_PING_COUNT :: 5

Vt_Pong_Data :: struct {}

Vt_Pong_Behaviour :: actod.Actor_Behaviour(Vt_Pong_Data) {
	handle_message = proc(data: ^Vt_Pong_Data, from: actod.PID, msg: any) {
		if m, ok := msg.(Integration_Test_Message); ok {
			g_vt_pong_received += 1
			_ = actod.send_message(from, Integration_Test_Message{id = m.id, payload = "pong"})
		}
	},
}

Vt_Ping_Data :: struct {
	target_node: string,
}

Vt_Ping_Behaviour :: actod.Actor_Behaviour(Vt_Ping_Data) {
	handle_message = proc(data: ^Vt_Ping_Data, from: actod.PID, msg: any) {
		m, ok := msg.(Integration_Test_Message)
		if !ok {
			return
		}
		if m.payload == "go" {
			for i in 0 ..< VT_PING_COUNT {
				_ = actod.send_remote_by_name(
					data.target_node,
					"vt_pong",
					Integration_Test_Message{id = i, payload = "ping"},
				)
			}
		} else {
			g_vt_replies_received += 1
		}
	},
}

@(private = "file")
run_both_until_idle :: proc(node_a, node_b: ^actod.Node_State) {
	for _ in 0 ..< 200 {
		_ = actod.sim_bind_node(node_a)
		a_steps := actod.sim_run_until_idle()
		_ = actod.sim_bind_node(node_b)
		b_steps := actod.sim_run_until_idle()
		if a_steps == 0 && b_steps == 0 {
			break
		}
	}
	_ = actod.sim_bind_node(node_a)
}

test_sim_virtual_transport :: proc(t: ^testing.T) {
	g_vt_pong_received = 0
	g_vt_replies_received = 0

	det: ti.Det_State
	det.virtual_now = time.now()
	det.virtual_tick_ns = 1
	ti.det = &det
	defer ti.det = nil

	node_a := actod.NODE

	ping_pid, ping_ok := actod.spawn(
		"vt_ping",
		Vt_Ping_Data{target_node = "sim_vt_b"},
		Vt_Ping_Behaviour,
	)
	expect(t, ping_ok, "ping spawn failed")

	node_b := actod.sim_create_node()
	_ = actod.sim_bind_node(node_b)

	opts := actod.make_node_config(
		worker_count = 2,
		sim_mode = true,
		network = actod.make_network_config(
			auth_password = "test_dist_password",
			port = 18500,
		),
		actor_config = actod.make_actor_config(logging = actod.make_log_config(level = .Warning)),
	)
	actod.node_init("sim_vt_b", opts)

	_, pong_ok := actod.spawn("vt_pong", Vt_Pong_Data{}, Vt_Pong_Behaviour)
	expect(t, pong_ok, "pong spawn failed")

	_ = actod.sim_bind_node(node_a)
	_, registered := actod.register_node(
		"sim_vt_b",
		net.Endpoint{address = net.IP4_Loopback, port = 18500},
		.TCP_Custom_Protocol,
	)
	expect(t, registered, "register_node failed")

	_ = actod.send_message(ping_pid, Integration_Test_Message{payload = "go"})
	run_both_until_idle(node_a, node_b)

	expect_value(t, g_vt_pong_received, VT_PING_COUNT)
	expect_value(t, g_vt_replies_received, VT_PING_COUNT)

	_, gossiped := actod.get_actor_pid("vt_pong@sim_vt_b")
	expect(t, gossiped, "registry snapshot did not reach node A over the virtual pipe")

	actod.sim_set_recv_chunk(3)
	_ = actod.send_message(ping_pid, Integration_Test_Message{payload = "go"})
	run_both_until_idle(node_a, node_b)
	actod.sim_set_recv_chunk(0)

	expect_value(t, g_vt_pong_received, 2 * VT_PING_COUNT)
	expect_value(t, g_vt_replies_received, 2 * VT_PING_COUNT)

	_ = actod.sim_bind_node(node_b)
	actod.node_shutdown()
	_ = actod.sim_bind_node(node_a)
	_ = actod.sim_run_until_idle()
	actod.sim_destroy_node(node_b)
}
