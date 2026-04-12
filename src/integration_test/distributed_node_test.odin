package integration

import "../actod"
import "./network/shared/"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

Distributed_Receiver_Data :: struct {
	messages:       [dynamic]shared.Two_Node_Message,
	expected_count: int,
	done:           ^sync.Sema,
}

Distributed_Receiver_Behaviour :: actod.Actor_Behaviour(Distributed_Receiver_Data) {
	handle_message = proc(data: ^Distributed_Receiver_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case shared.Two_Node_Message:
			content := shared.get_message_content(m)
			sender := shared.get_message_sender(m)
			log.infof("Received distributed message: %d - %s from %s\n", m.id, content, sender)
			delete(content)
			delete(sender)
			append(&data.messages, m)

			resp := shared.make_two_node_response(m.id, "ACK", actod.get_local_node_name())
			actod.send_message(from, resp)

			if len(data.messages) >= data.expected_count {
				sync.sema_post(data.done)
			}
		}
	},
}

Distributed_Echo_Actor_Data :: struct {
	name:           string,
	received_count: int,
}

Distributed_Echo_Actor_Behaviour :: actod.Actor_Behaviour(Distributed_Echo_Actor_Data) {
	handle_message = proc(data: ^Distributed_Echo_Actor_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case shared.Distributed_Echo_Request:
			data.received_count += 1
			response := shared.Distributed_Echo_Response {
				id         = m.id,
				message    = m.message,
				from_actor = data.name,
			}
			target := m.reply_to if m.reply_to != 0 else from
			actod.send_message(target, response)
		}
	},
}

Distributed_Collector_Data :: struct {
	responses:      [dynamic]shared.Distributed_Echo_Response,
	expected_count: int,
	done:           ^sync.Sema,
}

Distributed_Collector_Behaviour :: actod.Actor_Behaviour(Distributed_Collector_Data) {
	handle_message = proc(data: ^Distributed_Collector_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case shared.Distributed_Echo_Response:
			fmt.printf(
				"[Collector] Received response %d from %s: %s\n",
				m.id,
				m.from_actor,
				m.message,
			)
			append(&data.responses, m)
			fmt.printf(
				"[Collector] Total responses: %d/%d\n",
				len(data.responses),
				data.expected_count,
			)
			if len(data.responses) >= data.expected_count {
				fmt.println("[Collector] All responses received!")
				sync.sema_post(data.done)
			}
		case:
			fmt.printf("[Collector] Received unexpected message type: %T\n", msg)
		}
	},
}

test_distributed_communication :: proc(t: ^testing.T) {
	received := sync.Sema{}
	receiver_data := Distributed_Receiver_Data {
		expected_count = 1,
		done           = &received,
	}
	_, ok := actod.spawn("dist_receiver", receiver_data, Distributed_Receiver_Behaviour)
	testing.expect(t, ok, "Failed to spawn receiver actor")

	node2_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=send_once",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
				"TARGET_ACTOR=dist_receiver",
				"AUTH_PASSWORD=test_dist_password",
			},
		),
	}

	remote_process, remote_err := os.process_start(node2_desc)
	if remote_err != nil {
		panic("failed to start node2")
	}

	success := sync.sema_wait_with_timeout(&received, 3 * time.Second)
	testing.expect(t, success, "Failed to receive message from remote node")

	_ = os.process_kill(remote_process)
	_, _ = os.process_wait(remote_process)
}

test_distributed_network_message_routing :: proc(t: ^testing.T) {
	Origin_Data :: struct {
		received_back: bool,
		done:          ^sync.Sema,
	}

	Origin_Behaviour :: actod.Actor_Behaviour(Origin_Data) {
		handle_message = proc(data: ^Origin_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Response:
				data.received_back = true
				if data.done != nil {
					sync.sema_post(data.done)
				}
			}
		},
	}

	received := sync.Sema{}
	origin_data := Origin_Data {
		done = &received,
	}
	_, ok := actod.spawn("origin_actor", origin_data, Origin_Behaviour)
	testing.expect(t, ok, "Failed to spawn origin actor")

	node2_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=relay_node",
				"NODE_NAME=RelayNode2",
				fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
				"TARGET_NODE=RelayNode3",
				fmt.tprintf("TARGET_PORT=%d", test_base_port + 2),
				"AUTH_PASSWORD=test_dist_password",
				"ORIGIN_NODE=TestNode1",
				fmt.tprintf("ORIGIN_PORT=%d", test_base_port),
				"ORIGIN_ACTOR=origin_actor",
			},
		),
	}

	remote_process, remote_err := os.process_start(node2_desc)
	if remote_err != nil {
		panic("failed to start node2")
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	node3_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=echo_back",
				"NODE_NAME=RelayNode3",
				fmt.tprintf("NODE_PORT=%d", test_base_port + 2),
				"AUTH_PASSWORD=test_dist_password",
				"ECHO_TO_NODE=TestNode1",
				fmt.tprintf("ECHO_TO_PORT=%d", test_base_port),
				"ECHO_TO_ACTOR=origin_actor",
			},
		),
	}

	node3_process, node3_err := os.process_start(node3_desc)
	if node3_err != nil {
		panic("failed to start node3")
	}
	defer {
		_ = os.process_kill(node3_process)
		_, _ = os.process_wait(node3_process)
	}

	time.sleep(200 * time.Millisecond)

	node2_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg2 := actod.register_node("RelayNode2", node2_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg2, "Failed to register Node2")

	msg := shared.Network_Test_Request {
		id      = 1,
		message = "Hello from network routing test",
	}
	err := actod.send_message_name("relay_actor@RelayNode2", msg)
	testing.expect(t, err == .OK, "Failed to send to relay node")

	success := sync.sema_wait_with_timeout(&received, 3 * time.Second)
	testing.expect(t, success, "Failed to receive message back through network relay")
}

