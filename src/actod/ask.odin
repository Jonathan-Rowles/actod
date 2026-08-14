package actod

import "../../test_harness/ti"
_ :: ti
import "core:log"
import "core:time"

DEFAULT_ASK_TIMEOUT :: 5 * time.Second

Ask_Token :: distinct u64

Ask_Timeout :: struct {
	token: Ask_Token,
}

@(init)
init_ask_messages :: proc "contextless" () {
	register_message_type(Ask_Timeout)
}

@(require_results)
ask :: #force_inline proc(
	to: PID,
	content: $T,
	timeout: time.Duration = DEFAULT_ASK_TIMEOUT,
	loc := #caller_location,
) -> (
	Ask_Token,
	Send_Error,
) {
	when ODIN_TEST {
		if token, err, ok := ti.intercept_ask(u64(to), content, timeout); ok {
			return Ask_Token(token), Send_Error(err)
		}
	}
	ctx := current_actor_context
	if ctx == nil {
		log.errorf("ask() must be called from within an actor", location = loc)
		return 0, .NOT_ASKED
	}

	timer_id, timer_err := set_timer(timeout, false, loc)
	if timer_err != .OK do return 0, timer_err

	token := ctx.next_ask_token + 1
	v := content
	info := get_validated_message_info_ptr(T, loc)
	err := send_message_impl(to, &v, size_of(T), typeid_of(T), info, .User, loc, token)
	if err != .OK {
		_ = cancel_timer(timer_id, loc)
		return 0, err
	}

	ctx.next_ask_token = token
	ctx.pending_asks[token] = timer_id
	ctx.timer_asks[timer_id] = token
	return Ask_Token(token), .OK
}

@(require_results)
reply :: #force_inline proc(content: $T, loc := #caller_location) -> Send_Error {
	when ODIN_TEST {
		if err, ok := ti.intercept_reply(content); ok do return Send_Error(err)
	}
	ctx := current_actor_context
	if ctx == nil || ctx.current_ask_token == 0 do return .NOT_ASKED

	v := content
	info := get_validated_message_info_ptr(T, loc)
	return send_message_impl(
		ctx.current_ask_from,
		&v,
		size_of(T),
		typeid_of(T),
		info,
		.User,
		loc,
		ctx.current_ask_token | ASK_REPLY_BIT,
	)
}

@(require_results)
replying_to :: proc() -> (Ask_Token, bool) {
	when ODIN_TEST {
		if token, replying, ok := ti.intercept_replying_to(); ok {
			return Ask_Token(token), replying
		}
	}
	ctx := current_actor_context
	if ctx == nil || ctx.current_reply_token == 0 do return 0, false
	return Ask_Token(ctx.current_reply_token), true
}

@(private)
remove_ask_timer_registration :: proc(ctx: ^Actor_Context, timer_id: u32) {
	for i := 0; i < len(ctx.timers); i += 1 {
		if ctx.timers[i] == Timer_Registration(timer_id) {
			unordered_remove(&ctx.timers, i)
			break
		}
	}
}

@(private)
deliver_user_message :: #force_inline proc(actor: ^Actor($T), msg: ^Message, data: any) {
	ctx := current_actor_context
	if ctx == nil {
		actor.handle_message(actor.data, msg.from, data)
		return
	}

	token, _ := message_ask_token(msg)
	if token == 0 && !ctx.ask_dirty && len(ctx.timer_asks) == 0 {
		actor.handle_message(actor.data, msg.from, data)
		return
	}

	deliver_user_message_ask(actor, msg, data, ctx)
}

@(private)
deliver_user_message_ask :: #force_no_inline proc(
	actor: ^Actor($T),
	msg: ^Message,
	data: any,
	ctx: ^Actor_Context,
) {
	if ctx.ask_dirty {
		ctx.current_ask_token = 0
		ctx.current_ask_from = 0
		ctx.current_reply_token = 0
		ctx.ask_dirty = false
	}

	token, is_reply := message_ask_token(msg)
	if token == 0 {
		if len(ctx.timer_asks) > 0 && data.id == typeid_of(Timer_Tick) {
			tick := (cast(^Timer_Tick)data.data)^
			if ask_token, pending := ctx.timer_asks[tick.id]; pending {
				delete_key(&ctx.timer_asks, tick.id)
				delete_key(&ctx.pending_asks, ask_token)
				remove_ask_timer_registration(ctx, tick.id)
				timed_out := Ask_Timeout {
					token = Ask_Token(ask_token),
				}
				actor.handle_message(actor.data, msg.from, timed_out)
				return
			}
		}
		actor.handle_message(actor.data, msg.from, data)
		return
	}

	if is_reply {
		timer_id, pending := ctx.pending_asks[token]
		if !pending {
			log.debugf("dropping late reply %v for ask %d from %v", data.id, token, msg.from)
			return
		}
		delete_key(&ctx.pending_asks, token)
		delete_key(&ctx.timer_asks, timer_id)
		_ = cancel_timer(timer_id)
		ctx.current_reply_token = token
		ctx.ask_dirty = true
		actor.handle_message(actor.data, msg.from, data)
		ctx.current_reply_token = 0
		ctx.ask_dirty = false
		return
	}

	ctx.current_ask_token = token
	ctx.current_ask_from = msg.from
	ctx.ask_dirty = true
	actor.handle_message(actor.data, msg.from, data)
	ctx.current_ask_token = 0
	ctx.current_ask_from = 0
	ctx.ask_dirty = false
}
