package actod

import "core:log"
import "core:sync"
import "core:time"

@(private)
find_child :: proc(actor: ^Actor, child_pid: PID) -> int {
	for child, idx in actor.children {
		if child.pid == child_pid do return idx
	}
	return -1
}

@(private)
remove_child_from_supervisor :: proc(actor: ^Actor, child_pid: PID) {
	child_index := find_child(actor, child_pid)
	if child_index == -1 do return
	sync.mutex_lock(&actor.children_lock)
	ordered_remove(&actor.children, child_index)
	sync.mutex_unlock(&actor.children_lock)
}

@(private)
record_direct_child :: proc(actor: ^Actor, child_pid: PID) {
	sync.mutex_lock(&actor.children_lock)
	defer sync.mutex_unlock(&actor.children_lock)
	append(
		&actor.children,
		Supervised_Child{pid = child_pid, restart = {first_restart = now(), last_restart = now()}},
	)
}

@(private)
record_spawned_child :: proc(actor: ^Actor, child_pid: PID, spawn_func: SPAWN) -> Node_ID {
	process_spawn_signals(actor)

	child_node_id: Node_ID = 0
	if !is_local_pid(child_pid) do child_node_id = get_node_id(child_pid)

	if child_index := find_child(actor, child_pid); child_index != -1 {
		actor.children[child_index].restart.spawn_func = spawn_func
		actor.children[child_index].restart.node_id = child_node_id
		return child_node_id
	}

	if is_local_pid(child_pid) {
		log.warnf(
			"Spawn function of %d returned %d, which is not its child, so it is not supervised",
			actor.pid,
			child_pid,
		)
		return child_node_id
	}

	sync.mutex_lock(&actor.children_lock)
	append(
		&actor.children,
		Supervised_Child {
			pid = child_pid,
			restart = {
				first_restart = now(),
				last_restart = now(),
				spawn_func = spawn_func,
				node_id = child_node_id,
			},
		},
	)
	sync.mutex_unlock(&actor.children_lock)
	return child_node_id
}

@(private)
has_restart_source :: proc(restart_info: Restart_Info) -> bool {
	remote_child := restart_info.node_id != 0 && restart_info.node_id != NODE.node_id
	return restart_info.spawn_func != nil || (remote_child && restart_info.spawn_func_name_hash != 0)
}

@(private)
handle_remove_child :: proc(actor: ^Actor, msg: Remove_Child) {
	if find_child(actor, msg.child_pid) == -1 {
		log.warnf("Attempted to remove unknown child %d from parent %d", msg.child_pid, actor.pid)
		return
	}

	remove_child_from_supervisor(actor, msg.child_pid)

	child_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, msg.child_pid))
	if ok {
		term_msg := Terminate {
			reason = .SHUTDOWN,
		}
		send(msg.child_pid, term_msg, child_actor)
	}

	log.infof("Removed child %d from parent %d", msg.child_pid, actor.pid)
}