test_distributed_concurrent_network_messages :: proc(t: ^testing.T) {
	message_count := 100
	done := sync.Sema{}

	Concurrent_Test_Data :: struct {
		messages:       [dynamic]shared.Two_Node_Message,
		expected_count: int,
		done:           ^sync.Sema,
		start_time:     time.Time,
		first_msg_time: time.Time,
		last_msg_time:  time.Time,
	}

	Concurrent_Test_Behaviour :: actod.Actor_Behaviour(Concurrent_Test_Data) {
		handle_message = proc(data: ^Concurrent_Test_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Two_Node_Message:
				if len(data.messages) == 0 {
					data.first_msg_time = time.now()
				}
				append(&data.messages, m)
				data.last_msg_time = time.now()

				if len(data.messages) >= data.expected_count {
					sync.sema_post(data.done)
				}
			}
		},
	}

	test_data := Concurrent_Test_Data {
		expected_count = message_count,
		done           = &done,
		start_time     = time.now(),
	}

	_, ok := actod.spawn("burst_receiver", test_data, Concurrent_Test_Behaviour)
	testing.expect(t, ok, "Failed to spawn receiver actor")

	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=send_burst",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
				"TARGET_ACTOR=burst_receiver",
				"AUTH_PASSWORD=test_dist_password",
				fmt.tprintf("MESSAGE_COUNT=%d", message_count),
			},
		),
	}

	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		panic(fmt.tprintf("failed to start remote_process: %v", remote_err))
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	timeout := time.Duration(max(5, message_count / 100) * int(time.Second))
	success := sync.sema_wait_with_timeout(&done, timeout)
	testing.expect(
		t,
		success,
		fmt.tprintf("Failed to receive all %d messages in %v", message_count, timeout),
	)
}

test_connection_lifecycle :: proc(t: ^testing.T) {
	Lifecycle_Test_Data :: struct {
		responses:      [dynamic]shared.Network_Test_Response,
		expected_count: int,
		done:           ^sync.Sema,
	}

	Lifecycle_Test_Behaviour :: actod.Actor_Behaviour(Lifecycle_Test_Data) {
		handle_message = proc(data: ^Lifecycle_Test_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Response:
				append(&data.responses, m)
				if len(data.responses) >= data.expected_count {
					sync.sema_post(data.done)
				}
			}
		},
	}

	done := sync.Sema{}
	test_data := Lifecycle_Test_Data {
		expected_count = 3,
		done           = &done,
	}

	_, ok := actod.spawn("lifecycle_test_actor", test_data, Lifecycle_Test_Behaviour)
	testing.expect(t, ok, "Failed to spawn test actor")

	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=lifecycle_server",
				"NODE_NAME=LifecycleNode",
				fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
				"AUTH_PASSWORD=test_dist_password",
				"HEARTBEAT_INTERVAL_MS=100",
				"HEARTBEAT_TIMEOUT_MS=300",
				"RECONNECT_INITIAL_MS=200",
				"RECONNECT_RETRY_MS=300",
				"REPLY_TO_ACTOR=lifecycle_test_actor",
				"REPLY_TO_NODE=TestNode1",
				fmt.tprintf("REPLY_TO_PORT=%d", test_base_port),
			},
		),
	}

	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		testing.expect(t, false, "Failed to start remote node")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("LifecycleNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(200 * time.Millisecond)

	for i in 0 ..< 3 {
		msg := shared.Network_Test_Request {
			id      = i,
			message = fmt.tprintf("Lifecycle test message %d", i),
		}
		err := actod.send_message_name("lifecycle_echo@LifecycleNode", msg)
		testing.expect(t, err == .OK, fmt.tprintf("Failed to send message %d", i))
		time.sleep(100 * time.Millisecond)
	}

	success := sync.sema_wait_with_timeout(&done, 3 * time.Second)
	testing.expect(t, success, "Failed to receive all responses")
}

test_lifecycle_broadcast :: proc(t: ^testing.T) {
	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=lifecycle_broadcast",
				"NODE_NAME=BroadcastNode",
				fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
				"AUTH_PASSWORD=test_dist_password",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
			},
		),
	}

	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		testing.expect(t, false, "Failed to start remote broadcast node")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	found := false
	for _ in 0 ..< 30 {
		pid, ok := actod.get_actor_pid("broadcast_test_actor@BroadcastNode")
		if ok && pid != 0 {
			testing.expect(t, !actod.is_local_pid(pid), "Broadcast actor should be a remote PID")
			found = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, found, "Remote actor should appear via lifecycle broadcast within 5 seconds")
}

