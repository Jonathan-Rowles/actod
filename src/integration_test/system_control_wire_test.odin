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

SYSTEM_CONTROL_PEER_NODE :: "SystemControlSender"
SYSTEM_CONTROL_PROBE :: "system control probe"
SYSTEM_CONTROL_FORGED_FROM_PROBE :: "system control forged from probe"
SYSTEM_CONTROL_VICTIM_NAME :: "control_victim"

Refused_Wire_Shape :: struct {
	log_text: string,
	logged:   bool,
}

refused_wire_shapes := [?]Refused_Wire_Shape {
	{log_text = "Refused a actod.Rename_Actor from node"},
	{log_text = "Refused a actod.Reload_Behaviour from node"},
	{log_text = "Refused a actod.Start_Timer from node"},
	{log_text = "Refused a actod.Cancel_All_Timers from node"},
	{log_text = "Refused a actod.Get_Stats from node"},
	{log_text = "Refused a actod.Remove_Child from node"},
	{log_text = "Refused a actod.Connect_Request from node"},
	{log_text = "Refused a actod.Close_Connection from node"},
	{log_text = "Refused a actod.Remote_Message from node"},
}

refused_actor_stopped_count: int

record_refused_system_control :: proc(
	level: log.Level,
	text: string,
	location: runtime.Source_Code_Location,
) {
	if !strings.contains(text, SYSTEM_CONTROL_PEER_NODE) do return
	if strings.contains(text, "Refused a actod.Actor_Stopped from node") {
		sync.atomic_add(&refused_actor_stopped_count, 1)
		return
	}
	for &shape in refused_wire_shapes {
		if strings.contains(text, shape.log_text) do sync.atomic_store(&shape.logged, true)
	}
}

Control_Victim_Data :: struct {
	probe_arrived:        ^sync.Sema,
	forged_from_arrived:  ^sync.Sema,
	forged_from_was_peer: ^bool,
}

control_victim_behaviour := actod.Actor_Behaviour(Control_Victim_Data) {
	handle_message = proc(
		data: ^Control_Victim_Data,
		from: actod.PID,
		msg: any,
	) {
		text, is_text := msg.(string)
		if !is_text do return
		switch text {
		case SYSTEM_CONTROL_PROBE:
			sync.sema_post(data.probe_arrived)
		case SYSTEM_CONTROL_FORGED_FROM_PROBE:
			from_is_peer :=
				!actod.is_local_pid(from) &&
				actod.get_actor_name(from) == "<unknown>"
			sync.atomic_store(data.forged_from_was_peer, from_is_peer)
			sync.sema_post(data.forged_from_arrived)
		}
	},
}

all_refused_wire_shapes_logged :: proc(state: rawptr) -> bool {
	for &shape in refused_wire_shapes {
		if !sync.atomic_load(&shape.logged) do return false
	}
	return true
}

test_peer_cannot_address_system_control_messages :: proc(t: ^testing.T) {
	logging_before := actod.NODE.config.actor_config.logging
	defer actod.NODE.config.actor_config.logging = logging_before
	actod.NODE.config.actor_config.logging.level = .Warning
	actod.NODE.config.actor_config.logging.custom_logger =
		record_refused_system_control

	probe_arrived: sync.Sema
	forged_from_arrived: sync.Sema
	forged_from_was_peer: bool

	victim_pid, victim_ok := actod.spawn(
		SYSTEM_CONTROL_VICTIM_NAME,
		Control_Victim_Data {
			probe_arrived = &probe_arrived,
			forged_from_arrived = &forged_from_arrived,
			forged_from_was_peer = &forged_from_was_peer,
		},
		control_victim_behaviour,
	)
	if !expect(t, victim_ok, "Should spawn the victim actor") do return

	peer: Node_Role_Process
	peer_started := start_node_role(
		&peer,
		[]string {
			"ACTOD_TEST_NODE=system_control_sender",
			fmt.tprintf("NODE_NAME=%s", SYSTEM_CONTROL_PEER_NODE),
			fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
			"AUTH_PASSWORD=test_dist_password",
			"TARGET_NODE=TestNode1",
			fmt.tprintf("TARGET_PORT=%d", test_base_port),
			fmt.tprintf("VICTIM_PID=%d", u64(victim_pid)),
			fmt.tprintf("TARGET_NODE_PID=%d", u64(actod.get_local_node_pid())),
		},
	)
	if !expect(t, peer_started, "Failed to start the system control sender") do return
	defer stop_node_role(&peer)
	if !expect(t, wait_for_node_role_ready(&peer), "The sender never reported READY") do return

	forged_ok := sync.sema_wait_with_timeout(
		&forged_from_arrived,
		scaled_timeout(5 * time.Second),
	)
	expect(t, forged_ok, "The probe with a forged from_handle never arrived")
	expect(
		t,
		sync.atomic_load(&forged_from_was_peer),
		"A from_handle naming a local actor must arrive as a pid of the peer node that resolves to no local actor",
	)

	probe_ok := sync.sema_wait_with_timeout(
		&probe_arrived,
		scaled_timeout(5 * time.Second),
	)
	if !expect(t, probe_ok, "The probe sent after the refused frames never arrived") do return

	expect(
		t,
		poll_until(
			all_refused_wire_shapes_logged,
			nil,
			scaled_timeout(2 * time.Second),
		),
		"Every refused system control frame must be logged with its type and the peer",
	)
	for &shape in refused_wire_shapes {
		expect(
			t,
			sync.atomic_load(&shape.logged),
			fmt.tprintf("missing log line: %s", shape.log_text),
		)
	}
	expect(
		t,
		sync.atomic_load(&refused_actor_stopped_count) == 0,
		fmt.tprintf(
			"Actor_Stopped is accepted from a peer for any actor, yet %d were refused",
			sync.atomic_load(&refused_actor_stopped_count),
		),
	)
	expect(
		t,
		actod.get_actor_name(victim_pid) == SYSTEM_CONTROL_VICTIM_NAME,
		"The victim must still be alive under its own name",
	)

	_ = actod.terminate_actor(victim_pid)
	time.sleep(100 * time.Millisecond)
}

