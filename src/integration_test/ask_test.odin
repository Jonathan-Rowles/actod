package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

Ask_Question :: struct {
	x: int,
}

Ask_Answer :: struct {
	y: int,
}

Do_Ask :: struct {
	target:     actod.PID,
	timeout_ms: int,
	x:          int,
}

Probe_Reply_Misuse :: struct {
	marker: int,
}

@(init)
register_ask_test_messages :: proc "contextless" () {
	actod.register_message_type(Ask_Question)
	actod.register_message_type(Ask_Answer)
	actod.register_message_type(Do_Ask)
	actod.register_message_type(Probe_Reply_Misuse)
}

Ask_Responder_Data :: struct {
	silent:     bool,
	delay:      time.Duration,
	reply_err:  ^int,
	misuse_err: ^int,
}

ask_responder_handle :: proc(d: ^Ask_Responder_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Ask_Question:
		if d.silent {
			return
		}
		if d.delay > 0 {
			time.sleep(d.delay)
		}
		err := actod.reply(Ask_Answer{y = m.x * 2})
		sync.atomic_store(d.reply_err, int(err))
	case Probe_Reply_Misuse:
		err := actod.reply(Ask_Answer{y = -1})
		sync.atomic_store(d.misuse_err, int(err))
	}
}

Ask_Responder_Behaviour :: actod.Actor_Behaviour(Ask_Responder_Data) {
	handle_message = ask_responder_handle,
}

Ask_Requester_Data :: struct {
	asked_token:   ^u64,
	ask_err:       ^int,
	answer_y:      ^int,
	answer_token:  ^u64,
	replying_ok:   ^bool,
	timeout_token: ^u64,
}

ask_requester_handle :: proc(d: ^Ask_Requester_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Do_Ask:
		token, err := actod.ask(
			m.target,
			Ask_Question{x = m.x},
			time.Duration(m.timeout_ms) * time.Millisecond,
		)
		sync.atomic_store(d.asked_token, u64(token))
		sync.atomic_store(d.ask_err, int(err))
	case Ask_Answer:
		token, ok := actod.replying_to()
		sync.atomic_store(d.answer_token, u64(token))
		sync.atomic_store(d.replying_ok, ok)
		sync.atomic_store(d.answer_y, m.y)
	case actod.Ask_Timeout:
		sync.atomic_store(d.timeout_token, u64(m.token))
	}
}

Ask_Requester_Behaviour :: actod.Actor_Behaviour(Ask_Requester_Data) {
	handle_message = ask_requester_handle,
}

wait_for_int :: proc(target: ^int, sentinel: int, budget: time.Duration) {
	start := time.now()
	for sync.atomic_load(target) == sentinel && time.diff(start, time.now()) < budget {
		time.sleep(5 * time.Millisecond)
	}
}