test_registry_exchange :: proc(t: ^testing.T) {
	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=registry_exchange",
				"NODE_NAME=RegistryNode",
				fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
				"AUTH_PASSWORD=test_dist_password",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
			},
		),
	}

	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		testing.expect(t, false, "Failed to start remote registry exchange node")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	found_actor_1 := false
	found_actor_2 := false
	for _ in 0 ..< 30 {
		if !found_actor_1 {
			pid1, ok1 := actod.get_actor_pid("pre_existing_actor_1@RegistryNode")
			if ok1 && pid1 != 0 {
				testing.expect(t, !actod.is_local_pid(pid1), "Actor 1 should be a remote PID")
				found_actor_1 = true
			}
		}
		if !found_actor_2 {
			pid2, ok2 := actod.get_actor_pid("pre_existing_actor_2@RegistryNode")
			if ok2 && pid2 != 0 {
				testing.expect(t, !actod.is_local_pid(pid2), "Actor 2 should be a remote PID")
				found_actor_2 = true
			}
		}
		if found_actor_1 && found_actor_2 {
			break
		}
		time.sleep(100 * time.Millisecond)
	}

	testing.expect(
		t,
		found_actor_1,
		"Pre-existing actor 1 should appear via registry snapshot within 5 seconds",
	)
	testing.expect(
		t,
		found_actor_2,
		"Pre-existing actor 2 should appear via registry snapshot within 5 seconds",
	)
}

Spawn_Test_Data :: struct {
	initialized: bool,
	parent:      actod.PID,
}

spawn_test_worker :: proc(name: string, parent_pid: actod.PID) -> (actod.PID, bool) {
	actor_type, _ := actod.register_actor_type("spawn_test_worker")
	data := Spawn_Test_Data{}
	behaviour := actod.Actor_Behaviour(Spawn_Test_Data) {
		actor_type = actor_type,
		init = proc(data: ^Spawn_Test_Data) {
			data.initialized = true
			data.parent = actod.get_actor_parent(actod.get_self_pid())
		},
		handle_message = proc(data: ^Spawn_Test_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Request:
				response := shared.Network_Test_Response {
					id        = m.id,
					message   = m.message,
					from_node = "spawn_test",
				}
				actod.send_message(from, response)
			}
		},
	}
	return actod.spawn(name, data, behaviour, parent_pid = parent_pid)
}

test_spawn_by_name :: proc(t: ^testing.T) {
	SPAWN_TEST_TYPE, type_ok := actod.register_actor_type("spawn_test_worker")
	testing.expect(t, type_ok, "Should register actor type")

	reg_ok := actod.register_spawn_func("spawn_test_worker", spawn_test_worker)
	testing.expect(t, reg_ok, "Should register spawn function")

	pid, spawn_ok := actod.spawn_by_name("spawn_test_worker", "test_worker_1")
	testing.expect(t, spawn_ok, "spawn_by_name should succeed")
	testing.expect(t, pid != 0, "PID should not be zero")

	time.sleep(50 * time.Millisecond)

	pid_type := actod.get_pid_actor_type(pid)
	testing.expect(
		t,
		pid_type == SPAWN_TEST_TYPE,
		fmt.tprintf("Actor type in PID should be %d, got %d", SPAWN_TEST_TYPE, pid_type),
	)

	done := sync.Sema{}
	Collector_Data :: struct {
		response: shared.Network_Test_Response,
		done:     ^sync.Sema,
	}
	Collector_Behaviour :: actod.Actor_Behaviour(Collector_Data) {
		handle_message = proc(data: ^Collector_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Response:
				data.response = m
				sync.sema_post(data.done)
			}
		},
	}
	collector_pid, col_ok := actod.spawn(
		"spawn_test_collector",
		Collector_Data{done = &done},
		Collector_Behaviour,
	)
	testing.expect(t, col_ok, "Should spawn collector")

	time.sleep(50 * time.Millisecond)

	req := shared.Network_Test_Request {
		id      = 42,
		message = "hello from spawn test",
	}
	actod.send_message(pid, req)

	success := sync.sema_wait_with_timeout(&done, 2 * time.Second)
	testing.expect(t, success, "Should receive response from spawned actor")

	parent_pid := collector_pid
	child_pid, child_ok := actod.spawn_by_name(
		"spawn_test_worker",
		"test_worker_child",
		parent_pid,
	)
	testing.expect(t, child_ok, "spawn_by_name with parent should succeed")

	time.sleep(50 * time.Millisecond)

	actual_parent := actod.get_actor_parent(child_pid)
	testing.expect(
		t,
		actual_parent == parent_pid,
		fmt.tprintf("Parent PID should be %v, got %v", parent_pid, actual_parent),
	)

	hash := actod.get_spawn_func_hash("spawn_test_worker")
	func_from_hash, hash_found := actod.get_spawn_func_by_hash(hash)
	testing.expect(t, hash_found, "Should find spawn function by hash")
	testing.expect(t, func_from_hash != nil, "Function from hash should not be nil")

	hash_pid, hash_ok := func_from_hash("test_worker_from_hash", 0)
	testing.expect(t, hash_ok, "Spawning via hash-resolved function should succeed")

	hash_pid_type := actod.get_pid_actor_type(hash_pid)
	testing.expect(
		t,
		hash_pid_type == SPAWN_TEST_TYPE,
		"Actor spawned via hash should have correct type",
	)

	actod.terminate_actor(hash_pid)
	actod.terminate_actor(child_pid)
	actod.terminate_actor(pid)
	actod.terminate_actor(collector_pid)
	time.sleep(100 * time.Millisecond)
}

