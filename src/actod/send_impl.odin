package actod

import "../pkgs/coro"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:sync"
import "core:time"

Msg_Class :: enum u8 {
	User,
	System,
}

@(private)
create_message_impl :: proc(
	msg: ^Message,
	pool: ^Pool,
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
) -> (
	Alloc_Error,
	int,
) {
	if info.flags == {} {
		if size <= INLINE_MESSAGE_SIZE {
			msg.inline_type = tid
			msg.content = nil
			intrinsics.mem_copy_non_overlapping(&msg.inline_data[0], data, size)
			return .OK, 0
		}

		aligned_size := mem.align_forward_int(TYPE_HEADER_SIZE + size, CACHE_LINE_SIZE)

		buffer, alloc_err := message_alloc(pool, aligned_size)
		if alloc_err != .OK {
			return alloc_err, aligned_size
		}

		header := cast(^Type_Header)buffer
		header.type_id = tid
		header.size = aligned_size

		data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
		intrinsics.mem_copy_non_overlapping(data_ptr, data, size)

		msg.content = buffer
		msg.inline_type = nil
		return .OK, 0
	}

	variable_size := calculate_variable_data_size(data, info)
	total_message_size := size + variable_size

	if total_message_size <= INLINE_MESSAGE_SIZE {
		msg.inline_type = tid
		msg.content = INLINE_NEEDS_FIXUP
		intrinsics.mem_copy_non_overlapping(&msg.inline_data[0], data, size)
		copy_variable_data(&msg.inline_data[0], &msg.inline_data[0], data, info, size)
		return .OK, 0
	}

	aligned_size := mem.align_forward_int(TYPE_HEADER_SIZE + size + variable_size, CACHE_LINE_SIZE)

	buffer, alloc_err := message_alloc(pool, aligned_size)
	if alloc_err != .OK {
		return alloc_err, aligned_size
	}

	header := cast(^Type_Header)buffer
	header.type_id = tid
	header.size = aligned_size

	data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
	intrinsics.mem_copy_non_overlapping(data_ptr, data, size)
	copy_variable_data(buffer, data_ptr, data, info, TYPE_HEADER_SIZE + size)

	msg.content = buffer
	msg.inline_type = nil
	return .OK, 0
}

@(private)
release_undelivered :: #force_inline proc(target: ^Actor(int), msg: ^Message, msg_ready: bool) {
	if msg_ready && msg.content != nil && msg.content != INLINE_NEEDS_FIXUP {
		free_message(&target.pool, msg.content)
	}
}

@(private)
send_user_backpressure :: #force_no_inline proc(
	to: PID,
	msg: ^Message,
	msg_ready: bool,
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	loc := #caller_location,
) -> Send_Error {
	entered_pinned := tls_reclaim_depth > 0
	if entered_pinned do reclaim_unpin()

	result := send_user_backpressure_loop(to, msg, msg_ready, data, size, tid, info, loc)

	if entered_pinned do reclaim_pin()
	return result
}

