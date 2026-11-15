package integration

import "../actod"
import "base:runtime"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

SELF_DIAL_PORT :: 37130
SELF_DIAL_RECONNECT_DELAYS :: 10
SELF_DIAL_RECONNECT_DELAY :: 2 * time.Second

self_dial_arrivals: int

count_self_dial_arrivals :: proc(
	level: log.Level,
	text: string,
	location: runtime.Source_Code_Location,
) {
	if strings.contains(text, "this node's own name") do sync.atomic_add(&self_dial_arrivals, 1)
}

expect_no_redial :: proc(
	t: ^testing.T,
	mesh: ^actod.Sim_Mesh,
	arrivals_before: int,
) -> bool {
	for _ in 0 ..< SELF_DIAL_RECONNECT_DELAYS {
		actod.sim_mesh_advance_clock(
			mesh,
			SELF_DIAL_RECONNECT_DELAY + time.Second,
		)
		_ = actod.sim_mesh_run_until_idle(mesh)
	}
	_ = actod.sim_mesh_bind(mesh, 0)
	return expectf(
		t,
		sync.atomic_load(&self_dial_arrivals) == arrivals_before,
		"%d reconnect delays after a dial that reached this node, it was refused %d times more",
		SELF_DIAL_RECONNECT_DELAYS,
		sync.atomic_load(&self_dial_arrivals) - arrivals_before,
	)
}

test_sim_a_node_that_dials_itself_stops_redialing :: proc(t: ^testing.T) {
	sync.atomic_store(&self_dial_arrivals, 0)
	mesh := actod.sim_mesh_create(
		1,
		base_port = SELF_DIAL_PORT,
		auth_password = "self dial",
		log_level = test_log_level(),
	)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 0)
	actod.NODE.config.actor_config.logging.level = .Warning
	actod.NODE.config.actor_config.logging.custom_logger =
		count_self_dial_arrivals
	alias, registered := actod.register_node(
		"an alias for this node",
		net.Endpoint{address = net.IP4_Loopback, port = SELF_DIAL_PORT},
		.TCP_Custom_Protocol,
		connect = true,
	)
	if !expect(t, registered, "the alias registered") do return
	_ = actod.sim_mesh_run_until_idle(mesh)
	arrivals_after_first_dial := sync.atomic_load(&self_dial_arrivals)
	if !expect(t, arrivals_after_first_dial > 0, "the first dial reached this node and was refused") do return

	if !expect_no_redial(t, mesh, arrivals_after_first_dial) do return

	connection := connection_actor_of(alias)
	if !expect(t, connection != nil, "the alias has a connection actor") do return
	asked := actod.send_message(
		connection.pid,
		actod.Reconnect{delay = SELF_DIAL_RECONNECT_DELAY},
	)
	if !expect(t, asked == .OK, "the reconnect reached the connection actor") do return
	_ = actod.sim_mesh_run_until_idle(mesh)
	actod.sim_mesh_advance_clock(mesh, SELF_DIAL_RECONNECT_DELAY + time.Second)
	_ = actod.sim_mesh_run_until_idle(mesh)
	arrivals_after_timer := sync.atomic_load(&self_dial_arrivals)
	if !expect(t, arrivals_after_timer > arrivals_after_first_dial, "the reconnect timer's dial reached this node and was refused") do return
	if !expect_no_redial(t, mesh, arrivals_after_timer) do return

	_ = actod.sim_mesh_bind(mesh, 0)
	ring := actod.get_connection_ring(alias)
	expect(
		t,
		ring == nil || sync.atomic_load(&ring.state) != .Ready,
		"a connection that reached this node is not left up",
	)
	expect(
		t,
		connection_actor_of(alias) != nil,
		"the connection actor stays, so a later send can ask it to dial again",
	)
}