test_connection_reconnection :: proc(t: ^testing.T) {
	Reconnect_Test_Data :: struct {
		responses:    [dynamic]shared.Network_Test_Response,
		phase1_count: int,
		phase2_count: int,
		phase1_done:  ^sync.Sema,
		phase2_done:  ^sync.Sema,
	}

	Reconnect_Test_Behaviour :: actod.Actor_Behaviour(Reconnect_Test_Data) {
		handle_message = proc(data: ^Reconnect_Test_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Response:
				append(&data.responses, m)
				count := len(data.responses)
				if count == data.phase1_count && data.phase1_done != nil {
					sync.sema_post(data.phase1_done)
				}
				if count == data.phase1_count + data.phase2_count && data.phase2_done != nil {
					sync.sema_post(data.phase2_done)
				}
			}
		},
	}

	phase1_done := sync.Sema{}
	phase2_done := sync.Sema{}
	test_data := Reconnect_Test_Data {
		phase1_count = 2,
		phase2_count = 2,
		phase1_done  = &phase1_done,
		phase2_done  = &phase2_done,
	}

	_, ok := actod.spawn("reconnect_test_actor", test_data, Reconnect_Test_Behaviour)
	testing.expect(t, ok, "Failed to spawn test actor")

	reconnect_port := test_base_port + 1
	reconnect_base := test_base_port

	start_remote :: proc(node_port: int, reply_port: int) -> (os.Process, bool) {
		desc := os.Process_Desc {
			command = []string{INTEGRATION_TEST_BIN},
			env     = make_test_env(
				[]string {
					"ACTOD_TEST_NODE=lifecycle_server",
					"NODE_NAME=ReconnectNode",
					fmt.tprintf("NODE_PORT=%d", node_port),
					"AUTH_PASSWORD=test_dist_password",
					"HEARTBEAT_INTERVAL_MS=100",
					"HEARTBEAT_TIMEOUT_MS=300",
					"RECONNECT_INITIAL_MS=200",
					"RECONNECT_RETRY_MS=300",
					"REPLY_TO_ACTOR=reconnect_test_actor",
					"REPLY_TO_NODE=TestNode1",
					fmt.tprintf("REPLY_TO_PORT=%d", reply_port),
				},
			),
		}
		proc_handle, err := os.process_start(desc)
		if err != nil {
			return {}, false
		}
		return proc_handle, true
	}

	remote_process, start_ok := start_remote(reconnect_port, reconnect_base)
	testing.expect(t, start_ok, "Failed to start remote node")

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = reconnect_port,
	}
	_, reg_ok := actod.register_node("ReconnectNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(200 * time.Millisecond)

	for i in 0 ..< 2 {
		msg := shared.Network_Test_Request {
			id      = i,
			message = fmt.tprintf("Phase 1 message %d", i),
		}
		err := actod.send_message_name("lifecycle_echo@ReconnectNode", msg)
		testing.expect(t, err == .OK, fmt.tprintf("Failed to send phase 1 message %d", i))
		time.sleep(100 * time.Millisecond)
	}

	phase1_success := sync.sema_wait_with_timeout(&phase1_done, 3 * time.Second)
	testing.expect(t, phase1_success, "Failed to complete phase 1")

	_ = os.process_kill(remote_process)
	_, _ = os.process_wait(remote_process)

	time.sleep(200 * time.Millisecond)

	remote_process2, restart_ok := start_remote(reconnect_port, reconnect_base)
	testing.expect(t, restart_ok, "Failed to restart remote node")
	defer {
		_ = os.process_kill(remote_process2)
		_, _ = os.process_wait(remote_process2)
	}

	time.sleep(500 * time.Millisecond)

	for i in 0 ..< 2 {
		msg := shared.Network_Test_Request {
			id      = 100 + i,
			message = fmt.tprintf("Phase 2 message %d", i),
		}
		err := actod.send_message_name("lifecycle_echo@ReconnectNode", msg)
		if err != .OK {
			time.sleep(200 * time.Millisecond)
			err = actod.send_message_name("lifecycle_echo@ReconnectNode", msg)
		}
		testing.expect(t, err == .OK, fmt.tprintf("Failed to send phase 2 message %d: %v", i, err))
		time.sleep(100 * time.Millisecond)
	}

	phase2_success := sync.sema_wait_with_timeout(&phase2_done, 5 * time.Second)
	testing.expect(t, phase2_success, "Failed to complete phase 2 - reconnection may have failed")
}


@(private)
g_supervision_target_node: string

@(private)
g_remote_child_counter: u64

local_supervision_worker_stub :: proc(name: string, parent_pid: actod.PID) -> (actod.PID, bool) {
	return 0, false
}

create_remote_crash_child :: proc() -> actod.SPAWN {
	return proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
			idx := sync.atomic_add(&g_remote_child_counter, 1)
			name := fmt.tprintf("remote-crash-child-%d", idx)
			return actod.spawn_remote(
				"supervision_worker",
				name,
				g_supervision_target_node,
				_parent_pid,
			)
		}
}

