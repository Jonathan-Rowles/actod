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
	register_internal_message_type(Ask_Timeout, .Local_Only)
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
	err := send_message_impl(
		to,
		&v,
		size_of(T),
		typeid_of(T),
		info,
		.User,
		loc,
		token,
	)
	if err != .OK {
		_ = cancel_timer(timer_id, loc)
		return 0, err
	}

	ctx.next_ask_token = token
	ctx.pending_asks[token] = Pending_Ask {
		timer_id = timer_id,
		asked    = to,
	}
	ctx.timer_asks[timer_id] = token
	return Ask_Token(token), .OK
}

@(require_results)
ask_to :: #force_inline proc(
	actor_name: string,
	node_name: string,
	content: $T,
	timeout: time.Duration = DEFAULT_ASK_TIMEOUT,
	loc := #caller_location,
) -> (
	Ask_Token,
	Send_Error,
) {
	when ODIN_TEST {
		if err, ok := ti.intercept_send_to(actor_name, node_name, content);
		   ok {
			return 0, Send_Error(err)
		}
	}
	ctx := current_actor_context
	if ctx == nil {
		log.errorf(
			"ask_to() must be called from within an actor",
			location = loc,
		)
		return 0, .NOT_ASKED
	}

	timer_id, timer_err := set_timer(timeout, false, loc)
	if timer_err != .OK do return 0, timer_err

	token := ctx.next_ask_token + 1
	v := content
	info := get_validated_message_info_ptr(T, loc)
	err := send_remote_by_name_impl(
		node_name,
		actor_name,
		&v,
		info,
		loc,
		token,
	)
	if err != .OK {
		_ = cancel_timer(timer_id, loc)
		return 0, err
	}

	asked_node, _ := get_node_by_name(node_name)
	ctx.next_ask_token = token
	ctx.pending_asks[token] = Pending_Ask {
		timer_id   = timer_id,
		asked_node = asked_node,
	}
	ctx.timer_asks[timer_id] = token
	return Ask_Token(token), .OK
}

@(require_results)
reply :: #force_inline proc(
	content: $T,
	loc := #caller_location,
) -> Send_Error {
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
deliver_user_message :: #force_inline proc(
	actor: ^Actor,
	msg: ^Message,
	data: any,
) {
	ctx := current_actor_context
	if ctx == nil {
		actor.handle_message(actor.data, msg.from, data)
		return
	}

	token, _ := message_ask_token(msg)
	if token == 0 && !ctx.ask_dirty {
		if data.id != typeid_of(Timer_Tick) || len(ctx.timer_asks) == 0 {
			actor.handle_message(actor.data, msg.from, data)
			return
		}
	}

	deliver_user_message_ask(actor, msg, data, ctx)
}

@(private)
deliver_user_message_ask :: #force_no_inline proc(
	actor: ^Actor,
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
		ask, pending := ctx.pending_asks[token]
		if !pending {
			log.debugf(
				"dropping late reply %v for ask %d from %v",
				data.id,
				token,
				msg.from,
			)
			return
		}
		if ask.asked != 0 ? msg.from != ask.asked : get_node_id(msg.from) != ask.asked_node {
			log.warnf(
				"dropping reply %v for ask %d from %v, which was not asked; the ask went to %v on node %d",
				data.id,
				token,
				msg.from,
				ask.asked,
				ask.asked_node,
			)
			return
		}
		delete_key(&ctx.pending_asks, token)
		delete_key(&ctx.timer_asks, ask.timer_id)
		_ = cancel_timer(ask.timer_id)
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
