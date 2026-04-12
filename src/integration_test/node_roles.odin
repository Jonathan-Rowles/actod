package integration

import "../actod"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "network/shared"

log_level :: log.Level.Fatal


run_node_role :: proc(command: string) {
	switch command {
	case "send_once":
		run_send_once()
	case "send_burst":
		run_send_burst()
	case "relay_node":
		run_relay_node()
	case "echo_back":
		run_echo_back()
	case "concurrent_echo":
		run_concurrent_echo()
	case "lifecycle_server":
		run_lifecycle_server()
	case "lifecycle_broadcast":
		run_lifecycle_broadcast()
	case "registry_exchange":
		run_registry_exchange()
	case "supervision_server":
		run_supervision_server()
	case "mesh_middle":
		run_mesh_middle()
	case "mesh_leaf":
		run_mesh_leaf()
	case "pubsub_subscriber":
		run_pubsub_subscriber()
	case "union_sender":
		run_union_sender()
	case:
		fmt.eprintf("Unknown node role: %s\n", command)
		os.exit(1)
	}
}

run_send_once :: proc() {
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "16001"
	target_actor := os.lookup_env("TARGET_ACTOR", context.temp_allocator) or_else "dist_receiver"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"

	target_port := 16001
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	actod.NODE_INIT(
		name = "SendOnceNode",
		opts = actod.make_node_config(
			network = actod.make_network_config(port = 0, auth_password = auth_password),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}

	_, ok := actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)
	if !ok {
		fmt.println("Failed to register target node")
		os.exit(1)
	}

	time.sleep(250 * time.Millisecond)

	msg := shared.make_two_node_message(1, "Hello from send-once mode", "SendOnceNode")

	err := actod.send_to(target_actor, target_node, msg)
	if err != .OK {
		fmt.printf("Failed to send message: %v\n", err)
		os.exit(1)
	}

	time.sleep(250 * time.Millisecond)

	actod.SHUTDOWN_NODE()
	os.exit(0)
}

run_send_burst :: proc() {
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "16001"
	target_actor := os.lookup_env("TARGET_ACTOR", context.temp_allocator) or_else "burst_receiver"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	message_count_str := os.lookup_env("MESSAGE_COUNT", context.temp_allocator) or_else "1000"

	target_port := 16001
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	message_count := 1000
	if count_val, ok := strconv.parse_int(message_count_str); ok {
		message_count = count_val
	}

	actod.NODE_INIT(
		name = "BurstSenderNode",
		opts = actod.make_node_config(
			network = actod.make_network_config(port = 0, auth_password = auth_password),
		),
	)

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}

	_, ok := actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)
	if !ok {
		fmt.println("Failed to register target node")
		os.exit(1)
	}

	time.sleep(500 * time.Millisecond)

	Burst_Sender_Data :: struct {
		target_node:   string,
		target_actor:  string,
		message_count: int,
		done:          ^sync.Sema,
	}

	Burst_Sender_Behaviour :: actod.Actor_Behaviour(Burst_Sender_Data) {
		init = proc(data: ^Burst_Sender_Data) {
			for i in 0 ..< data.message_count {
				msg_content := fmt.tprintf("Burst msg %d", i)
				msg := shared.make_two_node_message(i, msg_content, "BurstSenderNode")
				delete(msg_content)

				err := actod.send_to(data.target_actor, data.target_node, msg)
				if err != .OK {
					fmt.printf("Failed to send message %d: %v\n", i, err)
					break
				}

				if i % 10 == 0 && i > 0 {
					time.sleep(5 * time.Millisecond)
				}
			}

			if data.done != nil {
				sync.sema_post(data.done)
			}
		},
		handle_message = proc(data: ^Burst_Sender_Data, from: actod.PID, msg: any) {},
	}

	done_sema := sync.Sema{}
	sender_data := Burst_Sender_Data {
		target_node   = target_node,
		target_actor  = target_actor,
		message_count = message_count,
		done          = &done_sema,
	}
	_, spawn_ok := actod.spawn("burst_sender", sender_data, Burst_Sender_Behaviour)
	if !spawn_ok {
		fmt.println("Failed to spawn burst sender")
		os.exit(1)
	}

	sync.sema_wait(&done_sema)

	wait_time := max(1, message_count / 1000)
	time.sleep(time.Duration(wait_time) * time.Second)

	actod.SHUTDOWN_NODE()
	os.exit(0)
}