start_supervision_server :: proc(node_port: int, base_port: int) -> (os.Process, bool) {
	desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=supervision_server",
				"NODE_NAME=SupervisionNode",
				fmt.tprintf("NODE_PORT=%d", node_port),
				"AUTH_PASSWORD=test_dist_password",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", base_port),
			},
		),
	}
	proc_handle, err := os.process_start(desc)
	if err != nil {
		return {}, false
	}
	return proc_handle, true
}

test_remote_spawn_basic :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	pid, spawn_ok := actod.spawn_remote("supervision_worker", "remote-worker-1", "SupervisionNode")
	testing.expect(t, spawn_ok, "spawn_remote should succeed")
	testing.expect(t, pid != 0, "Remote PID should not be zero")
	testing.expect(t, !actod.is_local_pid(pid), "Remote PID should not be local")

	done := sync.Sema{}

	Pong_Collector_Data :: struct {
		response: shared.Supervision_Pong,
		done:     ^sync.Sema,
	}

	Pong_Collector_Behaviour :: actod.Actor_Behaviour(Pong_Collector_Data) {
		handle_message = proc(data: ^Pong_Collector_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Supervision_Pong:
				data.response = m
				sync.sema_post(data.done)
			}
		},
	}

	collector_pid, col_ok := actod.spawn(
		"pong_collector",
		Pong_Collector_Data{done = &done},
		Pong_Collector_Behaviour,
	)
	testing.expect(t, col_ok, "Should spawn collector")

	time.sleep(50 * time.Millisecond)

	ping := shared.Supervision_Ping {
		id = 1,
	}
	err := actod.send_message(pid, ping)
	testing.expect(t, err == .OK, "Should send ping to remote actor")

	success := sync.sema_wait_with_timeout(&done, 3 * time.Second)
	testing.expect(t, success, "Should receive pong from remote actor")

	actod.terminate_actor(collector_pid)
}

test_remote_child_crash_notification :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	done := sync.Sema{}

	Observer_Data :: struct {
		stopped_msg: actod.Actor_Stopped,
		received:    bool,
		done:        ^sync.Sema,
	}

	Observer_Behaviour :: actod.Actor_Behaviour(Observer_Data) {
		handle_message = proc(data: ^Observer_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case actod.Actor_Stopped:
				data.stopped_msg = m
				data.received = true
				sync.sema_post(data.done)
			}
		},
	}

	observer_pid, obs_ok := actod.spawn(
		"crash_observer",
		Observer_Data{done = &done},
		Observer_Behaviour,
	)
	testing.expect(t, obs_ok, "Should spawn observer")

	time.sleep(50 * time.Millisecond)

	child_pid, spawn_ok := actod.spawn_remote(
		"supervision_worker",
		"crash-test-child",
		"SupervisionNode",
		observer_pid,
	)
	testing.expect(t, spawn_ok, "spawn_remote should succeed")
	testing.expect(t, child_pid != 0, "Child PID should not be zero")

	time.sleep(200 * time.Millisecond)

	crash_cmd := shared.Supervision_Crash_Command {
		reason = .INTERNAL_ERROR,
	}
	err := actod.send_message(child_pid, crash_cmd)
	testing.expect(t, err == .OK, "Should send crash command to remote child")

	success := sync.sema_wait_with_timeout(&done, 3 * time.Second)
	testing.expect(t, success, "Observer should receive Actor_Stopped from remote child")

	actod.terminate_actor(observer_pid)
}

test_remote_one_for_one_restart :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	g_supervision_target_node = "SupervisionNode"
	sync.atomic_store(&g_remote_child_counter, 0)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	supervisor_data := Supervisor_Test_Data {
		id = 200,
	}
	supervisor_pid, sup_ok := actod.spawn(
		"remote-one-for-one-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, sup_ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)

	child_pid, add_ok := actod.add_child(supervisor_pid, create_remote_crash_child())
	testing.expect(t, add_ok, "Should add remote child")
	testing.expect(t, child_pid != 0, "Child PID should not be zero")
	testing.expect(t, !actod.is_local_pid(child_pid), "Child should be remote")

	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 2000), "Should have 1 child")

	time.sleep(200 * time.Millisecond)
	crash_cmd := shared.Supervision_Crash_Command {
		reason = .INTERNAL_ERROR,
	}
	err := actod.send_message(child_pid, crash_cmd)
	testing.expect(t, err == .OK, "Should send crash to remote child")

	new_pid, changed := wait_for_child_pid_change(supervisor_pid, child_pid, 0, 5000)
	testing.expect(t, changed, "Remote child should be restarted with new PID")
	testing.expect(t, new_pid != child_pid, "New PID should differ from old")
	testing.expect(t, !actod.is_local_pid(new_pid), "Restarted child should still be remote")

	verify_child_count(t, supervisor_pid, 1)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	time.sleep(200 * time.Millisecond)
}

