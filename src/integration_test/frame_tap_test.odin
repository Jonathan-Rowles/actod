package integration

import "../actod"
import "./network/shared/"
import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

test_frame_tap_duplicate_actor_stopped :: proc(t: ^testing.T) {
	defer actod.frame_tap_clear()
	_ = actod.register_spawn_func("hello_probe", spawn_hello_probe)

	child_gone_count: i32 = 0
	child_gone := sync.Sema{}

	Dup_Parent_Data :: struct {
		child_gone_count: ^i32,
		child_gone:       ^sync.Sema,
	}

	parent_behaviour := actod.Actor_Behaviour(Dup_Parent_Data) {
		handle_message = proc(data: ^Dup_Parent_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case string:
				if m == "go" {
					_, spawned := actod.spawn_remote(
						"hello_probe",
						"dup1",
						"SupervisionNode",
						actod.get_self_pid(),
					)
					if !spawned {
						fmt.println("spawn_remote hello_probe failed")
					}
				}
			}
		},
		on_child_terminated = proc(
			data: ^Dup_Parent_Data,
			child_pid: actod.PID,
			child_name: string,
			reason: actod.Termination_Reason,
			will_restart: bool,
		) {
			sync.atomic_add(data.child_gone_count, 1)
			sync.sema_post(data.child_gone)
		},
	}

	parent_pid, parent_ok := actod.spawn(
		"dup_probe_parent",
		Dup_Parent_Data{child_gone_count = &child_gone_count, child_gone = &child_gone},
		parent_behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
	)
	expect(t, parent_ok, "Should spawn the local parent")

	actod.frame_tap_add(
		actod.Frame_Fault_Rule {
			dir       = .In,
			action    = .Duplicate,
			type_hash = actod.frame_tap_type_hash(actod.Actor_Stopped),
			count     = 1,
		},
	)

	remote_process, start_ok := start_supervision_server(test_base_port + 1, test_base_port)
	if !start_ok {
		expect(t, false, "Failed to start the supervision server")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(200 * time.Millisecond)
	remote_addr := loopback_endpoint(test_base_port + 1)
	_, reg_ok := actod.register_node("SupervisionNode", remote_addr, .TCP_Custom_Protocol)
	expect(t, reg_ok, "Failed to register remote node")
	time.sleep(300 * time.Millisecond)

	_ = actod.send_message(parent_pid, "go")

	got_term := sync.sema_wait_with_timeout(&child_gone, scaled_timeout(5 * time.Second))
	expect(t, got_term, "on_child_terminated must fire despite the duplicated frame")

	time.sleep(500 * time.Millisecond)
	expectf(
		t,
		sync.atomic_load(&child_gone_count) == 1,
		"A duplicated Actor_Stopped frame must not double-fire on_child_terminated, got %d",
		sync.atomic_load(&child_gone_count),
	)
	expect(t, actod.frame_tap_fired() > 0, "The duplicate rule should have fired")

	_ = actod.terminate_actor(parent_pid)
	time.sleep(100 * time.Millisecond)
}

test_frame_tap_partition_heals :: proc(t: ^testing.T) {
	defer actod.frame_tap_clear()

	actod.frame_tap_add(Frame_Fault_Rule_partition(.Out))
	actod.frame_tap_add(Frame_Fault_Rule_partition(.In))

	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		stderr  = os.stderr,
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=latecomer_publisher",
				"TARGET_NODE=TestNode1",
				fmt.tprintf("TARGET_PORT=%d", test_base_port),
				"AUTH_PASSWORD=test_dist_password",
			},
		),
	}
	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		expect(t, false, "Failed to start the latecomer publisher")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(scaled_timeout(2 * time.Second))
	_, found := actod.get_node_by_name("LatecomerPublisher")
	expect(t, !found, "The partition must prevent the handshake from completing")

	actod.frame_tap_clear()

	healed := false
	for _ in 0 ..< scaled_attempts(120) {
		if _, ok := actod.get_node_by_name("LatecomerPublisher"); ok {
			healed = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	expect(t, healed, "After healing the partition the reconnect must complete the handshake")
}

@(private = "file")
Frame_Fault_Rule_partition :: proc(dir: actod.Frame_Dir) -> actod.Frame_Fault_Rule {
	return actod.Frame_Fault_Rule {
		dir       = dir,
		action    = .Drop,
		type_hash = actod.FRAME_TAP_ANY,
		count     = -1,
	}
}

@(private = "file")
loopback_endpoint :: proc(port: int) -> net.Endpoint {
	return net.Endpoint{address = net.IP4_Loopback, port = port}
}

test_frame_tap_drops_outbound_user_message :: proc(t: ^testing.T) {
	defer actod.frame_tap_clear()

	echoed := sync.Sema{}

	Echo_Watcher_Data :: struct {
		echoed: ^sync.Sema,
	}

	watcher_behaviour := actod.Actor_Behaviour(Echo_Watcher_Data) {
		handle_message = proc(data: ^Echo_Watcher_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case shared.Network_Test_Response:
				sync.sema_post(data.echoed)
			}
		},
	}

	watcher_pid, watcher_ok := actod.spawn(
		"tap_echo_watcher",
		Echo_Watcher_Data{echoed = &echoed},
		watcher_behaviour,
	)
	expect(t, watcher_ok, "Should spawn the watcher")

	remote_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		stderr  = os.stderr,
		env     = make_test_env(
			[]string {
				"ACTOD_TEST_NODE=echo_back",
				"NODE_NAME=TapEchoNode",
				fmt.tprintf("NODE_PORT=%d", test_base_port + 1),
				"ECHO_TO_NODE=TestNode1",
				fmt.tprintf("ECHO_TO_PORT=%d", test_base_port),
				"ECHO_TO_ACTOR=tap_echo_watcher",
				"AUTH_PASSWORD=test_dist_password",
			},
		),
	}
	remote_process, remote_err := os.process_start(remote_desc)
	if remote_err != nil {
		expect(t, false, "Failed to start the echo node")
		return
	}
	defer {
		_ = os.process_kill(remote_process)
		_, _ = os.process_wait(remote_process)
	}

	time.sleep(300 * time.Millisecond)
	echo_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = test_base_port + 1,
	}
	_, reg_ok := actod.register_node("TapEchoNode", echo_addr, .TCP_Custom_Protocol)
	expect(t, reg_ok, "Should register the echo node")
	time.sleep(300 * time.Millisecond)

	actod.frame_tap_add(
		actod.Frame_Fault_Rule {
			dir       = .Out,
			action    = .Drop,
			type_hash = actod.frame_tap_type_hash(shared.Network_Test_Request),
		},
	)

	msg := shared.Network_Test_Request {
		id      = 1,
		message = "should be dropped outbound",
	}
	_ = actod.send_to("relay_actor", "TapEchoNode", msg)

	dropped := !sync.sema_wait_with_timeout(&echoed, scaled_timeout(2 * time.Second))
	expect(t, dropped, "An Out drop rule must suppress the outbound user message")
	expect(t, actod.frame_tap_fired() > 0, "The outbound rule must have fired")

	actod.frame_tap_clear()
	_ = actod.send_to("relay_actor", "TapEchoNode", msg)
	delivered := sync.sema_wait_with_timeout(&echoed, scaled_timeout(5 * time.Second))
	expect(t, delivered, "After clearing the rule the same send must reach the peer")

	_ = actod.terminate_actor(watcher_pid)
	time.sleep(100 * time.Millisecond)
}