run_relay_node :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "RelayNode2"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "16002"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "RelayNode3"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "16003"

	node_port := 16002
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	target_port := 16003
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	Relay_Actor_Data :: struct {
		node_name:   string,
		target_node: string,
	}

	Relay_Actor_Behaviour :: actod.Actor_Behaviour(Relay_Actor_Data) {
		handle_message = proc(data: ^Relay_Actor_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Request:
				new_req := shared.Network_Test_Request {
					id      = m.id + 1,
					message = m.message,
				}
				err := actod.send_to("relay_actor", data.target_node, new_req)
				if err == .OK {
					fmt.printf("[%s] Forwarded request to %s\n", data.node_name, data.target_node)
				}
			}
		},
	}

	relay_data := Relay_Actor_Data {
		node_name   = node_name,
		target_node = target_node,
	}
	_, ok := actod.spawn("relay_actor", relay_data, Relay_Actor_Behaviour)
	if !ok {
		fmt.println("Failed to spawn relay actor")
		return
	}
	for {
		time.sleep(250 * time.Millisecond)
	}
}

run_echo_back :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "RelayNode3"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "16003"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	echo_to_node := os.lookup_env("ECHO_TO_NODE", context.temp_allocator) or_else "TestNode1"
	echo_to_port_str := os.lookup_env("ECHO_TO_PORT", context.temp_allocator) or_else "16001"
	echo_to_actor := os.lookup_env("ECHO_TO_ACTOR", context.temp_allocator) or_else "origin_actor"

	node_port := 16003
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	echo_to_port := 16001
	if port_val, ok := strconv.parse_int(echo_to_port_str); ok {
		echo_to_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	echo_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = echo_to_port,
	}
	actod.register_node(echo_to_node, echo_addr, .TCP_Custom_Protocol)

	Echo_Back_Data :: struct {
		node_name:     string,
		echo_to_node:  string,
		echo_to_actor: string,
	}

	Echo_Back_Behaviour :: actod.Actor_Behaviour(Echo_Back_Data) {
		handle_message = proc(data: ^Echo_Back_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Request:
				echo_msg := fmt.tprintf("Echo: %s", m.message)
				defer delete(echo_msg)

				echo_resp := shared.Network_Test_Response {
					id        = m.id + 100,
					message   = echo_msg,
					from_node = data.node_name,
				}
				err := actod.send_to(data.echo_to_actor, data.echo_to_node, echo_resp)
				if err == .OK {
					fmt.printf(
						"[%s] Sent echo back to %s/%s\n",
						data.node_name,
						data.echo_to_node,
						data.echo_to_actor,
					)
				}
			}
		},
	}

	echo_data := Echo_Back_Data {
		node_name     = node_name,
		echo_to_node  = echo_to_node,
		echo_to_actor = echo_to_actor,
	}
	_, ok := actod.spawn("relay_actor", echo_data, Echo_Back_Behaviour)
	if !ok {
		fmt.println("Failed to spawn echo back actor")
		return
	}

	for {
		time.sleep(250 * time.Millisecond)
	}
}

run_concurrent_echo :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "ConcurrentNode"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "16002"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	echo_count_str := os.lookup_env("ECHO_COUNT", context.temp_allocator) or_else "3"

	node_port := 16002
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	echo_count := 3
	if count_val, ok := strconv.parse_int(echo_count_str); ok {
		echo_count = count_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	Concurrent_Echo_Data :: struct {
		actor_name:     string,
		received_count: int,
	}

	Concurrent_Echo_Behaviour :: actod.Actor_Behaviour(Concurrent_Echo_Data) {
		handle_message = proc(data: ^Concurrent_Echo_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Distributed_Echo_Request:
				data.received_count += 1
				response := shared.Distributed_Echo_Response {
					id         = m.id,
					message    = m.message,
					from_actor = data.actor_name,
				}

				target := m.reply_to if m.reply_to != 0 else from
				actod.send_message(target, response)
			}
		},
	}

	for i in 0 ..< echo_count {
		actor_name := fmt.tprintf("echo_actor_%d", i)
		echo_data := Concurrent_Echo_Data {
			actor_name = strings.clone(actor_name),
		}

		_, ok := actod.spawn(actor_name, echo_data, Concurrent_Echo_Behaviour)
		if !ok {
			fmt.printf("Failed to spawn echo actor %s\n", actor_name)
			return
		}
		delete(actor_name)
	}

	for {
		time.sleep(250 * time.Millisecond)
	}
}