test_remote_one_for_all_restart :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	g_supervision_target_node = "SupervisionNode"
	sync.atomic_store(&g_remote_child_counter, 0)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	supervisor_data := Supervisor_Test_Data {
		id = 201,
	}
	supervisor_pid, sup_ok := actod.spawn(
		"remote-one-for-all-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .ONE_FOR_ALL,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, sup_ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)

	for _ in 0 ..< 3 {
		_, add_ok := actod.add_child(supervisor_pid, create_remote_crash_child())
		testing.expect(t, add_ok, "Should add remote child")
	}

	testing.expect(t, wait_for_child_count(supervisor_pid, 3, 3000), "Should have 3 children")

	initial_children := actod.get_children(supervisor_pid)
	defer delete(initial_children)
	testing.expect_value(t, len(initial_children), 3)

	if len(initial_children) > 0 {
		crash_cmd := shared.Supervision_Crash_Command {
			reason = .INTERNAL_ERROR,
		}
		err := actod.send_message(initial_children[0], crash_cmd)
		testing.expect(t, err == .OK, "Should crash first child")

		time.sleep(1 * time.Second)

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		testing.expect_value(t, len(new_children), 3)
		for new_pid, i in new_children {
			testing.expect(
				t,
				new_pid != initial_children[i],
				fmt.tprintf("Child %d should have new PID", i),
			)
			testing.expect(
				t,
				!actod.is_local_pid(new_pid),
				fmt.tprintf("Child %d should be remote", i),
			)
		}
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	time.sleep(200 * time.Millisecond)
}

test_remote_rest_for_one_restart :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	g_supervision_target_node = "SupervisionNode"
	sync.atomic_store(&g_remote_child_counter, 0)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	supervisor_data := Supervisor_Test_Data {
		id = 202,
	}
	supervisor_pid, sup_ok := actod.spawn(
		"remote-rest-for-one-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .REST_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, sup_ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)

	for _ in 0 ..< 4 {
		_, add_ok := actod.add_child(supervisor_pid, create_remote_crash_child())
		testing.expect(t, add_ok, "Should add remote child")
	}

	testing.expect(t, wait_for_child_count(supervisor_pid, 4, 3000), "Should have 4 children")

	initial_children := actod.get_children(supervisor_pid)
	defer delete(initial_children)
	testing.expect_value(t, len(initial_children), 4)

	if len(initial_children) >= 3 {
		crash_cmd := shared.Supervision_Crash_Command {
			reason = .INTERNAL_ERROR,
		}
		err := actod.send_message(initial_children[1], crash_cmd)
		testing.expect(t, err == .OK, "Should crash second child")

		time.sleep(1 * time.Second)

		new_children := actod.get_children(supervisor_pid)
		defer delete(new_children)

		testing.expect_value(t, len(new_children), 4)

		testing.expect_value(t, new_children[0], initial_children[0])

		for i in 1 ..< 4 {
			testing.expect(
				t,
				new_children[i] != initial_children[i],
				fmt.tprintf("Child %d should have new PID", i),
			)
			testing.expect(
				t,
				!actod.is_local_pid(new_children[i]),
				fmt.tprintf("Child %d should be remote", i),
			)
		}
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	time.sleep(200 * time.Millisecond)
}

test_remote_restart_via_registry_lookup :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	supervisor_data := Supervisor_Test_Data {
		id = 203,
	}
	supervisor_pid, sup_ok := actod.spawn(
		"remote-registry-restart-supervisor",
		supervisor_data,
		Supervisor_Test_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .PERMANENT,
			max_restarts = 5,
		),
	)
	testing.expect(t, sup_ok, "Failed to spawn supervisor")

	time.sleep(100 * time.Millisecond)

	remote_pid, spawn_ok := actod.spawn_remote(
		"supervision_worker",
		"registry-restart-child",
		"SupervisionNode",
		supervisor_pid,
	)
	testing.expect(t, spawn_ok, "spawn_remote should succeed")
	testing.expect(t, remote_pid != 0, "Remote PID should not be zero")
	testing.expect(t, !actod.is_local_pid(remote_pid), "Child should be remote")

	spawn_hash := actod.get_spawn_func_hash("supervision_worker")

	_, adopt_ok := actod.add_child_existing(
		supervisor_pid,
		remote_pid,
		local_supervision_worker_stub,
		spawn_hash,
	)
	testing.expect(t, adopt_ok, "Should adopt remote child")

	testing.expect(t, wait_for_child_count(supervisor_pid, 1, 2000), "Should have 1 child")

	children := actod.get_children(supervisor_pid)
	defer delete(children)
	testing.expect_value(t, len(children), 1)
	if len(children) > 0 {
		testing.expect_value(t, children[0], remote_pid)
	}

	time.sleep(200 * time.Millisecond)
	crash_cmd := shared.Supervision_Crash_Command {
		reason = .INTERNAL_ERROR,
	}
	err := actod.send_message(remote_pid, crash_cmd)
	testing.expect(t, err == .OK, "Should send crash to remote child")

	new_pid, changed := wait_for_child_pid_change(supervisor_pid, remote_pid, 0, 5000)
	testing.expect(t, changed, "Remote child should be restarted with new PID")
	testing.expect(t, new_pid != remote_pid, "New PID should differ from old")
	testing.expect(t, !actod.is_local_pid(new_pid), "Restarted child should still be remote")

	verify_child_count(t, supervisor_pid, 1)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	time.sleep(200 * time.Millisecond)
}

