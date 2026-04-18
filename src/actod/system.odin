package actod

import "../pkgs/coro"
import "../pkgs/threads_act"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import vmem "core:mem/virtual"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

SYSTEM_MSG :: union {
	Terminate,
	Actor_Stopped,
	Remove_Child,
	Add_Child,
	Set_Parent,
	Get_Stats,
	Rename_Actor,
	Reload_Behaviour,
}

Reload_Behaviour :: struct {
	generation: u32,
}

Terminate :: struct {
	reason: Termination_Reason,
}

Actor_Stopped :: struct {
	child_pid:   PID,
	reason:      Termination_Reason,
	child_name:  string,
	child_index: int,
}

Remove_Child :: struct {
	child_pid: PID,
}

Add_Child :: struct {
	spawn_func:           SPAWN,
	existing_pid:         PID,
	spawn_func_name_hash: u64, // remote
}

Set_Parent :: struct {
	new_parent: PID,
	spawn_func: SPAWN,
}

// Observer system messages
Get_Stats :: struct {
	requester: PID, // Observer PID
}

Rename_Actor :: struct {
	new_name: string,
}

Actor_Spawned_Broadcast :: struct {
	pid:              PID,
	name:             string,
	actor_type:       Actor_Type,
	parent_pid:       PID,
	ttl:              u8,
	source_node_name: string,
	source_port:      u16,
	source_ip:        u32,
}

Actor_Terminated_Broadcast :: struct {
	pid:              PID,
	name:             string,
	reason:           Termination_Reason,
	ttl:              u8,
	source_node_name: string,
}

Remote_Spawn_Request :: struct {
	request_id:           u64,
	parent_pid:           PID,
	spawn_func_name_hash: u64,
	actor_name:           string,
}

Remote_Spawn_Response :: struct {
	request_id: u64,
	success:    bool,
	pid:        PID,
	error_msg:  string,
}

Subscribe_Remote :: struct {
	subscriber_pid: PID,
	type_name_hash: u64,
}

Unsubscribe_Remote :: struct {
	subscriber_pid: PID,
	type_name_hash: u64,
}

@(init)
init_system_messages :: proc "contextless" () {
	register_message_type(PID)
	register_message_type(Terminate)
	register_message_type(Actor_Stopped)
	register_message_type(Remove_Child)
	register_message_type(Add_Child)
	register_message_type(Set_Parent)
	register_message_type(Get_Stats)
	register_message_type(Connect_Request)
	register_message_type(Raw_Network_Buffer)
	register_message_type(Remote_Message)
	register_message_type(Start_Receiving)
	register_message_type(Rename_Actor)
	register_message_type(Close_Connection)
	register_message_type(Actor_Spawned_Broadcast)
	register_message_type(Actor_Terminated_Broadcast)
	register_message_type(Remote_Spawn_Request)
	register_message_type(Remote_Spawn_Response)
	register_message_type(Subscribe_Remote)
	register_message_type(Unsubscribe_Remote)
	register_message_type(Scale_Up_Request)
	register_message_type(Accept_Pool_Ring_Socket)
	register_message_type(Pool_Ring_Closed)
	register_message_type(Reload_Behaviour)
}

Node_Behaviour :: Actor_Behaviour(Node_Data) {
	handle_message = handle_node_message,
	init           = init_system,
	terminate      = terminate_system,
}

@(private)
init_system :: proc(data: ^Node_Data) {
	current_node_id = 1
	init_network(current_node_id, data.name)
}

@(private)
terminate_system :: proc(data: ^Node_Data) {
	for i in 0 ..< MAX_NODES {
		if NODE.node_registry[i].node_name != "" {
			delete(NODE.node_registry[i].node_name, get_system_allocator())
			NODE.node_registry[i] = {}
		}
	}

	if NODE.node_name_to_id != nil {
		delete(NODE.node_name_to_id)
		NODE.node_name_to_id = nil
	}
	NODE.connection_actors = {}
}