run_lifecycle_server :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "LifecycleNode"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "16010"
	auth_password := os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_password"
	heartbeat_interval_str :=
		os.lookup_env("HEARTBEAT_INTERVAL_MS", context.temp_allocator) or_else "1000"
	heartbeat_timeout_str :=
		os.lookup_env("HEARTBEAT_TIMEOUT_MS", context.temp_allocator) or_else "3000"
	reconnect_initial_str :=
		os.lookup_env("RECONNECT_INITIAL_MS", context.temp_allocator) or_else "2000"
	reconnect_retry_str :=
		os.lookup_env("RECONNECT_RETRY_MS", context.temp_allocator) or_else "3000"
	reply_to_actor := os.lookup_env("REPLY_TO_ACTOR", context.temp_allocator) or_else ""
	reply_to_node := os.lookup_env("REPLY_TO_NODE", context.temp_allocator) or_else ""
	reply_to_port_str := os.lookup_env("REPLY_TO_PORT", context.temp_allocator) or_else "16001"

	node_port := 16010
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	heartbeat_interval := 1000
	if val, ok := strconv.parse_int(heartbeat_interval_str); ok {
		heartbeat_interval = val
	}

	heartbeat_timeout := 3000
	if val, ok := strconv.parse_int(heartbeat_timeout_str); ok {
		heartbeat_timeout = val
	}

	reconnect_initial := 2000
	if val, ok := strconv.parse_int(reconnect_initial_str); ok {
		reconnect_initial = val
	}

	reconnect_retry := 3000
	if val, ok := strconv.parse_int(reconnect_retry_str); ok {
		reconnect_retry = val
	}

	reply_to_port := 16001
	if val, ok := strconv.parse_int(reply_to_port_str); ok {
		reply_to_port = val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = time.Duration(heartbeat_interval) * time.Millisecond,
				heartbeat_timeout = time.Duration(heartbeat_timeout) * time.Millisecond,
				reconnect_initial_delay = time.Duration(reconnect_initial) * time.Millisecond,
				reconnect_retry_delay = time.Duration(reconnect_retry) * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	if reply_to_node != "" {
		reply_addr := net.Endpoint {
			address = net.IP4_Loopback,
			port    = reply_to_port,
		}
		actod.register_node(reply_to_node, reply_addr, .TCP_Custom_Protocol)
	}

	Lifecycle_Echo_Data :: struct {
		name:           string,
		reply_to_actor: string,
		reply_to_node:  string,
		received_count: int,
	}

	Lifecycle_Echo_Behaviour :: actod.Actor_Behaviour(Lifecycle_Echo_Data) {
		handle_message = proc(data: ^Lifecycle_Echo_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Request:
				data.received_count += 1
				response := shared.Network_Test_Response {
					id        = m.id,
					message   = m.message,
					from_node = data.name,
				}
				if data.reply_to_actor != "" && data.reply_to_node != "" {
					actod.send_to(data.reply_to_actor, data.reply_to_node, response)
				} else {
					actod.send_message(from, response)
				}
			}
		},
	}

	echo_data := Lifecycle_Echo_Data {
		name           = node_name,
		reply_to_actor = reply_to_actor,
		reply_to_node  = reply_to_node,
	}
	_, ok := actod.spawn("lifecycle_echo", echo_data, Lifecycle_Echo_Behaviour)
	if !ok {
		fmt.println("Failed to spawn lifecycle echo actor")
		os.exit(1)
	}

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

run_lifecycle_broadcast :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "BroadcastNode"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "16050"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "16001"

	node_port := 16050
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	target_port := 16001
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	time.sleep(250 * time.Millisecond)

	Broadcast_Test_Data :: struct {
		name: string,
	}

	Broadcast_Test_Behaviour :: actod.Actor_Behaviour(Broadcast_Test_Data) {
		handle_message = proc(data: ^Broadcast_Test_Data, from: actod.PID, msg: any) {},
	}

	_, ok := actod.spawn(
		"broadcast_test_actor",
		Broadcast_Test_Data{name = node_name},
		Broadcast_Test_Behaviour,
	)
	if !ok {
		fmt.println("Failed to spawn broadcast_test_actor")
		os.exit(1)
	}

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

