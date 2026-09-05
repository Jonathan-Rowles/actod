package actod

import "core:log"
import "core:time"

@(private)
remove_child_from_supervisor :: proc(actor: ^Actor($T), child_pid: PID, child_index: int) {
	actual_index := child_index
	if actual_index == -1 {
		for pid, idx in actor.children {
			if pid == child_pid {
				actual_index = idx
				break
			}
		}
		if actual_index == -1 do return
	}

	ordered_remove(&actor.children, actual_index)

	if actual_index < len(actor.opts.children) do ordered_remove(&actor.opts.children, actual_index)

	delete_key(&actor.child_restarts, child_pid)

	for j := actual_index; j < len(actor.children); j += 1 {
		remaining_pid := actor.children[j]
		if info, has := &actor.child_restarts[remaining_pid]; has do info.child_index = j
	}
}

@(private)
handle_remove_child :: proc(actor: ^Actor($T), msg: Remove_Child) {
	for child_pid, idx in actor.children {
		if child_pid == msg.child_pid {
			remove_child_from_supervisor(actor, child_pid, idx)

			child_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, child_pid))
			if ok {
				term_msg := Terminate {
					reason = .SHUTDOWN,
				}
				send(child_pid, term_msg, child_actor)
			}

			log.infof("Removed child %d from parent %d", child_pid, actor.pid)
			return
		}
	}

	log.warnf("Attempted to remove unknown child %d from parent %d", msg.child_pid, actor.pid)
}

@(private)
handle_add_child :: proc(actor: ^Actor($T), msg: Add_Child) {
	child_pid: PID
	ok: bool

	if msg.existing_pid != 0 {
		// Adopting an existing actor as a child
		child_pid = msg.existing_pid

		for existing_child in actor.children {
			if existing_child == child_pid {
				log.warnf("Child %d already exists in parent %d", child_pid, actor.pid)
				return
			}
		}

		if is_local_pid(child_pid) {
			child_actor, child_ok := get_actor_from_pointer(get(&NODE.actor_registry, child_pid))
			if !child_ok {
				log.errorf("Cannot adopt child %d - actor not found", child_pid)
				return
			}

			set_parent_msg := Set_Parent {
				new_parent = actor.pid,
				spawn_func = msg.spawn_func,
			}
			if send(child_pid, set_parent_msg, child_actor) != .OK {
				log.errorf("Failed to send Set_Parent message to child %d", child_pid)
				return
			}
		}

		append(&actor.children, child_pid)
		ok = true
	} else {
		child_pid, ok = msg.spawn_func("", actor.pid)
		if !ok {
			log.errorf("Failed to spawn child for parent %d", actor.pid)
			return
		}

		if !is_local_pid(child_pid) do append(&actor.children, child_pid)
	}

	if actor.opts.children == nil do actor.opts.children = make([dynamic]SPAWN)

	append(&actor.opts.children, msg.spawn_func)

	child_node_id: Node_ID = 0
	if !is_local_pid(child_pid) do child_node_id = get_node_id(child_pid)

	child_index := len(actor.children) - 1

	actor.child_restarts[child_pid] = Restart_Info {
		count                = 0,
		first_restart        = now(),
		last_restart         = now(),
		child_index          = child_index,
		spawn_func_name_hash = msg.spawn_func_name_hash,
		node_id              = child_node_id,
	}

	if actor.behaviour.on_child_started != nil {
		actor.behaviour.on_child_started(actor.data, child_pid)
	}

	log.infof(
		"Dynamically added child %d to parent %d (node_id=%d)",
		child_pid,
		actor.pid,
		child_node_id,
	)
}

@(private)
handle_set_parent :: proc(actor: ^Actor($T), msg: Set_Parent) {
	old_parent := actor.parent

	// If we had an old parent, notify it to remove us
	if old_parent != 0 {
		old_parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, old_parent))
		if ok {
			remove_msg := Remove_Child {
				child_pid = actor.pid,
			}
			send(old_parent, remove_msg, old_parent_actor)
		}
	}

	actor.parent = msg.new_parent

	if msg.new_parent == 0 {
		log.infof("Actor %d removed parent (was %d)", actor.pid, old_parent)
		return
	}

	// If we have a new parent, notify it to add us
	new_parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, msg.new_parent))
	if !ok {
		actor.parent = old_parent
		log.errorf(
			"Failed to set parent %d for actor %d - parent not found",
			msg.new_parent,
			actor.pid,
		)
	}

	add_msg := Add_Child {
		spawn_func   = msg.spawn_func,
		existing_pid = actor.pid,
	}

	if send(msg.new_parent, add_msg, new_parent_actor) == .OK {
		log.infof("Actor %d changed parent from %d to %d", actor.pid, old_parent, msg.new_parent)
	} else {
		actor.parent = old_parent
		log.errorf("Failed to notify new parent %d about child %d", msg.new_parent, actor.pid)
	}
}

