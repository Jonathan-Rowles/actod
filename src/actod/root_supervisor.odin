package actod

import "core:log"

ROOT_SUPERVISOR_NAME :: "root_supervisor"

@(private)
Root_Supervisor_Data :: struct {}

@(private)
Root_Supervisor_Behaviour :: Actor_Behaviour(Root_Supervisor_Data) {
	handle_message           = root_supervisor_handle_message,
	on_max_restarts_exceeded = root_supervisor_escalate,
}

@(private)
root_supervisor_handle_message :: proc(data: ^Root_Supervisor_Data, from: PID, msg: any) {
	log.debugf(
		"the root supervisor received a message of type %T from %s that it does not handle",
		msg,
		actor_origin(from),
	)
}

@(private)
root_supervisor_escalate :: proc(data: ^Root_Supervisor_Data, child_pid: PID) {
	escalate_node_failure("a node child exceeded max_restarts")
}

@(private)
spawn_root_supervisor_child :: proc(_name: string, parent_pid: PID) -> (PID, bool) {
	config := NODE.config.actor_config
	config.children = NODE.root_supervisor_children
	pid, ok := spawn(
		ROOT_SUPERVISOR_NAME,
		Root_Supervisor_Data{},
		Root_Supervisor_Behaviour,
		config,
		parent_pid,
	)
	if !ok {
		panic_at(
			NODE.config.loc,
			"node startup failed: the root supervisor could not be spawned, node children would have no supervisor",
		)
	}
	NODE.root_supervisor_pid = pid
	return pid, ok
}

supervising_parent :: #force_inline proc(parent: PID) -> PID {
	if parent == NODE.pid && NODE.root_supervisor_pid != 0 do return NODE.root_supervisor_pid
	return parent
}