@(private)
send_user_backpressure_loop :: proc(
	to: PID,
	msg: ^Message,
	initial_msg_ready: bool,
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	loc := #caller_location,
) -> Send_Error {
	co := coro.running()
	msg_ready := initial_msg_ready
	observed_read: u64
	observed_frees: u64
	have_observation := false
	stall_start := time.tick_now()

	for {
		if co != nil {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		} else {
			time.sleep(SEND_RETRY_DELAY)
		}

		reclaim_pin()
		fresh, ok := get_relaxed(&global_registry, to)
		if !ok || fresh == nil {
			reclaim_unpin()
			return .ACTOR_NOT_FOUND
		}
		target := cast(^Actor(int))fresh
		state := sync.atomic_load(&target.state)
		if state != .RUNNING && state != .IDLE && state != .INIT {
			release_undelivered(target, msg, msg_ready)
			reclaim_unpin()
			return .ACTOR_NOT_FOUND
		}

		current_read := sync.atomic_load_explicit(&target.mailbox.read_index, .Relaxed)
		current_frees := sync.atomic_load_explicit(&target.pool.write_index, .Relaxed)

		if !msg_ready {
			pool_allocs := sync.atomic_load_explicit(&target.pool.read_index, .Relaxed)
			pool_has_room :=
				current_frees != pool_allocs ||
				sync.atomic_load_explicit(&target.pool.allocated_count, .Relaxed) <
					target.pool.max_pages
			if pool_has_room {
				alloc_err, attempted_size := create_message_impl(
					msg,
					&target.pool,
					data,
					size,
					tid,
					info,
				)
				if alloc_err == .OK {
					msg_ready = true
				} else if alloc_err != .POOL_EXHAUSTED && alloc_err != .ALLOC_CONTENDED {
					err := report_alloc_error(alloc_err, attempted_size, &target.pool, to, loc)
					reclaim_unpin()
					return err
				}
			}
		}

		if msg_ready {
			write_idx := sync.atomic_load_explicit(&target.mailbox.write_index, .Relaxed)
			spin_budget := THREAD_SEND_SPIN_TRIES if co == nil else 1
			for spin := 0; spin < spin_budget; spin += 1 {
				if write_idx - current_read <= target.mailbox.mask &&
				   mpsc_push(&target.mailbox, msg^) {
					wake_actor(target)
					handle_set_message_stats(msg.from, to)
					reclaim_unpin()
					return .OK
				}
				intrinsics.cpu_relax()
				write_idx = sync.atomic_load_explicit(&target.mailbox.write_index, .Relaxed)
				current_read = sync.atomic_load_explicit(&target.mailbox.read_index, .Relaxed)
			}
		}

		if sync.atomic_load(&NODE.shutting_down) {
			release_undelivered(target, msg, msg_ready)
			reclaim_unpin()
			return .SYSTEM_SHUTTING_DOWN
		}

		if !have_observation || current_read != observed_read || current_frees != observed_frees {
			observed_read = current_read
			observed_frees = current_frees
			have_observation = true
			stall_start = time.tick_now()
		} else if time.tick_since(stall_start) > SEND_STALL_TIMEOUT {
			release_undelivered(target, msg, msg_ready)
			reclaim_unpin()
			log.errorf(
				"send to %s failed: receiver made no progress for %v, its mailbox or message pool is still full",
				actor_origin(to),
				SEND_STALL_TIMEOUT,
				location = loc,
			)
			return .RECEIVER_BACKLOGGED
		}

		reclaim_unpin()
	}
}

@(private)
send_to_actor_impl :: proc(
	to: PID,
	actor: ^Actor(int),
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
	loc := #caller_location,
) -> Send_Error {
	when class == .User {
		if sync.atomic_load_explicit(&NODE.shutting_down, .Relaxed) {
			return .SYSTEM_SHUTTING_DOWN
		}
	}

	current_state := sync.atomic_load(&actor.state)

	when class == .System {
		if current_state == .TERMINATED ||
		   current_state == .THREAD_STOPPED ||
		   current_state == .STOPPING {
			return .ACTOR_NOT_FOUND
		}
	} else {
		if current_state != .RUNNING && current_state != .IDLE && current_state != .INIT {
			return .ACTOR_NOT_FOUND
		}
	}

	msg: Message
	msg.from = get_self_pid()

	if info.flags == {} && size <= INLINE_MESSAGE_SIZE {
		msg.inline_type = tid
		msg.content = nil
		intrinsics.mem_copy_non_overlapping(&msg.inline_data[0], data, size)
	} else {
		alloc_err, attempted_size := create_message_impl(&msg, &actor.pool, data, size, tid, info)
		when class == .User {
			if alloc_err == .POOL_EXHAUSTED || alloc_err == .ALLOC_CONTENDED {
				return send_user_backpressure(to, &msg, false, data, size, tid, info, loc)
			}
		}
		if alloc_err != .OK {
			return report_alloc_error(alloc_err, attempted_size, &actor.pool, to, loc)
		}
	}

	when class == .System {
		if !mpsc_push(&actor.system_mailbox, msg) {
			log.errorf(
				"system mailbox of %s is full (%d slots), dropping %v, the receiver is not draining",
				actor_origin(to),
				SYSTEM_MAILBOX_SIZE,
				tid,
				location = loc,
			)
			if msg.content != nil && msg.content != INLINE_NEEDS_FIXUP {
				free_message(&actor.pool, msg.content)
			}
			return .RECEIVER_BACKLOGGED
		}
		wake_actor(actor)
		handle_set_message_stats(msg.from, to)
		return .OK
	} else {
		return push_to_mailbox(actor, msg, to, loc)
	}
}