run_registry_exchange :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "RegistryNode"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "16060"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "16001"

	node_port := 16060
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	target_port := 16001
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	Registry_Exchange_Data :: struct {
		name: string,
	}

	Registry_Exchange_Behaviour :: actod.Actor_Behaviour(Registry_Exchange_Data) {
		handle_message = proc(data: ^Registry_Exchange_Data, from: actod.PID, msg: any) {},
	}

	_, ok1 := actod.spawn(
		"pre_existing_actor_1",
		Registry_Exchange_Data{name = "actor1"},
		Registry_Exchange_Behaviour,
	)
	if !ok1 {
		fmt.println("Failed to spawn pre_existing_actor_1")
		os.exit(1)
	}

	_, ok2 := actod.spawn(
		"pre_existing_actor_2",
		Registry_Exchange_Data{name = "actor2"},
		Registry_Exchange_Behaviour,
	)
	if !ok2 {
		fmt.println("Failed to spawn pre_existing_actor_2")
		os.exit(1)
	}

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

Supervision_Worker_Data :: struct {
	name: string,
}

Supervision_Worker_Behaviour :: actod.Actor_Behaviour(Supervision_Worker_Data) {
	handle_message = proc(data: ^Supervision_Worker_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case shared.Supervision_Crash_Command:
			actod.self_terminate(m.reason)
		case shared.Supervision_Ping:
			response := shared.Supervision_Pong {
				id        = m.id,
				from_name = data.name,
			}
			actod.send_message(from, response)
		}
	},
}

spawn_supervision_worker :: proc(name: string, parent_pid: actod.PID) -> (actod.PID, bool) {
	data := Supervision_Worker_Data {
		name = name,
	}
	return actod.spawn(name, data, Supervision_Worker_Behaviour, parent_pid = parent_pid)
}

run_supervision_server :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "SupervisionNode"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "17100"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "17090"

	node_port := 17100
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	target_port := 17090
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	actod.register_spawn_func("supervision_worker", spawn_supervision_worker)

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

run_mesh_middle :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "MeshNodeB"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "17152"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "17151"

	node_port := 17152
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	target_port := 17151
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

run_mesh_leaf :: proc() {
	node_name := os.lookup_env("NODE_NAME", context.temp_allocator) or_else "MeshNodeC"
	node_port_str := os.lookup_env("NODE_PORT", context.temp_allocator) or_else "17153"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "MeshNodeB"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "17152"

	node_port := 17153
	if port_val, ok := strconv.parse_int(node_port_str); ok {
		node_port = port_val
	}

	target_port := 17152
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	shared.check_port_available(node_port)

	actod.NODE_INIT(
		name = node_name,
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = node_port,
				auth_password = auth_password,
				heartbeat_interval = 100 * time.Millisecond,
				heartbeat_timeout = 300 * time.Millisecond,
			),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	time.sleep(250 * time.Millisecond)

	Mesh_Leaf_Data :: struct {
		name: string,
	}

	Mesh_Leaf_Behaviour :: actod.Actor_Behaviour(Mesh_Leaf_Data) {
		handle_message = proc(data: ^Mesh_Leaf_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Request:
				response := shared.Network_Test_Response {
					id        = m.id,
					message   = m.message,
					from_node = data.name,
				}
				actod.send_message(from, response)
			}
		},
	}

	_, ok := actod.spawn("mesh_actor", Mesh_Leaf_Data{name = node_name}, Mesh_Leaf_Behaviour)
	if !ok {
		fmt.println("Failed to spawn mesh_actor")
		os.exit(1)
	}

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