@(private)
handle_add_child :: proc(actor: ^Actor, msg: Add_Child) {
	child_pid: PID
	child_node_id: Node_ID

	if msg.existing_pid != 0 {
		// Adopting an existing actor as a child
		child_pid = msg.existing_pid

		if existing_index := find_child(actor, child_pid); existing_index != -1 {
			if is_remote_spawn_registration(msg) {
				complete_remote_child_record(&actor.children[existing_index], msg)
				return
			}
			log.warnf("Child %d already exists in parent %d", child_pid, actor.pid)
			return
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

		if !is_local_pid(child_pid) do child_node_id = get_node_id(child_pid)

		sync.mutex_lock(&actor.children_lock)
		append(
			&actor.children,
			Supervised_Child {
				pid = child_pid,
				restart = {
					first_restart = now(),
					last_restart = now(),
					spawn_func = msg.spawn_func,
					spawn_func_name_hash = msg.spawn_func_name_hash,
					node_id = child_node_id,
				},
			},
		)
		sync.mutex_unlock(&actor.children_lock)
	} else {
		ok: bool
		child_pid, ok = msg.spawn_func("", actor.pid)
		if !ok {
			log.errorf("Failed to spawn child for parent %d", actor.pid)
			return
		}

		child_node_id = record_spawned_child(actor, child_pid, msg.spawn_func)
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
is_remote_spawn_registration :: proc(msg: Add_Child) -> bool {
	return msg.spawn_func == nil && msg.spawn_func_name_hash != 0 && !is_local_pid(msg.existing_pid)
}

@(private)
complete_remote_child_record :: proc(child: ^Supervised_Child, msg: Add_Child) {
	if child.restart.node_id == 0 do child.restart.node_id = get_node_id(child.pid)
	if !has_restart_source(child.restart) do child.restart.spawn_func_name_hash = msg.spawn_func_name_hash
}

@(private)
handle_set_parent :: proc(actor: ^Actor, msg: Set_Parent) {
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
handle_child_termination :: proc(actor: ^Actor, msg: Actor_Stopped) {
	if NODE.shutting_down {
		log.infof(
			"System is shutting down, not restarting child %s (PID %d)",
			msg.child_name,
			msg.child_pid,
		)
		return
	}

	child_index := find_child(actor, msg.child_pid)
	if child_index == -1 {
		if msg.reason != .NORMAL && msg.reason != .SHUTDOWN {
			log.warnf(
				"Received Actor_Stopped for unknown child %d (reason=%v)",
				msg.child_pid,
				msg.reason,
			)
		}
		return
	}

	if msg.reason == .SHUTDOWN {
		log.infof(
			"Child %s (PID %d) terminated with reason SHUTDOWN, not restarting",
			msg.child_name,
			msg.child_pid,
		)
		if actor.behaviour.on_child_terminated != nil {
			actor.behaviour.on_child_terminated(
				actor.data,
				msg.child_pid,
				msg.child_name,
				msg.reason,
				false,
			)
		}
		remove_child_from_supervisor(actor, msg.child_pid)
		return
	}

	should_restart := false
	switch msg.restart_policy {
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
			actor.behaviour.on_child_terminated(
				actor.data,
				msg.child_pid,
				msg.child_name,
				msg.reason,
				false,
			)
		}
		remove_child_from_supervisor(actor, msg.child_pid)
		return
	}

	restart_info := &actor.children[child_index].restart
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
			actor.behaviour.on_max_restarts_exceeded(actor.data, msg.child_pid, msg.child_name)
		}
		remove_child_from_supervisor(actor, msg.child_pid)
		return
	}

	dying_child_restartable := has_restart_source(actor.children[child_index].restart)

	if actor.behaviour.on_child_terminated != nil {
		actor.behaviour.on_child_terminated(
			actor.data,
			msg.child_pid,
			msg.child_name,
			msg.reason,
			dying_child_restartable,
		)
	}

	if !dying_child_restartable {
		remove_unrestartable_child(actor, msg.child_pid, msg.child_name)
		return
	}

	// Execute restart strategy
	switch actor.opts.supervision_strategy {
	case .ONE_FOR_ONE:
		restart_child(actor, msg.child_pid)

	case .ONE_FOR_ALL:
		stop_and_restart_children_from(actor, 0, msg.child_pid)

	case .REST_FOR_ONE:
		child_index = find_child(actor, msg.child_pid)
		if child_index == -1 do return

		stop_and_restart_children_from(actor, child_index, msg.child_pid)
	}
}

@(private)
Removed_Sibling :: struct {
	pid:       PID,
	by_policy: bool,
	name_len:  int,
	name_buf:  [STOP_SIGNAL_NAME_CAP]u8,
}

@(private)
local_restart_policy :: proc(child_pid: PID) -> (Restart_Policy, bool) {
	child_ptr, active := get(&NODE.actor_registry, child_pid)
	if !active || child_ptr == nil do return .PERMANENT, false
	return (cast(^Actor)child_ptr).opts.restart_policy, true
}

@(private)
remove_unrestartable_child :: proc(actor: ^Actor, child_pid: PID, child_name: string) {
	if find_child(actor, child_pid) == -1 do return
	log.warnf(
		"Child %s (PID %d) has no spawn function to restart it from, so supervisor %d removes it",
		child_name,
		child_pid,
		actor.pid,
	)
	remove_child_from_supervisor(actor, child_pid)
}

@(private)
stop_and_restart_children_from :: proc(actor: ^Actor, first_index: int, dying_pid: PID) {
	pids_to_wait: [dynamic]PID
	defer delete(pids_to_wait)
	pids_to_restart: [dynamic]PID
	defer delete(pids_to_restart)
	removed_siblings: [dynamic]Removed_Sibling
	defer delete(removed_siblings)

	for child in actor.children[first_index:] {
		restartable := has_restart_source(child.restart)
		if child.pid == dying_pid || child.pid == 0 {
			if restartable do append(&pids_to_restart, child.pid)
			continue
		}

		sibling := Removed_Sibling {
			pid = child.pid,
		}
		reclaim_pin()
		sibling.name_len = copy(sibling.name_buf[:], get_actor_name(child.pid))
		policy, policy_known := local_restart_policy(child.pid)
		reclaim_unpin()
		sibling.by_policy = policy_known && policy == .TEMPORARY

		if restartable && !sibling.by_policy {
			append(&pids_to_restart, child.pid)
			if terminate_actor(child.pid, .KILLED) do append(&pids_to_wait, child.pid)
			continue
		}

		if terminate_actor(child.pid, .KILLED) {
			append(&pids_to_wait, child.pid)
			append(&removed_siblings, sibling)
		}
	}
	wait_for_pids(pids_to_wait[:], supervisor = actor)

	for &sibling in removed_siblings {
		sibling_name := string(sibling.name_buf[:sibling.name_len])
		if actor.behaviour.on_child_terminated != nil {
			actor.behaviour.on_child_terminated(actor.data, sibling.pid, sibling_name, .KILLED, false)
		}
		if sibling.by_policy {
			log.infof(
				"Child %s (PID %d) terminated with reason %v, not restarting due to policy",
				sibling_name,
				sibling.pid,
				Termination_Reason.KILLED,
			)
			remove_child_from_supervisor(actor, sibling.pid)
		} else {
			remove_unrestartable_child(actor, sibling.pid, sibling_name)
		}
	}

	for child_pid in pids_to_restart {
		restart_child(actor, child_pid)
	}
}

@(private)
restart_child :: proc(actor: ^Actor, old_pid: PID) {
	child_index := find_child(actor, old_pid)
	if child_index == -1 {
		log.errorf("No restart info for child %d", old_pid)
		return
	}

	restart_info := actor.children[child_index].restart
	if !has_restart_source(restart_info) {
		log.errorf("Child %d at index %d has no spawn function to restart it from", old_pid, child_index)
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
		new_pid, ok = restart_info.spawn_func("", actor.pid)
	}

	if !ok {
		log.errorf("Failed to restart child at index %d", child_index)
		return
	}

	restarted_index, taken := take_restarted_pid(actor, old_pid, new_pid)
	if !taken do return

	if actor.behaviour.on_child_restarted != nil {
		actor.behaviour.on_child_restarted(actor.data, old_pid, new_pid, restart_info.count)
	}
	if actor.behaviour.on_child_started != nil {
		actor.behaviour.on_child_started(actor.data, new_pid)
	}

	log.infof(
		"Restarted child at index %d: old PID %d -> new PID %d (node %d)",
		restarted_index,
		old_pid,
		new_pid,
		restart_info.node_id,
	)
}

@(private)
take_restarted_pid :: proc(actor: ^Actor, old_pid: PID, new_pid: PID) -> (int, bool) {
	process_spawn_signals(actor)

	if new_pid == old_pid {
		log.errorf(
			"Spawn function of child %d returned that child's own stopped pid, so it is not restarted",
			old_pid,
		)
		return -1, false
	}

	registered_index := find_child(actor, new_pid)
	if registered_index != -1 && has_restart_source(actor.children[registered_index].restart) {
		log.errorf(
			"Spawn function of child %d returned %d, which is another supervised child, so %d is not restarted",
			old_pid,
			new_pid,
			old_pid,
		)
		return -1, false
	}

	if find_child(actor, old_pid) == -1 {
		log.errorf(
			"Child %d left its supervisor while being restarted, so %d is not recorded in its place",
			old_pid,
			new_pid,
		)
		return -1, false
	}

	sync.mutex_lock(&actor.children_lock)
	defer sync.mutex_unlock(&actor.children_lock)

	if registered_index != -1 do ordered_remove(&actor.children, registered_index)

	child_index := find_child(actor, old_pid)
	actor.children[child_index].pid = new_pid
	return child_index, true
}
