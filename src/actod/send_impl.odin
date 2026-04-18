package actod

import "base:intrinsics"
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
	$class: Msg_Class,
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

	if current_state == .STOPPING {
		when class == .System {
			alloc_err, _ := create_message_impl(&msg, &actor.pool, data, size, tid, info)
			if alloc_err == .OK {
				return .OK
			}
		}
		return .ACTOR_NOT_FOUND
	}

	alloc_err, attempted_size := create_message_impl(&msg, &actor.pool, data, size, tid, info)
	if alloc_err != .OK {
		return report_alloc_error(alloc_err, attempted_size, &actor.pool, to)
	}

	when class == .System {
		if !mpsc_push(&actor.system_mailbox, msg) {
			log.panicf("Couldn't send system message to %v", to)
		}
		wake_actor(actor)
		handle_set_message_stats(msg, to)
		return .OK
	} else {
		result := push_to_mailbox(actor, msg, to, get_send_priority())
		if result != .OK {
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
	$class: Msg_Class,
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
		return send_remote_impl(to, data, info)
	}

	actor_ptr := get_relaxed(&global_registry, to)
	if actor_ptr == nil {
		return .ACTOR_NOT_FOUND
	}
	return send_to_actor_impl(to, cast(^Actor(int))actor_ptr, data, size, tid, info, class)
}

@(private)
send_self_impl :: proc(
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
) -> Send_Error {
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return .ACTOR_NOT_FOUND
	}
	return send_to_actor_impl(actor.pid, actor, data, size, tid, info, class)
}

@(private)
send_message_to_parent_impl :: proc(
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
) -> bool {
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return false
	}
	parent_actor, got_parent := get_actor_from_pointer(get(&global_registry, actor.parent))
	if !got_parent {
		return false
	}
	return send_to_actor_impl(actor.parent, parent_actor, data, size, tid, info, class) == .OK
}

@(private)
send_message_to_children_impl :: proc(
	data: rawptr,
	size: int,
	tid: typeid,
	info: ^Message_Type_Info,
	$class: Msg_Class,
) -> bool {
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return false
	}
	for child_pid in actor.children {
		child_actor, child_ok := get_actor_from_pointer(get(&global_registry, child_pid))
		if !child_ok {
			return false
		}
		if send_to_actor_impl(child_pid, child_actor, data, size, tid, info, class) != .OK {
			return false
		}
	}
	return true
}