test_remote_spawn_invalid_func_name :: proc(t: ^testing.T) {
	actod.register_spawn_func("supervision_worker", local_supervision_worker_stub)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	testing.expect(t, start_ok, "Failed to start supervision server")
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)

	remote_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register remote node")

	time.sleep(300 * time.Millisecond)

	pid, spawn_ok := actod.spawn_remote(
		"nonexistent_worker_type",
		"should-fail-actor",
		"SupervisionNode",
	)
	testing.expect(t, !spawn_ok, "spawn_remote with invalid func name should fail")
	testing.expect_value(t, pid, actod.PID(0))
}

test_remote_spawn_timeout :: proc(t: ^testing.T) {
	dead_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("DeadNode", dead_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register dead node")

	pid, spawn_ok := actod.spawn_remote(
		"supervision_worker",
		"should-timeout-actor",
		"DeadNode",
		timeout = 500 * time.Millisecond,
	)
	testing.expect(t, !spawn_ok, "spawn_remote to dead node should fail (timeout)")
	testing.expect_value(t, pid, actod.PID(0))
}

test_mesh_discovery :: proc(t: ^testing.T) {
	node_b_port := test_base_port + 1
	node_b_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=mesh_middle",
				"NODE_NAME=MeshNodeB",
				fmt.tprintf("NODE_PORT=%d", node_b_port),
				"AUTH_PASSWORD=test_dist_password",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
			},
		),
	}

	node_b_process, node_b_err := os.process_start(node_b_desc)
	if node_b_err != nil {
		testing.expect(t, false, "Failed to start MeshNodeB")
		return
	}
	defer {
		_ = os.process_kill(node_b_process)
		_, _ = os.process_wait(node_b_process)
	}

	node_c_port := test_base_port + 2
	node_c_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=mesh_leaf",
				"NODE_NAME=MeshNodeC",
				fmt.tprintf("NODE_PORT=%d", node_c_port),
				"AUTH_PASSWORD=test_dist_password",
				"TARGET_NODE=MeshNodeB",
				fmt.tprintf("TARGET_PORT=%d", node_b_port),
			},
		),
	}

	node_c_process, node_c_err := os.process_start(node_c_desc)
	if node_c_err != nil {
		testing.expect(t, false, "Failed to start MeshNodeC")
		return
	}
	defer {
		_ = os.process_kill(node_c_process)
		_, _ = os.process_wait(node_c_process)
	}

	time.sleep(200 * time.Millisecond)

	node_b_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = node_b_port,
	}
	_, reg_ok := actod.register_node("MeshNodeB", node_b_addr, .TCP_Custom_Protocol)
	testing.expect(t, reg_ok, "Failed to register MeshNodeB")

	found := false
	mesh_actor_pid: actod.PID
	for _ in 0 ..< 30 {
		pid, ok := actod.get_actor_pid("mesh_actor@MeshNodeC")
		if ok && pid != 0 {
			testing.expect(t, !actod.is_local_pid(pid), "mesh_actor should be a remote PID")
			mesh_actor_pid = pid
			found = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(
		t,
		found,
		"Actor on MeshNodeC should be discovered by TestNode1 via MeshNodeB forwarding within 8 seconds",
	)

	if !found {
		return
	}

	done := sync.Sema{}

	Mesh_Collector_Data :: struct {
		response: shared.Network_Test_Response,
		done:     ^sync.Sema,
	}

	Mesh_Collector_Behaviour :: actod.Actor_Behaviour(Mesh_Collector_Data) {
		handle_message = proc(data: ^Mesh_Collector_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Test_Response:
				data.response = m
				sync.sema_post(data.done)
			}
		},
	}

	collector_pid, col_ok := actod.spawn(
		"mesh_collector",
		Mesh_Collector_Data{done = &done},
		Mesh_Collector_Behaviour,
	)
	testing.expect(t, col_ok, "Should spawn mesh collector")

	time.sleep(50 * time.Millisecond)

	req := shared.Network_Test_Request {
		id      = 99,
		message = "hello from mesh test",
	}
	send_err := actod.send_message(mesh_actor_pid, req)
	testing.expect(t, send_err == .OK, "Should send message to mesh-discovered actor on MeshNodeC")

	got_response := sync.sema_wait_with_timeout(&done, 3 * time.Second)
	testing.expect(
		t,
		got_response,
		"Should receive response from MeshNodeC's mesh_actor via lazy connection",
	)

	actod.terminate_actor(collector_pid)
	time.sleep(50 * time.Millisecond)

	_ = os.process_kill(node_c_process)
	_, _ = os.process_wait(node_c_process)

	removed := false
	for _ in 0 ..< 30 {
		_, ok := actod.get_actor_pid("mesh_actor@MeshNodeC")
		if !ok {
			removed = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(
		t,
		removed,
		"mesh_actor@MeshNodeC should be removed from A's registry after C disconnects from B",
	)
}

PUBSUB_BROADCAST_PUBLISHER_TYPE: actod.Actor_Type
PUBSUB_BROADCAST_SUBSCRIBER_COUNT :: 5

test_distributed_pubsub_broadcast :: proc(t: ^testing.T) {
	PUBSUB_BROADCAST_PUBLISHER_TYPE, _ = actod.register_actor_type("pubsub_broadcast_publisher")

	ack_count: i32 = 0
	done := sync.Sema{}

	Ack_Collector_Data :: struct {
		ack_count: ^i32,
		expected:  int,
		done:      ^sync.Sema,
	}

	Ack_Collector_Behaviour :: actod.Actor_Behaviour(Ack_Collector_Data) {
		handle_message = proc(data: ^Ack_Collector_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Pubsub_Broadcast_Ack:
				count := sync.atomic_add(data.ack_count, 1) + 1
				if int(count) >= data.expected {
					sync.sema_post(data.done)
				}
			}
		},
	}

	collector_pid, col_ok := actod.spawn(
		"pubsub_ack_collector",
		Ack_Collector_Data {
			ack_count = &ack_count,
			expected = PUBSUB_BROADCAST_SUBSCRIBER_COUNT,
			done = &done,
		},
		Ack_Collector_Behaviour,
	)
	testing.expect(t, col_ok, "Should spawn ack collector")

	Pubsub_Bcast_Publisher_Data :: struct {}

	pub_behaviour := actod.Actor_Behaviour(Pubsub_Bcast_Publisher_Data) {
		actor_type = PUBSUB_BROADCAST_PUBLISHER_TYPE,
		handle_message = proc(data: ^Pubsub_Bcast_Publisher_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case string:
				if m == "publish" {
					actod.broadcast(shared.Pubsub_Broadcast_Msg{value = 42, timestamp = 12345})
				}
			}
		},
	}

	pub_pid, pub_ok := actod.spawn(
		"pubsub_bcast_publisher",
		Pubsub_Bcast_Publisher_Data{},
		pub_behaviour,
	)
	testing.expect(t, pub_ok, "Should spawn publisher")

	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=pubsub_subscriber",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
				"AUTH_PASSWORD=test_dist_password",
				"ACK_ACTOR=pubsub_ack_collector",
				fmt.tprintf("SUBSCRIBER_COUNT=%d", PUBSUB_BROADCAST_SUBSCRIBER_COUNT),
			},
		),
	}

	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		testing.expect(t, false, "Failed to start remote pubsub node")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	for _ in 0 ..< 30 {
		count := actod.get_subscriber_count(PUBSUB_BROADCAST_PUBLISHER_TYPE)
		if count >= PUBSUB_BROADCAST_SUBSCRIBER_COUNT {
			break
		}
		time.sleep(100 * time.Millisecond)
	}

	sub_count := actod.get_subscriber_count(PUBSUB_BROADCAST_PUBLISHER_TYPE)
	testing.expectf(
		t,
		sub_count >= PUBSUB_BROADCAST_SUBSCRIBER_COUNT,
		"Should have %d subscribers, got %d",
		PUBSUB_BROADCAST_SUBSCRIBER_COUNT,
		sub_count,
	)

	actod.send_message(pub_pid, "publish")

	success := sync.sema_wait_with_timeout(&done, 5 * time.Second)
	testing.expectf(
		t,
		success,
		"All %d remote subscribers should ACK, got %d",
		PUBSUB_BROADCAST_SUBSCRIBER_COUNT,
		sync.atomic_load(&ack_count),
	)

	actod.terminate_actor(collector_pid)
	actod.terminate_actor(pub_pid)
	time.sleep(100 * time.Millisecond)
}