run_system_control_sender :: proc() {
	node_name :=
		os.lookup_env(
			"NODE_NAME",
			context.temp_allocator,
		) or_else SYSTEM_CONTROL_PEER_NODE
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
	target_node_pid, target_node_pid_ok := strconv.parse_u64(
		os.lookup_env("TARGET_NODE_PID", context.temp_allocator) or_else "",
	)
	if !node_port_ok || !target_port_ok || !victim_ok || !target_node_pid_ok {
		fmt.println(
			"NODE_PORT, TARGET_PORT, VICTIM_PID and TARGET_NODE_PID are required",
		)
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
	node_handle, _ := actod.unpack_pid(actod.PID(target_node_pid))
	remote_node := actod.pack_pid(node_handle, target_id)
	own_connection_on_target := fmt.tprintf("%s_connection", node_name)

	forged_stop := actod.Actor_Stopped {
		child_pid  = remote_victim,
		reason     = .ABNORMAL,
		child_name = "forged",
	}

	require_sent(
		actod.send_message(
			remote_victim,
			actod.Rename_Actor{new_name = "renamed_by_peer"},
		),
		"Rename_Actor",
	)
	require_sent(
		actod.send_message(
			remote_victim,
			actod.Reload_Behaviour{generation = 1},
		),
		"Reload_Behaviour",
	)
	require_sent(
		actod.send_message(
			remote_victim,
			actod.Get_Stats{requester = remote_victim},
		),
		"Get_Stats",
	)
	require_sent(
		actod.send_message(
			remote_victim,
			actod.Remove_Child{child_pid = remote_victim},
		),
		"Remove_Child",
	)
	require_sent(
		actod.send_message(remote_victim, forged_stop),
		"Actor_Stopped to the victim",
	)
	require_sent(
		actod.send_message(remote_node, forged_stop),
		"Actor_Stopped to the node",
	)
	require_sent(
		actod.send_remote_by_name(
			target_node,
			"timer",
			actod.Start_Timer {
				id = 1,
				interval = 10 * time.Millisecond,
				repeat = true,
			},
		),
		"Start_Timer",
	)
	require_sent(
		actod.send_remote_by_name(
			target_node,
			"timer",
			actod.Cancel_All_Timers{owner = remote_victim},
		),
		"Cancel_All_Timers",
	)
	require_sent(
		actod.send_remote_by_name(
			target_node,
			own_connection_on_target,
			actod.Connect_Request{node_id = target_id, address = target_addr},
		),
		"Connect_Request",
	)
	require_sent(
		actod.send_remote_by_name(
			target_node,
			own_connection_on_target,
			actod.Close_Connection{reason = "forged"},
		),
		"Close_Connection",
	)
	forged_frame := [?]u8{0, 0, 0, 0}
	require_sent(
		actod.send_remote_by_name(
			target_node,
			own_connection_on_target,
			actod.Remote_Message{from = remote_victim, data = forged_frame[:]},
		),
		"Remote_Message",
	)

	ring := actod.get_connection_ring(target_id)
	if ring == nil {
		fmt.println("No connection ring to the target node")
		os.exit(1)
	}
	append_forged_from_frame(
		ring,
		forged_stop,
		node_handle,
		victim_handle,
		{.SYSTEM},
		"Actor_Stopped with a forged from_handle",
	)
	append_forged_from_frame(
		ring,
		SYSTEM_CONTROL_FORGED_FROM_PROBE,
		victim_handle,
		victim_handle,
		{},
		"forged from probe",
	)

	require_sent(
		actod.send_message(remote_victim, SYSTEM_CONTROL_PROBE),
		"probe",
	)

	print_ready_once_listening()

	for {
		time.sleep(100 * time.Millisecond)
	}
}

require_sent :: proc(err: actod.Send_Error, what: string) {
	if err == .OK do return
	fmt.printf("Sending the %s frame failed: %v\n", what, err)
	os.exit(1)
}

append_forged_from_frame :: proc(
	ring: ^actod.Connection_Ring,
	content: $T,
	to_handle: actod.Handle,
	from_handle: actod.Handle,
	flags: actod.Network_Message_Flags,
	what: string,
) {
	frame: [512]byte
	frame_len := actod.build_wire_format_into_buffer(
		frame[:],
		content,
		to_handle,
		from_handle,
		flags,
		"",
	)
	if frame_len == 0 ||
	   !actod.batch_append_message_retry(ring, frame[:frame_len]) {
		fmt.printf("Appending the %s frame failed\n", what)
		os.exit(1)
	}
}
