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

WIRE_SAFETY_PROBE :: "wire safety probe"
WIRE_SAFETY_PEER_NODE :: "LocalOnlySenderNode"

refused_add_child_logged: bool
refused_stats_response_logged: bool

spawn_func_smuggled_over_the_wire :: proc(
	name: string,
	parent: actod.PID,
) -> (
	actod.PID,
	bool,
) {
	return 0, false
}

record_refused_wire_types :: proc(
	level: log.Level,
	text: string,
	location: runtime.Source_Code_Location,
) {
	if !strings.contains(text, "only accepted from local senders") do return
	if strings.contains(text, "Refused a actod.Add_Child from node") do sync.atomic_store(&refused_add_child_logged, true)
	if strings.contains(text, "Refused a actod.Stats_Response from node") do sync.atomic_store(&refused_stats_response_logged, true)
}

Wire_Victim_Data :: struct {
	probe_arrived:          ^sync.Sema,
	forged_stats_delivered: ^bool,
}

wire_victim_behaviour := actod.Actor_Behaviour(Wire_Victim_Data) {
	handle_message = proc(data: ^Wire_Victim_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case actod.Stats_Response:
			sync.atomic_store(data.forged_stats_delivered, true)
		case string:
			if m == WIRE_SAFETY_PROBE do sync.sema_post(data.probe_arrived)
		}
	},
}

refuse_the_local_only_frames :: proc(message: actod.Inbound_Message) -> bool {
	return(
		message.type_id != actod.Add_Child &&
		message.type_id != actod.Stats_Response \
	)
}

test_peer_cannot_send_local_only_message_types :: proc(t: ^testing.T) {
	expect_local_only_frames_refused_with_a_warning(t)
}

test_local_only_frames_refused_by_the_inbound_filter_still_log_a_warning :: proc(
	t: ^testing.T,
) {
	filter_before := actod.NODE.config.network.inbound_filter
	defer actod.NODE.config.network.inbound_filter = filter_before
	actod.NODE.config.network.inbound_filter = refuse_the_local_only_frames
	expect_local_only_frames_refused_with_a_warning(t)
}

expect_local_only_frames_refused_with_a_warning :: proc(t: ^testing.T) {
	sync.atomic_store(&refused_add_child_logged, false)
	sync.atomic_store(&refused_stats_response_logged, false)

	logging_before := actod.NODE.config.actor_config.logging
	defer actod.NODE.config.actor_config.logging = logging_before
	actod.NODE.config.actor_config.logging.level = .Warning
	actod.NODE.config.actor_config.logging.custom_logger =
		record_refused_wire_types

	probe_arrived: sync.Sema
	forged_stats_delivered: bool

	victim_pid, victim_ok := actod.spawn(
		"wire_victim",
		Wire_Victim_Data {
			probe_arrived = &probe_arrived,
			forged_stats_delivered = &forged_stats_delivered,
		},
		wire_victim_behaviour,
	)
	if !expect(t, victim_ok, "Should spawn the victim supervisor") do return

	peer: Node_Role_Process
	peer_started := start_node_role(
		&peer,
		[]string {
			"ACTOD_TEST_NODE=local_only_type_sender",
			fmt.tprintf("NODE_NAME=%s", WIRE_SAFETY_PEER_NODE),
			fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
			"AUTH_PASSWORD=test_dist_password",
			"TARGET_NODE=TestNode1",
			fmt.tprintf("TARGET_PORT=%d", test_base_port),
			fmt.tprintf("VICTIM_PID=%d", u64(victim_pid)),
		},
	)
	if !expect(t, peer_started, "Failed to start the local-only type sender") do return
	defer stop_node_role(&peer)
	if !expect(t, wait_for_node_role_ready(&peer), "The sender never reported READY") do return

	probe_ok := sync.sema_wait_with_timeout(
		&probe_arrived,
		scaled_timeout(5 * time.Second),
	)
	if !expect(t, probe_ok, "The wire-safe probe sent after the refused frames never arrived") do return

	expect(
		t,
		poll_until(
			atomic_flag_raised,
			&refused_add_child_logged,
			scaled_timeout(2 * time.Second),
		),
		"The SYSTEM Add_Child frame must be refused with a log line naming Add_Child",
	)
	expect(
		t,
		poll_until(
			atomic_flag_raised,
			&refused_stats_response_logged,
			scaled_timeout(2 * time.Second),
		),
		"The Stats_Response frame must be refused with a log line naming Stats_Response",
	)
	expect(
		t,
		!sync.atomic_load(&forged_stats_delivered),
		"A Stats_Response from a peer must never reach an actor",
	)

	_ = actod.terminate_actor(victim_pid)
	time.sleep(100 * time.Millisecond)
}

run_local_only_type_sender :: proc() {
	node_name :=
		os.lookup_env(
			"NODE_NAME",
			context.temp_allocator,
		) or_else WIRE_SAFETY_PEER_NODE
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
	node_port, node_port_ok := strconv.parse_int(
		os.lookup_env("NODE_PORT", context.temp_allocator) or_else "",
	)
	target_port, target_port_ok := strconv.parse_int(
		os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "",
	)
	victim, victim_ok := strconv.parse_u64(
		os.lookup_env("VICTIM_PID", context.temp_allocator) or_else "",
	)
	if !node_port_ok || !target_port_ok || !victim_ok {
		fmt.println("NODE_PORT, TARGET_PORT and VICTIM_PID are required")
		os.exit(1)
	}

	actod.node_init(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = scaled_timeout(300 * time.Millisecond),
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = test_log_level()),
			),
		),
	)
	defer actod.shutdown_node()

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

	victim_handle, _ := actod.unpack_pid(actod.PID(victim))
	remote_victim := actod.pack_pid(victim_handle, target_id)

	smuggled_add_child := actod.Add_Child {
		spawn_func   = spawn_func_smuggled_over_the_wire,
		existing_pid = 0,
	}
	if err := actod.send_message(remote_victim, smuggled_add_child);
	   err != .OK {
		fmt.printf("Sending the Add_Child frame failed: %v\n", err)
		os.exit(1)
	}
	forged_stats := actod.Stats_Response {
		stats = {pid = remote_victim, name = "forged"},
	}
	if err := actod.send_message(remote_victim, forged_stats); err != .OK {
		fmt.printf("Sending the Stats_Response frame failed: %v\n", err)
		os.exit(1)
	}
	if err := actod.send_message(remote_victim, WIRE_SAFETY_PROBE);
	   err != .OK {
		fmt.printf("Sending the probe failed: %v\n", err)
		os.exit(1)
	}

	print_ready_once_listening()

	for {
		time.sleep(100 * time.Millisecond)
	}
}