test_distributed_union_messages :: proc(t: ^testing.T) {
	ack_count: i32 = 0
	done := sync.Sema{}
	expected_acks: i32 = 3

	Union_Receiver_Data :: struct {
		ack_count: ^i32,
		done:      ^sync.Sema,
		expected:  i32,
		ping_ok:   bool,
		chat_ok:   bool,
	}

	Union_Receiver_Behaviour :: actod.Actor_Behaviour(Union_Receiver_Data) {
		handle_message = proc(data: ^Union_Receiver_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case shared.Network_Union_Message:
				switch v in m {
				case shared.Network_Union_Ping:
					data.ping_ok = v.seq == 42
				case shared.Network_Union_Chat:
					data.chat_ok = v.name == "alice" && v.content == "hello from remote"
				}

				ack := shared.Network_Union_Ack{}
				switch v in m {
				case shared.Network_Union_Ping:
					ack.variant_id = 1
					ack.seq = v.seq
				case shared.Network_Union_Chat:
					ack.variant_id = 2
				}
				actod.send_message(from, ack)

				count := sync.atomic_add(data.ack_count, 1)
				if count + 1 >= data.expected {
					sync.sema_post(data.done)
				}
			}
		},
	}

	receiver_data := Union_Receiver_Data {
		ack_count = &ack_count,
		done      = &done,
		expected  = expected_acks,
	}
	_, ok := actod.spawn("union_receiver", receiver_data, Union_Receiver_Behaviour)
	testing.expect(t, ok, "Failed to spawn union receiver actor")

	node2_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=union_sender",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
				"TARGET_ACTOR=union_receiver",
				"AUTH_PASSWORD=test_dist_password",
			},
		),
	}

	remote_process, remote_err := os.process_start(node2_desc)
	if remote_err != nil {
		panic("failed to start union_sender node")
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	success := sync.sema_wait_with_timeout(&done, 5 * time.Second)
	testing.expectf(
		t,
		success,
		"Timed out waiting for distributed union messages, got %d/%d",
		sync.atomic_load(&ack_count),
		expected_acks,
	)
}