run_pubsub_subscriber :: proc() {
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "17160"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"
	ack_actor := os.lookup_env("ACK_ACTOR", context.temp_allocator) or_else "pubsub_ack_collector"
	subscriber_count_str := os.lookup_env("SUBSCRIBER_COUNT", context.temp_allocator) or_else "5"

	target_port := 17160
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	subscriber_count := 5
	if count_val, ok := strconv.parse_int(subscriber_count_str); ok {
		subscriber_count = count_val
	}

	actod.NODE_INIT(
		name = "PubsubNode",
		opts = actod.make_node_config(
			network = actod.make_network_config(port = 0, auth_password = auth_password),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)
	defer actod.SHUTDOWN_NODE()

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}
	actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)

	PUBLISHER_TYPE, _ := actod.register_actor_type("pubsub_broadcast_publisher")

	actod.send_to("_", target_node, shared.Pubsub_Broadcast_Msg{})
	for _ in 0 ..< 50 {
		target_node_id, found := actod.get_node_by_name(target_node)
		if found {
			ring := actod.get_connection_ring(target_node_id)
			if ring != nil && ring.state == .Ready {
				break
			}
		}
		time.sleep(100 * time.Millisecond)
	}

	Pubsub_Sub_Data :: struct {
		subscriber_id:  int,
		ack_actor:      string,
		target_node:    string,
		publisher_type: actod.Actor_Type,
	}

	Pubsub_Sub_Behaviour :: actod.Actor_Behaviour(Pubsub_Sub_Data) {
		init = proc(data: ^Pubsub_Sub_Data) {
			actod.subscribe_type(data.publisher_type)
		},
		handle_message = proc(data: ^Pubsub_Sub_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Pubsub_Broadcast_Msg:
				ack := shared.Pubsub_Broadcast_Ack {
					subscriber_id = data.subscriber_id,
					value         = m.value,
				}
				actod.send_to(data.ack_actor, data.target_node, ack)
			}
		},
	}

	for i in 0 ..< subscriber_count {
		sub_data := Pubsub_Sub_Data {
			subscriber_id  = i,
			ack_actor      = ack_actor,
			target_node    = target_node,
			publisher_type = PUBLISHER_TYPE,
		}
		_, spawn_ok := actod.spawn(fmt.tprintf("pubsub_sub_%d", i), sub_data, Pubsub_Sub_Behaviour)
		if !spawn_ok {
			fmt.printf("Failed to spawn pubsub subscriber %d\n", i)
			os.exit(1)
		}
	}

	fmt.println("READY")

	for {
		time.sleep(100 * time.Millisecond)
	}
}

run_union_sender :: proc() {
	target_node := os.lookup_env("TARGET_NODE", context.temp_allocator) or_else "TestNode1"
	target_port_str := os.lookup_env("TARGET_PORT", context.temp_allocator) or_else "16001"
	target_actor := os.lookup_env("TARGET_ACTOR", context.temp_allocator) or_else "union_receiver"
	auth_password :=
		os.lookup_env("AUTH_PASSWORD", context.temp_allocator) or_else "test_dist_password"

	target_port := 16001
	if port_val, ok := strconv.parse_int(target_port_str); ok {
		target_port = port_val
	}

	actod.NODE_INIT(
		name = "UnionSenderNode",
		opts = actod.make_node_config(
			network = actod.make_network_config(port = 0, auth_password = auth_password),
			actor_config = actod.make_actor_config(
				logging = actod.make_log_config(level = log_level),
			),
		),
	)

	target_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = target_port,
	}

	_, ok := actod.register_node(target_node, target_addr, .TCP_Custom_Protocol)
	if !ok {
		fmt.println("Failed to register target node")
		os.exit(1)
	}

	time.sleep(250 * time.Millisecond)

	ping_msg := shared.Network_Union_Message(shared.Network_Union_Ping{seq = 42})
	err := actod.send_to(target_actor, target_node, ping_msg)
	if err != .OK {
		fmt.printf("Failed to send ping union message: %v\n", err)
		os.exit(1)
	}

	chat_msg := shared.Network_Union_Message(
		shared.Network_Union_Chat{name = "alice", content = "hello from remote"},
	)
	err2 := actod.send_to(target_actor, target_node, chat_msg)
	if err2 != .OK {
		fmt.printf("Failed to send chat union message: %v\n", err2)
		os.exit(1)
	}

	ping_msg2 := shared.Network_Union_Message(shared.Network_Union_Ping{seq = 99})
	err3 := actod.send_to(target_actor, target_node, ping_msg2)
	if err3 != .OK {
		fmt.printf("Failed to send second ping union message: %v\n", err3)
		os.exit(1)
	}

	time.sleep(500 * time.Millisecond)

	actod.SHUTDOWN_NODE()
	os.exit(0)
}
