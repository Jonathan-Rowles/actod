package integration

import "../actod"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

POOL_PEER_NODE :: "PoolPeerNode"
POOL_PEER_RINGS :: 3
POOL_PEER_CLOSER :: "pool_peer_closer"

End_Pool_Ring :: struct {
	index: u32,
}

@(init)
register_pool_peer_messages :: proc "contextless" () {
	actod.register_message_type(End_Pool_Ring)
}

pool_peer_recv_end_count: int

record_pool_peer_recv_end :: proc(
	level: log.Level,
	text: string,
	location: runtime.Source_Code_Location,
) {
	if location.procedure != "nbio_recv_callback" do return
	if strings.contains(text, "Connection closed by peer") ||
	   strings.contains(text, "connection lost") ||
	   strings.contains(text, "recv error") {
		sync.atomic_add(&pool_peer_recv_end_count, 1)
	}
}

pool_peer_active_rings :: proc() -> u32 {
	node_id, found := actod.get_node_by_name(POOL_PEER_NODE)
	if !found do return 0
	pool := actod.get_connection_pool(node_id)
	if pool == nil do return 0
	return actod.pool_active_count(pool)
}

pool_adopted_rings :: proc(state: rawptr) -> bool {
	return pool_peer_active_rings() >= POOL_PEER_RINGS
}

pool_dropped_a_ring :: proc(state: rawptr) -> bool {
	return pool_peer_active_rings() < POOL_PEER_RINGS
}

test_pool_peer_ring_reports_its_close_once :: proc(t: ^testing.T) {
	sync.atomic_store(&pool_peer_recv_end_count, 0)

	logging_before := actod.NODE.config.actor_config.logging
	defer actod.NODE.config.actor_config.logging = logging_before
	actod.NODE.config.actor_config.logging.level = .Info
	actod.NODE.config.actor_config.logging.custom_logger =
		record_pool_peer_recv_end

	peer: Node_Role_Process
	peer_started := start_node_role(
		&peer,
		[]string {
			"ACTOD_TEST_NODE=pool_peer",
			"AUTH_PASSWORD=test_dist_password",
			"TARGET_NODE=TestNode1",
			fmt.tprintf("TARGET_PORT=%d", test_base_port),
		},
	)
	if !expect(t, peer_started, "Failed to start the pool peer") do return
	defer stop_node_role(&peer)
	if !expect(t, wait_for_node_role_ready(&peer), "The pool peer never reported READY") do return

	adopted := poll_until(pool_adopted_rings, nil, 5 * time.Second)
	if !expectf(t, adopted, "The session should hold %d rings before the peer closes one", POOL_PEER_RINGS) do return

	dropped := false
	for _ in 0 ..< scaled_attempts(100) {
		sent := actod.send_to(
			POOL_PEER_CLOSER,
			POOL_PEER_NODE,
			End_Pool_Ring{index = POOL_PEER_RINGS - 1},
		)
		if !expectf(t, sent == .OK, "Asking the peer to close a pool ring failed: %v", sent) do return
		dropped = poll_until(pool_dropped_a_ring, nil, 50 * time.Millisecond)
		if dropped do break
	}
	if !expect(t, dropped, "The session never let go of the ring the peer closed") do return
	expectf(
		t,
		sync.atomic_load(&pool_peer_recv_end_count) == 1,
		"The ring the peer closed should report its close once, %d reports came",
		sync.atomic_load(&pool_peer_recv_end_count),
	)

	node_id, _ := actod.get_node_by_name(POOL_PEER_NODE)
	_ = os.process_kill(peer.process)

	closed := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < scaled_timeout(5 * time.Second) {
		if sync.atomic_load_explicit(
			   cast(^u64)&actod.NODE.connection_actors[node_id],
			   .Acquire,
		   ) ==
		   0 {
			closed = true
			break
		}
		time.sleep(50 * time.Microsecond)
	}
	if !expect(t, closed, "The session never closed after the peer went away") do return
	expectf(
		t,
		sync.atomic_load(&pool_peer_recv_end_count) <= POOL_PEER_RINGS,
		"Each of the %d rings should report the end of its recv once, %d reports came",
		POOL_PEER_RINGS,
		sync.atomic_load(&pool_peer_recv_end_count),
	)
}

Pool_Peer_Closer :: struct {
	target_id: actod.Node_ID,
}

Pool_Peer_Closer_Behaviour :: actod.Actor_Behaviour(Pool_Peer_Closer) {
	handle_message = proc(
		data: ^Pool_Peer_Closer,
		from: actod.PID,
		content: any,
	) {
		end, is_end := content.(End_Pool_Ring)
		if !is_end do return
		pool := actod.get_connection_pool(data.target_id)
		if pool == nil do return
		ring := actod.get_pool_ring_at(pool, end.index)
		if ring == nil do return
		_ = net.shutdown(ring.tcp_socket, .Send)
	},
}

run_pool_peer :: proc() {
	auth_password :=
		os.lookup_env(
			"AUTH_PASSWORD",
			context.temp_allocator,
		) or_else "test_dist_password"
	target_node :=
		os.lookup_env(
			"TARGET_NODE",
			context.temp_allocator,
		) or_else "TestNode1"
	target_port, target_port_ok := strconv.parse_int(
		os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "",
	)
	if !target_port_ok {
		fmt.println("TARGET_PORT is required")
		os.exit(1)
	}

	ring_config := actod.DEFAULT_CONNECTION_RING_CONFIG
	ring_config.max_pool_rings = POOL_PEER_RINGS

	actod.node_init(
		name = POOL_PEER_NODE,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = 0,
				auth_password = auth_password,
				connection_ring = ring_config,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = scaled_timeout(300 * time.Millisecond),
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = test_log_level()),
			),
		),
	)

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	target_id, registered := actod.register_node(
		target_node,
		target_addr,
		.TCP_Custom_Protocol,
		connect = true,
	)
	if !registered || !wait_for_connection_ready(target_node) {
		fmt.println("Could not connect to the target node")
		os.exit(1)
	}

	pool := actod.get_connection_pool(target_id)
	for _ in 0 ..< scaled_attempts(50) {
		if pool != nil && actod.pool_active_count(pool) >= POOL_PEER_RINGS do break
		conn_pid := actod.PID(
			sync.atomic_load(
				cast(^u64)&actod.NODE.connection_actors[target_id],
			),
		)
		if conn_pid != 0 do _ = actod.send_message(conn_pid, actod.Scale_Up_Request{})
		time.sleep(50 * time.Millisecond)
	}
	if pool == nil || actod.pool_active_count(pool) < POOL_PEER_RINGS {
		fmt.println("The pool never reached its rings")
		os.exit(1)
	}

	_, closer_spawned := actod.spawn(
		POOL_PEER_CLOSER,
		Pool_Peer_Closer{target_id = target_id},
		Pool_Peer_Closer_Behaviour,
	)
	if !closer_spawned {
		fmt.println("Failed to spawn the pool ring closer")
		os.exit(1)
	}

	fmt.println("READY")
	for {
		time.sleep(time.Second)
	}
}
