package integration

import "../actod"
import "base:runtime"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

STUCK_OUTGOING_ANSWERER :: "stuck_outgoing_answerer"
STUCK_OUTGOING_ASKER :: "stuck_outgoing_asker"
STUCK_OUTGOING_REDIAL_ROUNDS :: 4
STUCK_OUTGOING_REDIAL_STEP :: 3 * time.Second

@(private = "file")
g_answers: int

@(private = "file")
g_dropped_sends: int

@(private = "file")
g_asked_node: string

@(private = "file")
g_last_asker: actod.PID

@(private = "file")
g_told: actod.Send_Error

@(private = "file")
count_dropped_sends :: proc(
	level: log.Level,
	text: string,
	location: runtime.Source_Code_Location,
) {
	if strings.contains(text, "no connection to node") do sync.atomic_add(&g_dropped_sends, 1)
}

Stuck_Outgoing_Answerer_Data :: struct {}

Stuck_Outgoing_Answerer_Behaviour :: actod.Actor_Behaviour(
	Stuck_Outgoing_Answerer_Data,
) {
	handle_message = proc(
		data: ^Stuck_Outgoing_Answerer_Data,
		from: actod.PID,
		msg: any,
	) {
		m, ok := msg.(Integration_Test_Message)
		if !ok do return
		switch m.payload {
		case "question":
			g_last_asker = from
			_ = actod.send_message(
				from,
				Integration_Test_Message{id = m.id, payload = "answer"},
			)
		case "tell":
			g_told = actod.send_message(
				g_last_asker,
				Integration_Test_Message{id = m.id, payload = "answer"},
			)
		}
	},
}

Stuck_Outgoing_Asker_Data :: struct {}

Stuck_Outgoing_Asker_Behaviour :: actod.Actor_Behaviour(
	Stuck_Outgoing_Asker_Data,
) {
	handle_message = proc(
		data: ^Stuck_Outgoing_Asker_Data,
		from: actod.PID,
		msg: any,
	) {
		m, ok := msg.(Integration_Test_Message)
		if !ok do return
		switch m.payload {
		case "ask":
			_ = actod.send_remote_by_name(
				g_asked_node,
				STUCK_OUTGOING_ANSWERER,
				Integration_Test_Message{id = m.id, payload = "question"},
			)
		case "answer":
			g_answers += 1
		}
	},
}

@(private = "file")
spawn_answerer :: proc(
	t: ^testing.T,
	mesh: ^actod.Sim_Mesh,
	node: int,
) -> (
	actod.PID,
	bool,
) {
	_ = actod.sim_mesh_bind(mesh, node)
	answerer, spawned := actod.spawn(
		STUCK_OUTGOING_ANSWERER,
		Stuck_Outgoing_Answerer_Data{},
		Stuck_Outgoing_Answerer_Behaviour,
	)
	return answerer, expect(t, spawned, "the answerer spawned")
}

@(private = "file")
spawn_asker :: proc(
	t: ^testing.T,
	mesh: ^actod.Sim_Mesh,
	node: int,
	asked: int,
) -> (
	actod.PID,
	bool,
) {
	g_asked_node = actod.sim_mesh_name(mesh, asked)
	_ = actod.sim_mesh_bind(mesh, node)
	asker, spawned := actod.spawn(
		STUCK_OUTGOING_ASKER,
		Stuck_Outgoing_Asker_Data{},
		Stuck_Outgoing_Asker_Behaviour,
	)
	return asker, expect(t, spawned, "the asker spawned")
}

@(private = "file")
ask :: proc(mesh: ^actod.Sim_Mesh, node: int, asker: actod.PID, id: int) {
	_ = actod.sim_mesh_bind(mesh, node)
	_ = actod.send_message(
		asker,
		Integration_Test_Message{id = id, payload = "ask"},
	)
	for _ in 0 ..< STUCK_OUTGOING_REDIAL_ROUNDS {
		_ = actod.sim_mesh_run_until_idle(mesh)
		actod.sim_mesh_advance_clock(mesh, STUCK_OUTGOING_REDIAL_STEP)
	}
	_ = actod.sim_mesh_run_until_idle(mesh)
}

@(private = "file")
register_at :: proc(
	mesh: ^actod.Sim_Mesh,
	node: int,
	peer: int,
	port: int,
) -> (
	actod.Node_ID,
	bool,
) {
	_ = actod.sim_mesh_bind(mesh, node)
	return actod.register_node(
		actod.sim_mesh_name(mesh, peer),
		net.Endpoint{address = net.IP4_Loopback, port = port},
		.TCP_Custom_Protocol,
	)
}

test_sim_a_peer_with_no_listen_port_is_not_dialled_and_is_answered_when_it_dials_again :: proc(
	t: ^testing.T,
) {
	g_answers = 0
	g_last_asker = 0
	g_told = .OK
	sync.atomic_store(&g_dropped_sends, 0)
	mesh := actod.sim_mesh_create(
		2,
		base_port = 39800,
		log_level = test_log_level(),
		register_peers = false,
	)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	actod.NODE.config.actor_config.logging.level = .Warning
	actod.NODE.config.actor_config.logging.custom_logger = count_dropped_sends
	answerer, answerer_spawned := spawn_answerer(t, mesh, 0)
	if !answerer_spawned do return
	_ = actod.sim_mesh_bind(mesh, 1)
	actod.NODE.config.network.port = 0
	asker, asker_spawned := spawn_asker(t, mesh, 1, 0)
	if !asker_spawned do return
	_, registered := register_at(mesh, 1, 0, mesh.ports[0])
	if !expect(t, registered, "the client registered the listener") do return

	ask(mesh, 1, asker, 1)
	if !expect_value(t, g_answers, 1) do return

	_ = actod.sim_mesh_bind(mesh, 0)
	client, known := actod.get_node_by_name(actod.sim_mesh_name(mesh, 1))
	if !expect(t, known, "the listener knows the client") do return
	info, _ := actod.get_node_info(client)
	if !expect_value(t, info.address.port, 0) do return

	actod.sim_mesh_sever(mesh, 0, 1, deliver_error = true)
	_ = actod.sim_mesh_run_until_idle(mesh)
	_ = actod.sim_mesh_bind(mesh, 0)
	if !expect(t, connection_actor_of(client) == nil, "the cut session's connection actor is gone") do return

	sync.atomic_store(&g_dropped_sends, 0)
	_ = actod.send_message(
		answerer,
		Integration_Test_Message{id = 2, payload = "tell"},
	)
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, g_told, actod.Send_Error.NODE_DISCONNECTED)
	expect_value(t, sync.atomic_load(&g_dropped_sends), 1)
	_ = actod.sim_mesh_bind(mesh, 0)
	expect(
		t,
		connection_actor_of(client) == nil,
		"no connection actor dials a node with no listen port",
	)

	ask(mesh, 1, asker, 3)
	expect_value(t, g_answers, 2)
}