@(private)
send_message_impl :: proc(
	to: PID,
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
	loc := #caller_location,
) -> Send_Error {
	if to == 0 {
		return .ACTOR_NOT_FOUND
	}

	when class == .User {
		if sync.atomic_load_explicit(&NODE.shutting_down, .Relaxed) {
			return .SYSTEM_SHUTTING_DOWN
		}
	}

	if !is_local_pid(to) {
		sys_flags: Network_Message_Flags
		when class == .System {
			sys_flags = {.SYSTEM}
		}
		return send_remote_impl(to, data, info, sys_flags, loc)
	}

	actor_ptr, home_worker, ok := get_relaxed_loc(&global_registry, to)
	if !ok || actor_ptr == nil {
		return .ACTOR_NOT_FOUND
	}

	if current_worker != nil && home_worker == i32(current_worker.id) + 1 {
		return send_to_actor_impl(to, cast(^Actor(int))actor_ptr, data, size, tid, info, class, loc)
	}

	reclaim_pin()
	defer reclaim_unpin()
	return send_to_actor_impl(to, cast(^Actor(int))actor_ptr, data, size, tid, info, class, loc)
}

@(private)
log_send_outside_actor :: proc(
	send_proc: string,
	tid: typeid,
	loc: runtime.Source_Code_Location,
) {
	context.logger = diagnostic_logger(context.logger)
	log.errorf("%s(%v) failed: must be called from inside an actor", send_proc, tid, location = loc)
}

@(private)
send_self_impl :: proc(
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
	loc := #caller_location,
) -> Send_Error {
	if current_actor_context == nil {
		log_send_outside_actor("send_self", tid, loc)
		return .ACTOR_NOT_FOUND
	}
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return .ACTOR_NOT_FOUND
	}
	return send_to_actor_impl(actor.pid, actor, data, size, tid, info, class, loc)
}

@(private)
send_message_to_parent_impl :: proc(
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
	loc := #caller_location,
) -> Send_Error {
	if current_actor_context == nil {
		log_send_outside_actor("send_message_to_parent", tid, loc)
		return .ACTOR_NOT_FOUND
	}
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return .ACTOR_NOT_FOUND
	}
	if actor.parent == 0 {
		log.errorf(
			"send_message_to_parent(%v) failed: actor '%s' has no parent (it was spawned without one)",
			tid,
			actor.name,
			location = loc,
		)
		return .ACTOR_NOT_FOUND
	}
	parent_actor, got_parent := get_actor_from_pointer(get(&global_registry, actor.parent))
	if !got_parent {
		log.errorf(
			"send_message_to_parent(%v) failed: parent %v of actor '%s' is no longer alive",
			tid,
			actor.parent,
			actor.name,
			location = loc,
		)
		return .ACTOR_NOT_FOUND
	}
	return send_to_actor_impl(actor.parent, parent_actor, data, size, tid, info, class, loc)
}

@(private)
send_message_to_children_impl :: proc(
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
	loc := #caller_location,
) -> Send_Error {
	if current_actor_context == nil {
		log_send_outside_actor("send_message_to_children", tid, loc)
		return .ACTOR_NOT_FOUND
	}
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return .ACTOR_NOT_FOUND
	}
	for child_pid in actor.children {
		child_actor, child_ok := get_actor_from_pointer(get(&global_registry, child_pid))
		if !child_ok {
			log.errorf(
				"send_message_to_children(%v) stopped: child %v of actor '%s' is no longer alive",
				tid,
				child_pid,
				actor.name,
				location = loc,
			)
			return .ACTOR_NOT_FOUND
		}
		err := send_to_actor_impl(child_pid, child_actor, data, size, tid, info, class, loc)
		if err != .OK {
			return err
		}
	}
	return .OK
}