test_ask_reply_roundtrip :: proc(t: ^testing.T) {
	reset_test_state()

	reply_err := -1
	misuse_err := -1
	responder, r_ok := actod.spawn(
		"ask-responder",
		Ask_Responder_Data{reply_err = &reply_err, misuse_err = &misuse_err},
		Ask_Responder_Behaviour,
	)
	expect(t, r_ok, "failed to spawn responder")
	if !r_ok {
		return
	}

	asked_token: u64
	ask_err := -1
	answer_y: int
	answer_token: u64
	replying_ok: bool
	timeout_token: u64
	requester, q_ok := actod.spawn(
		"ask-requester",
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
	expect(t, q_ok, "failed to spawn requester")
	if !q_ok {
		return
	}

	expect(
		t,
		actod.send_message(requester, Do_Ask{target = responder, timeout_ms = 300, x = 21}) == .OK,
		"failed to trigger the ask",
	)

	wait_for_int(&answer_y, 0, 3 * time.Second)

	expect(t, sync.atomic_load(&ask_err) == int(actod.Send_Error.OK), "ask() must return OK")
	expect(t, sync.atomic_load(&answer_y) == 42, "the reply payload must arrive")
	expect(t, sync.atomic_load(&replying_ok), "replying_to must identify the reply")
	expect(
		t,
		sync.atomic_load(&answer_token) != 0 &&
		sync.atomic_load(&answer_token) == sync.atomic_load(&asked_token),
		"the reply token must match the ask token",
	)
	expect(t, sync.atomic_load(&reply_err) == int(actod.Send_Error.OK), "reply() must return OK")

	time.sleep(600 * time.Millisecond)
	expect(
		t,
		sync.atomic_load(&timeout_token) == 0,
		"no Ask_Timeout may fire once the reply arrived",
	)

	expect(
		t,
		actod.send_message(responder, Probe_Reply_Misuse{marker = 1}) == .OK,
		"failed to send the misuse probe",
	)
	wait_for_int(&misuse_err, -1, 2 * time.Second)
	expect(
		t,
		sync.atomic_load(&misuse_err) == int(actod.Send_Error.NOT_ASKED),
		"reply() to a plain message must return NOT_ASKED",
	)

	off_actor_err := actod.reply(Ask_Answer{y = 0})
	expect(t, off_actor_err == .NOT_ASKED, "reply() outside an actor must return NOT_ASKED")

	actod.send_message(requester, actod.Terminate{reason = .NORMAL})
	actod.send_message(responder, actod.Terminate{reason = .NORMAL})
}

test_ask_timeout_and_late_reply :: proc(t: ^testing.T) {
	reset_test_state()

	silent_reply_err := -1
	silent_misuse_err := -1
	silent, s_ok := actod.spawn(
		"ask-silent",
		Ask_Responder_Data {
			silent = true,
			reply_err = &silent_reply_err,
			misuse_err = &silent_misuse_err,
		},
		Ask_Responder_Behaviour,
	)
	expect(t, s_ok, "failed to spawn silent responder")
	if !s_ok {
		return
	}

	asked_token: u64
	ask_err := -1
	answer_y: int
	answer_token: u64
	replying_ok: bool
	timeout_token: u64
	requester, q_ok := actod.spawn(
		"ask-timeout-requester",
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
	expect(t, q_ok, "failed to spawn requester")
	if !q_ok {
		return
	}

	expect(
		t,
		actod.send_message(requester, Do_Ask{target = silent, timeout_ms = 100, x = 1}) == .OK,
		"failed to trigger the silent ask",
	)

	start := time.now()
	for sync.atomic_load(&timeout_token) == 0 && time.diff(start, time.now()) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	expect(t, sync.atomic_load(&timeout_token) != 0, "Ask_Timeout must fire for a silent responder")
	expect(
		t,
		sync.atomic_load(&timeout_token) == sync.atomic_load(&asked_token),
		"the timeout token must match the ask token",
	)
	expect(t, sync.atomic_load(&answer_y) == 0, "no reply may arrive from a silent responder")

	late_reply_err := -1
	late_misuse_err := -1
	late, l_ok := actod.spawn(
		"ask-late",
		Ask_Responder_Data {
			delay = 400 * time.Millisecond,
			reply_err = &late_reply_err,
			misuse_err = &late_misuse_err,
		},
		Ask_Responder_Behaviour,
	)
	expect(t, l_ok, "failed to spawn late responder")
	if !l_ok {
		return
	}

	sync.atomic_store(&timeout_token, 0)
	sync.atomic_store(&asked_token, 0)

	expect(
		t,
		actod.send_message(requester, Do_Ask{target = late, timeout_ms = 50, x = 5}) == .OK,
		"failed to trigger the late ask",
	)

	wait_for_int(&late_reply_err, -1, 3 * time.Second)
	expect(
		t,
		sync.atomic_load(&late_reply_err) == int(actod.Send_Error.OK),
		"a late reply() still sends fine from the responder",
	)

	time.sleep(300 * time.Millisecond)
	expect(t, sync.atomic_load(&timeout_token) != 0, "Ask_Timeout must fire before the late reply")
	expect(t, sync.atomic_load(&answer_y) == 0, "a late reply must be dropped, not delivered")

	actod.send_message(requester, actod.Terminate{reason = .NORMAL})
	actod.send_message(silent, actod.Terminate{reason = .NORMAL})
	actod.send_message(late, actod.Terminate{reason = .NORMAL})
}