Node_Data :: struct {
	pid:                      PID,
	observer:                 PID,
	name:                     string,
	started:                  bool,
	shutting_down:            bool,
	node_registry:            [MAX_NODES]Node_Info,
	connection_pools:         [MAX_NODES]^Connection_Pool,
	connection_rings:         [MAX_NODES]^Connection_Ring, // fast-path cache of pool ring 0
	node_name_to_id:          map[string]Node_ID,
	node_registry_lock:       sync.RW_Mutex,
	connection_actors:        [MAX_NODES]PID,
	network_listener_thread:  ^thread.Thread,
	network_listener_running: i32, // Atomic flag: 0 = stopped, 1 = running
	network_listener_socket:  net.TCP_Socket,
	shutdown_signal_port:     int, // Port for shutdown signaling
}

NODE := Node_Data{}

get_local_node_name :: proc() -> string {
	return NODE.name
}

get_local_node_pid :: proc() -> PID {
	return NODE.pid
}

systemLogger := runtime.Logger{}

get_node_log_ctx :: proc() -> log.Logger {
	return systemLogger
}

NODE_INIT :: proc(name: string, opts := SYSTEM_CONFIG) {
	NODE.name = name

	logging_config := opts.actor_config.logging
	logging_config.ident = name
	systemLogger = init_logger(logging_config)
	context.logger = systemLogger

	SYSTEM_CONFIG = opts

	NODE.started = true
	NODE.shutting_down = false
	if NODE.node_name_to_id == nil {
		NODE.node_name_to_id = make(map[string]Node_ID, actor_system_allocator)
	}

	NODE.connection_actors = {}

	registry_size := opts.actor_registry_size
	if registry_size == 0 {
		registry_size = 256
	}
	init_pid_map(&global_registry, registry_size, actor_system_allocator)

	worker_count := opts.worker_count
	if worker_count == 0 {
		worker_count = threads_act.get_cpu_count()
	}
	init_worker_pool(worker_count)

	system_config := opts.actor_config

	system_children: [dynamic]SPAWN
	append(&system_children, spawn_timer_child)
	if opts.enable_observer {
		append(&system_children, spawn_observer_child)
	}
	if opts.hot_reload_dev {
		append(&system_children, spawn_hot_reload_child)
	}
	if system_config.children != nil {
		for child in system_config.children {
			append(&system_children, child)
		}
		delete(system_config.children)
	}
	SYSTEM_CONFIG.actor_config.children = nil
	system_config.children = system_children

	NODE.pid, NODE.started = spawn(name, NODE, Node_Behaviour, system_config)
	delete(system_children)
	if !NODE.started {
		log.panic("node failed to start")
	}

	if opts.blocking_child != nil {
		log.info("Starting blocking child on main thread")
		spawning_blocking_child = true
		opts.blocking_child("", 0)
		spawning_blocking_child = false
	}

}

send_node_msg :: proc(content: SYSTEM_MSG) -> bool {
	actor, ok := get_actor_from_pointer(get(&global_registry, NODE.pid), true)
	if !ok {
		return false
	}

	switch v in content {
	case Terminate:
		return send(NODE.pid, v, actor) == .OK
	case Actor_Stopped:
		return send_to_node_mailbox(actor, v)
	case Remove_Child:
		return send_to_node_mailbox(actor, v)
	case Add_Child:
		return send_to_node_mailbox(actor, v)
	case Set_Parent:
		return send_to_node_mailbox(actor, v)
	case Get_Stats:
		return send_to_node_mailbox(actor, v)
	case Rename_Actor:
		return send_to_node_mailbox(actor, v)
	case Reload_Behaviour:
		return send_to_node_mailbox(actor, v) // forwarded to target actors
	}

	unreachable()
}

