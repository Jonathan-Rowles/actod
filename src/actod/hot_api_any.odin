package actod

import "base:intrinsics"
import "core:log"
import "core:sync"

send_message_any :: proc(to: PID, content: any, loc := #caller_location) -> Send_Error {
	@(static) sentinel: Message_Type_Info
	info, ok := get_type_info_ptr(content.id, loc)
	if !ok do info = &sentinel
	size := type_info_of(content.id).size
	return send_message_impl(to, content.data, size, content.id, info, .User, loc)
}

broadcast_any :: proc(content: any, loc := #caller_location) {
	self_pid := get_self_pid()
	actor_type := get_pid_actor_type(self_pid)

	if actor_type == ACTOR_TYPE_UNTYPED {
		log.errorf(
			"broadcast(%v) dropped: actor %s is untyped. Set actor_type on its Actor_Behaviour to broadcast",
			content.id,
			actor_origin(self_pid),
			location = loc,
		)
		return
	}

	list := &NODE.type_subscribers[actor_type]
	block := load_subscriber_block(list)
	if block == nil do return
	n := min(sync.atomic_load_explicit(&list.local_count, .Acquire), block.capacity)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(&block.pids[i], .Acquire))
		if pid != 0 && pid != self_pid do send_message_any(pid, content, loc)
	}
}

publish_any :: proc(topic: ^Topic, content: any, loc := #caller_location) {
	if topic == nil {
		log.errorf("publish(%v) dropped: topic is nil", content.id, location = loc)
		return
	}
	self_pid := get_self_pid()
	n := sync.atomic_load_explicit(&topic.count, .Acquire)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[i], .Acquire))
		if pid != 0 && pid != self_pid do send_message_any(pid, content, loc)
	}
}

Raw_Spawn_Behaviour :: struct {
	handle_message:           rawptr,
	init_proc:                rawptr,
	terminate_proc:           rawptr,
	on_idle:                  rawptr,
	on_wake:                  rawptr,
	actor_type:               Actor_Type,
	on_child_started:         rawptr,
	on_child_terminated:      rawptr,
	on_child_restarted:       rawptr,
	on_max_restarts_exceeded: rawptr,
}

spawn_from_raw :: proc(
	name: string,
	data_ptr: rawptr,
	data_size: int,
	behaviour: Raw_Spawn_Behaviour,
	opts: Actor_Config,
	parent_pid: PID,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	state := Erased_State {
		ptr   = data_ptr,
		size  = data_size,
		align = align_of(int),
	}
	erased := Erased_Behaviour {
		handle_message           = auto_cast behaviour.handle_message,
		init                     = auto_cast behaviour.init_proc,
		terminate                = auto_cast behaviour.terminate_proc,
		on_idle                  = auto_cast behaviour.on_idle,
		on_wake                  = auto_cast behaviour.on_wake,
		actor_type               = behaviour.actor_type,
		on_child_started         = auto_cast behaviour.on_child_started,
		on_child_terminated      = auto_cast behaviour.on_child_terminated,
		on_child_restarted       = auto_cast behaviour.on_child_restarted,
		on_max_restarts_exceeded = auto_cast behaviour.on_max_restarts_exceeded,
	}
	return spawn_erased(name, state, erased, DEFAULT_MAIL_BOX_SIZE, opts, parent_pid, loc)
}

spawn_child_from_raw :: proc(
	name: string,
	data_ptr: rawptr,
	data_size: int,
	behaviour: Raw_Spawn_Behaviour,
	opts: Actor_Config,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	self_pid := get_self_pid()
	if self_pid == 0 {
		panic_at(
			loc,
			"spawn_child('%s'): must be called from inside an actor. Use spawn() with an explicit parent_pid outside one",
			name,
		)
	}
	return spawn_from_raw(name, data_ptr, data_size, behaviour, opts, self_pid, loc)
}