@(private)
handle_child_termination :: proc(actor: ^Actor($T), msg: Actor_Stopped) {
	if NODE.shutting_down {
		log.infof(
			"System is shutting down, not restarting child %s (PID %d)",
			msg.child_name,
			msg.child_pid,
		)
		return
	}

	restart_info, has_info := &actor.child_restarts[msg.child_pid]
	if !has_info {
		if msg.reason != .NORMAL {
			log.warnf(
				"Received Actor_Stopped for unknown child %d (reason=%v)",
				msg.child_pid,
				msg.reason,
			)
		}
		return
	}

	child_index := msg.child_index
	if child_index == -1 do child_index = restart_info.child_index

	if msg.reason == .SHUTDOWN {
		log.infof(
			"Child %s (PID %d) terminated with reason SHUTDOWN, not restarting",
			msg.child_name,
			msg.child_pid,
		)
		if actor.behaviour.on_child_terminated != nil {
			actor.behaviour.on_child_terminated(actor.data, msg.child_pid, msg.reason, false)
		}
		remove_child_from_supervisor(actor, msg.child_pid, child_index)
		return
	}

	should_restart := false
	switch actor.opts.restart_policy {
	case .PERMANENT:
		should_restart = true
	case .TRANSIENT:
		should_restart = msg.reason == .ABNORMAL
	case .TEMPORARY:
		should_restart = false
	}

	if !should_restart {
		log.infof(
			"Child %s (PID %d) terminated with reason %v, not restarting due to policy",
			msg.child_name,
			msg.child_pid,
			msg.reason,
		)
		if actor.behaviour.on_child_terminated != nil {
			actor.behaviour.on_child_terminated(actor.data, msg.child_pid, msg.reason, false)
		}
		remove_child_from_supervisor(actor, msg.child_pid, child_index)
		return
	}

	now := now()
	if time.diff(restart_info.first_restart, now) > actor.opts.restart_window {
		restart_info.count = 0
		restart_info.first_restart = now
	}

	restart_info.count += 1
	restart_info.last_restart = now

	if restart_info.count > actor.opts.max_restarts {
		log.errorf(
			"Child %s (PID %v) failed more than max_restarts (%d) times within %v, giving up on it",
			msg.child_name,
			msg.child_pid,
			actor.opts.max_restarts,
			actor.opts.restart_window,
		)
		if actor.behaviour.on_max_restarts_exceeded != nil {
			actor.behaviour.on_max_restarts_exceeded(actor.data, msg.child_pid)
		}
		remove_child_from_supervisor(actor, msg.child_pid, child_index)
		return
	}

	if actor.behaviour.on_child_terminated != nil {
		actor.behaviour.on_child_terminated(actor.data, msg.child_pid, msg.reason, true)
	}

	// Execute restart strategy
	switch actor.opts.supervision_strategy {
	case .ONE_FOR_ONE:
		restart_child(actor, child_index, msg.child_pid)

	case .ONE_FOR_ALL:
		pids_to_wait: [dynamic]PID
		defer delete(pids_to_wait)

		for child_pid in actor.children {
			if child_pid != msg.child_pid && child_pid != 0 {
				if terminate_actor(child_pid, .KILLED) do append(&pids_to_wait, child_pid)
			}
		}
		wait_for_pids(pids_to_wait[:])

		for idx in 0 ..< len(actor.opts.children) {
			restart_child(actor, idx, actor.children[idx])
		}

	case .REST_FOR_ONE:
		pids_to_wait: [dynamic]PID
		defer delete(pids_to_wait)

		for idx in child_index ..< len(actor.children) {
			if idx != child_index && actor.children[idx] != 0 {
				if terminate_actor(actor.children[idx], .KILLED) {
					append(&pids_to_wait, actor.children[idx])
				}
			}
		}
		wait_for_pids(pids_to_wait[:])

		for idx in child_index ..< len(actor.opts.children) {
			restart_child(actor, idx, actor.children[idx])
		}
	}
}

@(private)
restart_child :: proc(actor: ^Actor($T), child_index: int, old_pid: PID) {
	if child_index >= len(actor.opts.children) {
		log.errorf("Invalid child index %d", child_index)
		return
	}

	restart_info, has_info := actor.child_restarts[old_pid]
	if !has_info {
		log.errorf("No restart info for child %d", old_pid)
		return
	}

	new_pid: PID
	ok: bool

	remote_child := restart_info.node_id != 0 && restart_info.node_id != NODE.node_id

	if remote_child && restart_info.spawn_func_name_hash != 0 {
		// Adopted remote child with no local spawn closure: respawn by registered name.
		node_name, name_ok := get_node_name(restart_info.node_id)
		if !name_ok {
			log.errorf("Cannot restart child - unknown node %d", restart_info.node_id)
			return
		}

		spawn_func_name, found := get_spawn_func_name_by_hash(restart_info.spawn_func_name_hash)
		if !found {
			log.errorf("Unknown spawn function hash %x", restart_info.spawn_func_name_hash)
			return
		}

		new_pid, ok = spawn_remote_impl(
			spawn_func_name,
			get_actor_name(old_pid),
			node_name,
			actor.pid,
			SPAWN_REMOTE_TIMEOUT,
			false,
		)
	} else {
		// Local child, or a remote child added via a SPAWN closure that spawns it remotely.
		new_pid, ok = actor.opts.children[child_index]("", actor.pid)
	}

	if !ok {
		log.errorf("Failed to restart child at index %d", child_index)
		return
	}

	if len(actor.children) > 0 && actor.children[len(actor.children) - 1] == new_pid {
		pop(&actor.children)
	}
	actor.children[child_index] = new_pid
	restart_info.child_index = child_index
	delete_key(&actor.child_restarts, old_pid)
	actor.child_restarts[new_pid] = restart_info

	if actor.behaviour.on_child_restarted != nil {
		actor.behaviour.on_child_restarted(actor.data, old_pid, new_pid, restart_info.count)
	}
	if actor.behaviour.on_child_started != nil {
		actor.behaviour.on_child_started(actor.data, new_pid)
	}

	log.infof(
		"Restarted child at index %d: old PID %d -> new PID %d (node %d)",
		child_index,
		old_pid,
		new_pid,
		restart_info.node_id,
	)
}