@(private)
send_to_node_mailbox :: #force_inline proc(actor: ^Actor(int), content: $T) -> bool {
	state := sync.atomic_load(&actor.state)
	if state == .TERMINATED || state == .THREAD_STOPPED {
		return false
	}

	msg: Message
	msg.from = get_self_pid()
	info := get_validated_message_info_ptr(T)

	alloc_err, _ := create_message(&msg, &actor.pool, content, info)
	if alloc_err != .OK {
		return false
	}

	result := push_to_mailbox(actor, msg, NODE.pid, get_send_priority())
	if result != .OK {
		free_message(&actor.pool, msg.content)
		return false
	}
	return true
}

@(private)
handle_node_message :: proc(data: ^Node_Data, from: PID, msg: any) {
	switch v in msg {
	case Actor_Stopped:
		if !valid(&global_registry, from) {
			log.fatal("not valid pid")
		}

		actor_ptr, active := get(&global_registry, from)
		if !active || actor_ptr == nil {
			log.fatal("trying to terminate actor that is not in registry")
		}

		state_ptr := cast(^Actor_State)(uintptr(actor_ptr) + offset_of(Actor(int), state))
		current_state := sync.atomic_load(state_ptr)

		if current_state == .THREAD_STOPPED || current_state == .STOPPING {
			cleanup_terminated_actor(from, actor_ptr)
		} else {
			log.panicf(
				"Actor %v in unexpected state %v when Actor_Stopped received",
				from,
				current_state,
			)
		}
	case Remove_Child:
		a, _ := get_actor_from_pointer(get(&global_registry, NODE.pid), true)
		handle_remove_child(a, v)
	case Add_Child:
		a, _ := get_actor_from_pointer(get(&global_registry, NODE.pid), true)
		handle_add_child(a, v)
	case Set_Parent:
		a, _ := get_actor_from_pointer(get(&global_registry, NODE.pid), true)
		handle_set_parent(a, v)
	case Get_Stats:
		a, _ := get_actor_from_pointer(get(&global_registry, NODE.pid), true)
		handle_get_stats_request(a, v)
	case Terminate:
		log.info("To terminate system node call SHUTDOWN_NODE")
	case Rename_Actor:
		log.warn("Rename_Actor not yet handled in system node")
	case string:
		log.infof("Got message from %s: message -> %s", get_actor_name(from), v)
		err := send_message(from, "received message")
		if err != .OK {
			log.warnf("Failed to send reply: %v", err)
		}
	case:
		log.warn("unhandled msg type in system node: %T", v)
	}
}

