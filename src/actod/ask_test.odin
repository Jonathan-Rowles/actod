package actod

import "../../test_harness/ti"
import "core:testing"

@(private = "file")
Reply_Recorder :: struct {
	replies:    int,
	last_from:  PID,
	last_value: int,
}

@(private = "file")
record_reply :: proc(data: rawptr, from: PID, content: any) {
	recorder := cast(^Reply_Recorder)data
	value, is_int := content.(int)
	if !is_int do return
	recorder.replies += 1
	recorder.last_from = from
	recorder.last_value = value
}

@(private = "file")
deliver_reply :: proc(
	actor: ^Actor,
	ctx: ^Actor_Context,
	from: PID,
	token: u64,
	value: int,
) {
	payload := value
	msg := Message {
		from    = from,
		content = &payload,
	}
	msg.ask_token = token | ASK_REPLY_BIT
	deliver_user_message_ask(actor, &msg, payload, ctx)
}

@(test)
test_reply_is_delivered_only_from_the_asked_pid :: proc(t: ^testing.T) {
	timers: [dynamic]ti.Captured_Timer
	defer delete(timers)
	intercept := ti.Test_Intercept {
		timer_capture = &timers,
	}
	ti.test_intercept = &intercept
	defer ti.test_intercept = nil

	recorder: Reply_Recorder
	actor := new(Actor)
	defer free(actor)
	actor.data = &recorder
	actor.handle_message = record_reply

	ctx := new(Actor_Context)
	defer free(ctx)
	ctx.pending_asks = make(map[u64]Pending_Ask)
	defer delete(ctx.pending_asks)
	ctx.timer_asks = make(map[u32]u64)
	defer delete(ctx.timer_asks)

	asked := pack_pid(Handle{idx = 7, gen = 1}, 2)
	impostor_on_same_node := pack_pid(Handle{idx = 8, gen = 1}, 2)
	same_handle_on_other_node := pack_pid(Handle{idx = 7, gen = 1}, 3)

	token := u64(1)
	timer_id := u32(11)
	ctx.pending_asks[token] = Pending_Ask {
		timer_id = timer_id,
		asked    = asked,
	}
	ctx.timer_asks[timer_id] = token

	deliver_reply(actor, ctx, impostor_on_same_node, token, 999)
	testing.expect_value(t, recorder.replies, 0)

	deliver_reply(actor, ctx, same_handle_on_other_node, token, 998)
	testing.expect_value(t, recorder.replies, 0)
	testing.expect(
		t,
		token in ctx.pending_asks,
		"a forged reply must leave the ask pending",
	)

	deliver_reply(actor, ctx, asked, token, 42)
	testing.expect_value(t, recorder.replies, 1)
	testing.expect_value(t, recorder.last_from, asked)
	testing.expect_value(t, recorder.last_value, 42)
	testing.expect(
		t,
		token not_in ctx.pending_asks,
		"the real reply must settle the ask",
	)
	testing.expect(
		t,
		timer_id not_in ctx.timer_asks,
		"the real reply must release the ask timer",
	)
}
