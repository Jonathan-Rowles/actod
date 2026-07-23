package actod

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:sync"

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
send_to_actor_impl :: proc(
	to: PID,
	actor: ^Actor(int),
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	priority: Message_Priority,
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
		result := push_to_mailbox(actor, msg, to, int(priority), loc)
		if result != .OK && msg.content != nil && msg.content != INLINE_NEEDS_FIXUP {
			free_message(&actor.pool, msg.content)
		}
		return result
	}
}

@(private)
send_message_impl :: proc(
	to: PID,
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	priority: Message_Priority,
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
		return send_remote_impl(to, data, info, priority, sys_flags, loc)
	}

	actor_ptr, home_worker, ok := get_relaxed_loc(&global_registry, to)
	if !ok || actor_ptr == nil {
		return .ACTOR_NOT_FOUND
	}

	if current_worker != nil && home_worker == i32(current_worker.id) + 1 {
		return send_to_actor_impl(
			to,
			cast(^Actor(int))actor_ptr,
			data,
			size,
			tid,
			info,
			priority,
			class,
			loc,
		)
	}

	reclaim_pin()
	defer reclaim_unpin()
	return send_to_actor_impl(
		to,
		cast(^Actor(int))actor_ptr,
		data,
		size,
		tid,
		info,
		priority,
		class,
		loc,
	)
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
	return send_to_actor_impl(actor.pid, actor, data, size, tid, info, .NORMAL, class, loc)
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
	return send_to_actor_impl(
		actor.parent,
		parent_actor,
		data,
		size,
		tid,
		info,
		.NORMAL,
		class,
		loc,
	)
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
		err := send_to_actor_impl(
			child_pid,
			child_actor,
			data,
			size,
			tid,
			info,
			.NORMAL,
			class,
			loc,
		)
		if err != .OK {
			return err
		}
	}
	return .OK
}
