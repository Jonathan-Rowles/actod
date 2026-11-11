package integration

import "../../test_harness/ti"
import "../actod"
import "core:fmt"
import "core:testing"
import "core:time"

test_sim_link_peer_cannot_forge_a_reply_to_a_pending_ask :: proc(
	t: ^testing.T,
) {
	mesh := actod.sim_mesh_create(
		2,
		base_port = 36000,
		log_level = test_log_level(),
	)
	defer actod.sim_mesh_destroy(mesh)

	_ = actod.sim_mesh_bind(mesh, 1)
	remote_reply_err := -1
	remote_misuse_err := -1
	_, remote_ok := actod.spawn(
		"forge-remote-responder",
		Ask_Responder_Data {
			reply_err = &remote_reply_err,
			misuse_err = &remote_misuse_err,
		},
		Ask_Responder_Behaviour,
	)
	expect(t, remote_ok, "the remote responder spawned")

	_ = actod.sim_mesh_bind(mesh, 0)
	silent_reply_err := -1
	silent_misuse_err := -1
	silent, silent_ok := actod.spawn(
		"forge-silent",
		Ask_Responder_Data {
			silent = true,
			reply_err = &silent_reply_err,
			misuse_err = &silent_misuse_err,
		},
		Ask_Responder_Behaviour,
	)
	expect(t, silent_ok, "the silent responder spawned")

	asked_token: u64
	ask_err := -1
	answer_y: int
	answer_token: u64
	replying_ok: bool
	timeout_token: u64
	requester, requester_ok := actod.spawn(
		"forge-requester",
		Ask_Requester_Data {
			asked_token = &asked_token,
			ask_err = &ask_err,
			answer_y = &answer_y,
			answer_token = &answer_token,
			replying_ok = &replying_ok,
			timeout_token = &timeout_token,
		},
		Ask_Requester_Behaviour,
	)
	expect(t, requester_ok, "the requester spawned")

	expect(t, actod.sim_mesh_connect_full(mesh), "mesh connect did not settle")

	_ = actod.sim_mesh_bind(mesh, 0)
	remote_responder, remote_known := actod.get_actor_pid(
		fmt.tprintf("forge-remote-responder@%s", actod.sim_mesh_name(mesh, 1)),
	)
	expect(t, remote_known, "the asking node sees the remote responder")
	expect(
		t,
		actod.send_message(
			requester,
			Do_Ask{target = remote_responder, timeout_ms = 100, x = 21},
		) ==
		.OK,
		"the cross-node ask was triggered",
	)
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect_value(t, answer_y, 42)
	expect(t, replying_ok, "the cross-node reply is taken as the reply")
	expect(
		t,
		answer_token != 0 && answer_token == asked_token,
		"the cross-node reply carries the ask token",
	)

	answer_y = 0
	answer_token = 0
	replying_ok = false
	asked_token = 0

	_ = actod.sim_mesh_bind(mesh, 0)
	expect(
		t,
		actod.send_message(
			requester,
			Do_Ask{target = silent, timeout_ms = 100, x = 1},
		) ==
		.OK,
		"the local ask was triggered",
	)
	_ = actod.sim_mesh_run_until_idle(mesh)
	expect(t, asked_token != 0, "the local ask was issued")

	_ = actod.sim_mesh_bind(mesh, 1)
	asking_node, asking_known := actod.get_node_by_name(
		actod.sim_mesh_name(mesh, 0),
	)
	expect(t, asking_known, "the peer knows the asking node")
	forged := Ask_Answer {
		y = -7,
	}
	posing_as_asked := ti.Test_Intercept {
		self_pid = u64(silent),
	}
	ti.test_intercept = &posing_as_asked
	forged_from_handle, _ := actod.unpack_pid(actod.get_self_pid())
	silent_handle, _ := actod.unpack_pid(silent)
	expect(
		t,
		forged_from_handle == silent_handle,
		"the forged reply copies the asked actor's handle",
	)
	forged_sent := actod.send_to_connection_ring_impl(
		actod.get_connection_ring(asking_node),
		requester,
		&forged,
		actod.get_validated_message_info_ptr(Ask_Answer),
		{},
		token = asked_token | actod.ASK_REPLY_BIT,
	)
	ti.test_intercept = nil
	expect(t, forged_sent == .OK, "the peer sent the forged reply")
	_ = actod.sim_mesh_run_until_idle(mesh)

	expect_value(t, answer_y, 0)
	expect(
		t,
		!replying_ok,
		"a forged reply from a peer must not be taken as the reply",
	)

	actod.sim_mesh_advance_clock(mesh, 200 * time.Millisecond)
	_ = actod.sim_mesh_run_until_idle(mesh)

	expect(
		t,
		timeout_token != 0 && timeout_token == asked_token,
		"the ask must still time out after a forged reply",
	)
}