@(private)
shutdown_deferred_frees: [dynamic]rawptr
cleanup_terminated_actor :: proc(pid: PID, actor_ptr: rawptr) {
	if _, active := get(&global_registry, pid); !active {
		return
	}

	remove(&global_registry, pid)

	if sync.atomic_load(&NODE.shutting_down) {
		append(&shutdown_deferred_frees, actor_ptr)
		if pid == NODE.pid {
			NODE.pid = 0
		}
		return
	}

	state_ptr := cast(^Actor_State)(uintptr(actor_ptr) + offset_of(Actor(int), state))
	current := sync.atomic_load(state_ptr)

	if current == .TERMINATED {
		return
	}

	if current == .STOPPING || current == .THREAD_STOPPED {
		pool_handle_ptr := cast(^^Pooled_Actor_Handle)(uintptr(actor_ptr) +
			offset_of(Actor(int), pool_handle))
		if pool_handle_ptr^ != nil {
			for i := 0; i < 10000; i += 1 {
				if coro.status(pool_handle_ptr^.co) == .Dead do break
				time.sleep(100 * time.Microsecond)
			}
		} else {
			cleanup_actor_thread(actor_ptr)
		}

		current = sync.atomic_load(state_ptr)
		if current != .THREAD_STOPPED {
			log.fatalf("[PANIC] Actor %v in unexpected state %v after thread join", pid, current)
		}
	} else if current == .RUNNING || current == .IDLE {
		sync.atomic_store(state_ptr, .STOPPING)
		pool_handle_ptr := cast(^^Pooled_Actor_Handle)(uintptr(actor_ptr) +
			offset_of(Actor(int), pool_handle))
		if pool_handle_ptr^ != nil {
			wake_pooled_actor(pool_handle_ptr^)
			for i := 0; i < 10000; i += 1 {
				if coro.status(pool_handle_ptr^.co) == .Dead do break
				time.sleep(100 * time.Microsecond)
			}
		} else {
			sync.atomic_sema_post(
				cast(^sync.Atomic_Sema)(uintptr(actor_ptr) + offset_of(Actor(int), wake_sema)),
			)
			cleanup_actor_thread(actor_ptr)
		}

		current = sync.atomic_load(state_ptr)
	}

	if !try_transition_state(state_ptr, .THREAD_STOPPED, .TERMINATED) {
		return
	}

	children_ptr := cast(^[dynamic]PID)(uintptr(actor_ptr) + offset_of(Actor(int), children))

	if children_ptr != nil && len(children_ptr^) > 0 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		child_pids := make([dynamic]PID, len(children_ptr^), context.temp_allocator)
		copy(child_pids[:], children_ptr^[:])

		for child_pid in child_pids {
			if !terminate_actor(child_pid, .SHUTDOWN) {
				log.warnf("Failed to shutdown child %d of actor %d", child_pid, pid)
			}
		}

		for child_pid in child_pids {
			for i := 0; i < 100; i += 1 {
				if _, active := get(&global_registry, child_pid); !active {
					break
				}
				time.sleep(1 * time.Millisecond)
			}
		}
	}

	cleanup_actor_arena(actor_ptr)
	free(actor_ptr, actor_system_allocator)

	if pid == NODE.pid {
		NODE.pid = 0
	}
}

SHUTDOWN_NODE :: proc() {
	context.logger = systemLogger
	if !NODE.started || NODE.pid == 0 {
		cleanup_logger_and_context()
		reset_node_state()
		return
	}

	if coro.running() != nil {
		sync.atomic_store(&NODE.shutting_down, true)
		sync.atomic_sema_post(&signal_wake)
		return
	}

	sync.atomic_store(&NODE.shutting_down, true)

	cleanup_remote_proxy_entries()
	send_terminate_to_active_actors_and_wait()

	stop_network_listener()
	broadcast_graceful_disconnect("shutdown")

	clear_all_subscriptions()

	if OBSERVER_PID != {} {
		stop_observer()
	}

	if HOT_RELOAD_PID != 0 {
		stop_hot_reload_actor()
	}

	system_actors := 1
	if TIMER_PID != 0 {
		system_actors += 1
	}
	wait_for_actors_to_clear(max_remaining = system_actors, max_wait_ms = 1000)

	stop_timer_actor()

	cleanup_node_actor()
	shutdown_worker_pool()

	for ptr in shutdown_deferred_frees {
		cleanup_actor_arena(ptr)
		free(ptr, actor_system_allocator)
	}

	delete(shutdown_deferred_frees)
	shutdown_deferred_frees = {}

	destroy(&global_registry)

	cleanup_logger_and_context()
	reset_node_state()
}

send_terminate_to_active_actors_and_wait :: proc() {
	active_states := Actor_State_Set{.RUNNING, .IDLE}

	actors_to_wait: [dynamic]PID
	defer delete(actors_to_wait)

	it := make_iter(&global_registry)
	for {
		_, pid, ok := iter(&it)
		if !ok do break
		if is_system_actod_pid(pid) do continue
		if is_connection_actor(pid) do continue
		if !is_local_pid(pid) do continue

		actor_ptr, _, valid := get_valid_actor(pid, active_states, system_operation = true)
		if valid {
			parent_ptr := cast(^PID)(uintptr(actor_ptr) + offset_of(Actor(int), parent))
			parent := parent_ptr^
			if parent != 0 && parent != NODE.pid {
				continue
			}
			if terminate_actor(pid) {
				append(&actors_to_wait, pid)
			}
		}
	}

	wait_for_pids(actors_to_wait[:])
}

cleanup_remote_proxy_entries :: proc() {
	for node_id in 2 ..< Node_ID(MAX_NODES) {
		handle_node_disconnect(node_id)
	}
}

is_connection_actor :: proc(pid: PID) -> bool {
	for i in 0 ..< MAX_NODES {
		conn_pid := PID(sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[i], .Acquire))
		if conn_pid != 0 && conn_pid == pid {
			return true
		}
	}
	return false
}

cleanup_node_actor :: proc() {
	if NODE.pid == 0 do return

	node_ptr, active := get(&global_registry, NODE.pid)
	if !active || node_ptr == nil do return

	n, ok := get_actor_from_pointer(node_ptr, true)
	if ok && n != nil {
		n.termination_reason = .SHUTDOWN
		if n.behaviour.terminate != nil {
			n.behaviour.terminate(n.data)
		}
	}

	cleanup_terminated_actor(NODE.pid, node_ptr)
}

reset_node_state :: proc() {
	sync.atomic_store(&global_next_node_id, 2)
	current_node_id = 1
	NODE.started = false
	// NOTE: shutting_down stays true until NODE_INIT to prevent
	// concurrent senders from accessing freed actor memory.
	NODE.pid = 0
	NODE.observer = 0

	OBSERVER_PID = {}
	TIMER_PID = 0
	HOT_RELOAD_PID = 0
	reset_timer_registry()

	if NODE.node_name_to_id != nil {
		delete(NODE.node_name_to_id)
		NODE.node_name_to_id = nil
	}
	NODE.connection_actors = {}
	NODE.network_listener_thread = nil
	sync.atomic_store(&NODE.network_listener_running, 0)
	NODE.network_listener_socket = {}

	NODE.node_registry = {}
}

wait_for_actors_to_clear :: proc(
	max_remaining: int,
	max_wait_ms: int = 1000,
	poll_interval_ms: int = 10,
) -> bool {
	iterations := max_wait_ms / poll_interval_ms

	for i := 0; i < iterations; i += 1 {
		if num_used(&global_registry) <= max_remaining {
			return true
		}
		time.sleep(time.Duration(poll_interval_ms) * time.Millisecond)
	}

	return false
}

wait_for_pids :: proc(pids: []PID, poll_interval_ms: int = 10, max_wait_ms: int = 5000) {
	start := time.now()
	max_wait := time.Duration(max_wait_ms) * time.Millisecond
	poll_interval := time.Duration(poll_interval_ms) * time.Millisecond
	co := coro.running()

	for {
		all_done := true
		stuck_pid: PID = 0
		for pid in pids {
			if !is_local_pid(pid) do continue
			if _, active := get(&global_registry, pid); active {
				all_done = false
				stuck_pid = pid
				break
			}
		}
		if all_done {
			return
		}
		elapsed := time.since(start)
		if elapsed > max_wait {
			log.warnf(
				"[SHUTDOWN] wait_for_pids timed out after %d ms — stuck on PID %d",
				max_wait_ms,
				stuck_pid,
			)
			return
		}

		if co != nil {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		} else {
			time.sleep(poll_interval)
		}
	}
}

cleanup_actor_arena :: proc(actor_ptr: rawptr) {
	arena_offset := offset_of(Actor(int), arena)
	arena_ptr := cast(^vmem.Arena)(uintptr(actor_ptr) + arena_offset)
	vmem.arena_destroy(arena_ptr)
}

@(private)
signal_wake: sync.Atomic_Sema

await_signal :: proc() {
	setup_signal_handler()
	sync.atomic_sema_wait(&signal_wake)
	if NODE.pid != 0 {
		SHUTDOWN_NODE()
	}
}

is_system_actod_pid :: proc(pid: PID) -> bool {
	return(
		pid == 0 ||
		pid == NODE.pid ||
		pid == OBSERVER_PID ||
		pid == TIMER_PID ||
		pid == HOT_RELOAD_PID \
	)
}
