package act

import "base:runtime"
import "core:log"
import "core:net"
import "core:time"
import "src/actod"

// Initialize the actor system. Must be called before spawning any actors.
@(hot = "skip")
node_init :: proc(
	name: string,
	opts: System_Config = actod.SYSTEM_CONFIG,
	loc: runtime.Source_Code_Location = #caller_location,
) {
	actod.node_init(name, opts, loc)
}

// Gracefully shutdown the actor system and terminate all actors.
@(hot = "skip")
shutdown_node :: proc(loc: runtime.Source_Code_Location = #caller_location) {
	actod.shutdown_node(loc)
}

// Block until SIGINT/SIGTERM received, then shutdown.
@(hot = "skip")
await_signal :: proc() {
	actod.await_signal()
}

@(hot = `compose
default opts = {}
val := data
raw_beh := Raw_Spawn_Behaviour{
	handle_message           = rawptr(behaviour.handle_message),
	init_proc                = rawptr(behaviour.init),
	terminate_proc           = rawptr(behaviour.terminate),
	actor_type               = behaviour.actor_type,
	on_child_started         = rawptr(behaviour.on_child_started),
	on_child_terminated      = rawptr(behaviour.on_child_terminated),
	on_child_restarted       = rawptr(behaviour.on_child_restarted),
	on_max_restarts_exceeded = rawptr(behaviour.on_max_restarts_exceeded),
}
return hot_api.spawn_raw(name, &val, size_of(T), raw_beh, opts, parent_pid, loc)
`)
@(require_results)
spawn :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
	parent_pid: PID = 0,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.spawn(name, data, behaviour, opts, parent_pid, loc)
}

// Spawn a child actor with the current actor as parent. Must be called from within an actor.
@(hot = `compose
default opts = {}
val := data
raw_beh := Raw_Spawn_Behaviour{
	handle_message           = rawptr(behaviour.handle_message),
	init_proc                = rawptr(behaviour.init),
	terminate_proc           = rawptr(behaviour.terminate),
	actor_type               = behaviour.actor_type,
	on_child_started         = rawptr(behaviour.on_child_started),
	on_child_terminated      = rawptr(behaviour.on_child_terminated),
	on_child_restarted       = rawptr(behaviour.on_child_restarted),
	on_max_restarts_exceeded = rawptr(behaviour.on_max_restarts_exceeded),
}
return hot_api.spawn_child_raw(name, &val, size_of(T), raw_beh, opts, loc)
`)
@(require_results)
spawn_child :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.spawn_child(name, data, behaviour, opts, loc)
}

// Spawn an actor using a name registered via register_spawn_func.
@(require_results)
spawn_by_name :: proc(
	spawn_func_name: string,
	actor_name: string,
	parent_pid: PID = 0,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.spawn_by_name(spawn_func_name, actor_name, parent_pid, loc)
}

// Spawn an actor on a remote node. Blocks until response or timeout.
@(require_results)
@(hot = "skip")
spawn_remote :: proc(
	spawn_func_name: string,
	actor_name: string,
	target_node: string,
	parent_pid: PID = 0,
	timeout: time.Duration = actod.SPAWN_REMOTE_TIMEOUT,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.spawn_remote(spawn_func_name, actor_name, target_node, parent_pid, timeout, loc)
}

// Terminate an actor by PID.
terminate_actor :: proc(
	to: PID,
	reason: Termination_Reason = .SHUTDOWN,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.terminate_actor(to, reason, loc)
}

// Rename an actor by PID.
rename_actor :: proc(
	pid: PID,
	new_name: string,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.rename_actor(pid, new_name, loc)
}

// Send a message to an actor by PID. Routes to local or remote transparently.
send_message :: proc(
	to: PID,
	content: $T,
	priority: Message_Priority = .NORMAL,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_message(to, content, priority, loc)
}

// Fire-and-forget send over the UDP lane when the target node has one:
// at-most-once, unordered, silently lossy. Falls back to the reliable TCP
// path for local PIDs, oversized messages, or peers without a UDP lane.
send_unreliable :: proc(
	to: PID,
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_unreliable(to, content, loc)
}

// Send a message by name. Use "actor@node" for remote actors.
@(hot = `compose
pid, found := hot_api.get_actor_pid(to)
if !found do return .ACTOR_NOT_FOUND
return hot_api.send_message(pid, content, .NORMAL, loc)
`)
send_message_name :: proc(
	to: string,
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_message_name(to, content, loc)
}

// Send by name with a local PID cache. Caches the name->PID resolution so repeated
// sends to the same name skip the lookup. If the actor restarts (new PID), the cache
// auto-refreshes. Local actors only. Linear scan, best for a small number of target names.
@(hot = "skip")
send_by_name_cached :: proc(
	to: string,
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_by_name_cached(to, content, loc)
}

// Send a message to a remote actor with explicit node and actor names.
@(hot = "skip")
send_to :: proc(
	actor_name: string,
	node_name: string,
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_to(actor_name, node_name, content, loc)
}

// Send a message to self. Must be called from within an actor.
@(hot = `compose
return hot_api.send_message(hot_api.get_self_pid(), content, .NORMAL, loc)
`)
send_self :: proc(
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_self(content, loc)
}

// Send a message to the parent. Must be called from within an actor.
@(hot = `compose
parent := hot_api.get_parent_pid()
if parent == 0 do return .ACTOR_NOT_FOUND
return hot_api.send_message(parent, content, .NORMAL, loc)
`)
send_message_to_parent :: proc(
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_message_to_parent(content, loc)
}

// Send a message to all children. Must be called from within an actor.
@(hot = `compose
for child in hot_api.get_children(hot_api.get_self_pid()) {
	err := hot_api.send_message(child, content, .NORMAL, loc)
	if err != .OK do return err
}
return .OK
`)
send_message_to_children :: proc(
	content: $T,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.send_message_to_children(content, loc)
}

// Register a message type for deep-copy support and network serialization. Use with @(init).
@(hot = "noop")
register_message_type :: proc "contextless" (
	$T: typeid,
	loc: runtime.Source_Code_Location = #caller_location,
) {
	actod.register_message_type(T, loc)
}

get_self_pid :: proc() -> PID {
	return actod.get_self_pid()
}

get_self_name :: proc() -> string {
	return actod.get_self_name()
}

get_parent_pid :: proc() -> PID {
	return actod.get_parent_pid()
}

self_terminate :: proc(
	reason: Termination_Reason = .NORMAL,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.self_terminate(reason, loc)
}

self_rename :: proc(
	new_name: string,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.self_rename(new_name, loc)
}

// Cooperatively yield from a pooled actor, allowing other actors on the same worker to run.
// Must be called from within a pooled (non-dedicated-thread) actor.
// If you need this, reconsider your actor design.
yield :: proc(loc: runtime.Source_Code_Location = #caller_location) {
	actod.yield(loc)
}

// Returns real time in production, virtual time in tests.
now :: proc() -> time.Time {
	return actod.now()
}

@(require_results)
get_actor_pid :: proc(name: string) -> (PID, bool) {
	return actod.get_actor_pid(name)
}

get_actor_name :: proc(pid: PID) -> string {
	return actod.get_actor_name(pid)
}

is_local_pid :: proc(pid: PID) -> bool {
	return actod.is_local_pid(pid)
}

get_node_id :: proc(pid: PID) -> Node_ID {
	return actod.get_node_id(pid)
}

get_pid_actor_type :: proc(pid: PID) -> Actor_Type {
	return actod.get_pid_actor_type(pid)
}

pack_pid :: proc(h: Handle, node_id: Node_ID = actod.current_node_id) -> PID {
	return actod.pack_pid(h, node_id)
}

unpack_pid :: proc(pid: PID) -> (handle: Handle, node_id: Node_ID) {
	return actod.unpack_pid(pid)
}

Timer_Tick :: actod.Timer_Tick

@(require_results)
set_timer :: proc(
	interval: time.Duration,
	repeat: bool,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	u32,
	Send_Error,
) {
	return actod.set_timer(interval, repeat, loc)
}

cancel_timer :: proc(
	id: u32,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Send_Error {
	return actod.cancel_timer(id, loc)
}

// Supervision

get_children :: proc(parent: PID) -> []PID {
	return actod.get_children(parent)
}

// Dynamically spawn and add a new child to a supervisor.
@(require_results)
add_child :: proc(
	parent: PID,
	child_spawn: SPAWN,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.add_child(parent, child_spawn, loc)
}

// Adopt an existing actor as a child of a supervisor.
@(require_results)
@(hot = "extra_param spawn_func_name_hash: u64 = 0")
add_child_existing :: proc(
	parent: PID,
	existing_child: PID,
	child_spawn: SPAWN,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.add_child_existing(parent, existing_child, child_spawn, 0, loc)
}

remove_child :: proc(
	parent: PID,
	child: PID,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.remove_child(parent, child, loc)
}

// Register a named actor type. Returns the local Actor_Type ID.
@(require_results)
register_actor_type :: proc(name: string) -> (Actor_Type, bool) {
	return actod.register_actor_type(name)
}

// Get the string name of a registered actor type.
@(require_results)
get_actor_type_name :: proc(actor_type: Actor_Type) -> (string, bool) {
	return actod.get_actor_type_name(actor_type)
}

// Subscribe to broadcasts from actors of the given type. Must be called from within an actor.
// Subscriptions are automatically cleaned up on actor termination.
@(require_results)
subscribe_type :: proc(
	actor_type: Actor_Type,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	Subscription,
	bool,
) {
	return actod.subscribe_type(actor_type, loc)
}

// Unsubscribe from a previously subscribed actor type.
@(hot = "host_name pubsub_unsubscribe")
unsubscribe :: proc(
	sub: Subscription,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.pubsub_unsubscribe(sub, loc)
}

// Broadcast a message to all subscribers of the current actor's type.
// Must be called from within a typed actor (actor_type set on behaviour).
broadcast :: proc(msg: $T, loc: runtime.Source_Code_Location = #caller_location) {
	actod.broadcast(msg, loc)
}

get_subscriber_count :: proc(actor_type: Actor_Type) -> u32 {
	return actod.get_subscriber_count(actor_type)
}

@(require_results)
subscribe_topic :: proc(
	topic: ^Topic,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	Topic_Subscription,
	bool,
) {
	return actod.subscribe_topic(topic, loc)
}

unsubscribe_topic :: proc(
	sub: Topic_Subscription,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.unsubscribe_topic(sub, loc)
}

publish :: proc(topic: ^Topic, msg: $T, loc: runtime.Source_Code_Location = #caller_location) {
	actod.publish(topic, msg, loc)
}

@(require_results)
@(hot = "skip")
register_node :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
	connect: bool = false,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	Node_ID,
	bool,
) {
	return actod.register_node(name, address, transport, connect, loc)
}

// Register a named spawn function for remote spawning and spawn_by_name.
register_spawn_func :: proc(
	name: string,
	func: SPAWN,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.register_spawn_func(name, func, loc)
}

@(require_results)
@(hot = "skip")
get_node_info :: proc(node_id: Node_ID) -> (Node_Info, bool) {
	return actod.get_node_info(node_id)
}

@(require_results)
@(hot = "skip")
get_node_by_name :: proc(name: string) -> (Node_ID, bool) {
	return actod.get_node_by_name(name)
}

@(hot = "skip")
unregister_node :: proc(node_id: Node_ID) {
	actod.unregister_node(node_id)
}

get_local_node_pid :: proc() -> PID {
	return actod.get_local_node_pid()
}

get_local_node_name :: proc() -> string {
	return actod.get_local_node_name()
}

@(hot = "skip")
start_observer :: proc(
	collection_interval: time.Duration = 0,
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	PID,
	bool,
) {
	return actod.start_observer(collection_interval, loc)
}

@(hot = "skip")
stop_observer :: proc() {
	actod.stop_observer()
}

@(hot = "skip")
trigger_stats_collection :: proc(loc: runtime.Source_Code_Location = #caller_location) -> bool {
	return actod.trigger_stats_collection(loc)
}

@(hot = "skip")
request_actor_stats :: proc(
	actor_pid: PID,
	requester: PID,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.request_actor_stats(actor_pid, requester, loc)
}

@(hot = "skip")
request_all_stats :: proc(
	requester: PID,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.request_all_stats(requester, loc)
}

@(hot = "skip")
set_stats_collection_interval :: proc(
	interval: time.Duration,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.set_stats_collection_interval(interval, loc)
}

@(hot = "skip")
clear_terminated_stats :: proc(loc: runtime.Source_Code_Location = #caller_location) -> bool {
	return actod.clear_terminated_stats(loc)
}

// Subscribe to observer stats snapshots. Must be called from within an actor.
@(require_results)
@(hot = "skip")
subscribe_to_stats :: proc(
	loc: runtime.Source_Code_Location = #caller_location,
) -> (
	Subscription,
	bool,
) {
	return actod.subscribe_to_stats(loc)
}

@(hot = "skip")
unsubscribe_from_stats :: proc(
	sub: Subscription,
	loc: runtime.Source_Code_Location = #caller_location,
) -> bool {
	return actod.unsubscribe_from_stats(sub, loc)
}

set_log_level :: proc(level: Log_Level) {
	actod.set_log_level(level)
}

is_log_level_enabled :: proc(level: Log_Level) -> bool {
	return actod.is_log_level_enabled(level)
}

get_current_log_config :: proc() -> Log_Config {
	return actod.get_current_log_config()
}

@(hot = "skip")
make_node_config :: proc(
	actor_registry_size: int = actod.SYSTEM_CONFIG.actor_registry_size,
	allow_registry_growth: bool = actod.SYSTEM_CONFIG.allow_registry_growth,
	enable_observer: bool = actod.SYSTEM_CONFIG.enable_observer,
	observer_interval: time.Duration = actod.SYSTEM_CONFIG.observer_interval,
	network: Network_Config = actod.SYSTEM_CONFIG.network,
	actor_config: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
	blocking_child: SPAWN = actod.SYSTEM_CONFIG.blocking_child,
	worker_count: int = actod.SYSTEM_CONFIG.worker_count,
	hot_reload_dev: bool = actod.SYSTEM_CONFIG.hot_reload_dev,
	hot_reload_watch_path: string = actod.SYSTEM_CONFIG.hot_reload_watch_path,
	loc: runtime.Source_Code_Location = #caller_location,
) -> System_Config {
	return actod.make_node_config(
		actor_registry_size,
		allow_registry_growth,
		enable_observer,
		observer_interval,
		network,
		actor_config,
		blocking_child,
		worker_count,
		hot_reload_dev,
		hot_reload_watch_path,
		loc,
	)
}

@(hot = `compose
default children = nil
default spin_strategy = .WAKE_SEMA
default logging = {}
default message_batch = 64
default page_size = 65536
default supervision_strategy = .ONE_FOR_ONE
default restart_policy = .PERMANENT
default max_restarts = 3
default restart_window = 5 * time.Second
default home_worker = -1
default affinity = nil
default coro_stack_size = 57344
default use_dedicated_os_thread = false
default stack_size_dedicated_os_thread = 131072
return hot_api.make_actor_config(children, spin_strategy, logging, message_batch, page_size, supervision_strategy, restart_policy, max_restarts, restart_window, home_worker, affinity, coro_stack_size, use_dedicated_os_thread, stack_size_dedicated_os_thread, loc)
`)
make_actor_config :: proc(
	children: [dynamic]SPAWN = nil,
	spin_strategy: Spin_Strategy = actod.SYSTEM_CONFIG.actor_config.spin_strategy,
	logging: Log_Config = actod.SYSTEM_CONFIG.actor_config.logging,
	message_batch: int = actod.SYSTEM_CONFIG.actor_config.message_batch,
	page_size: int = actod.SYSTEM_CONFIG.actor_config.page_size,
	supervision_strategy: Supervision_Strategy = actod.SYSTEM_CONFIG.actor_config.supervision_strategy,
	restart_policy: Restart_Policy = actod.SYSTEM_CONFIG.actor_config.restart_policy,
	max_restarts: int = actod.SYSTEM_CONFIG.actor_config.max_restarts,
	restart_window: time.Duration = actod.SYSTEM_CONFIG.actor_config.restart_window,
	home_worker: int = actod.SYSTEM_CONFIG.actor_config.home_worker,
	affinity: Actor_Ref = actod.SYSTEM_CONFIG.actor_config.affinity,
	coro_stack_size: int = actod.SYSTEM_CONFIG.actor_config.coro_stack_size,
	use_dedicated_os_thread: bool = actod.SYSTEM_CONFIG.actor_config.use_dedicated_os_thread,
	stack_size_dedicated_os_thread: int = actod.SYSTEM_CONFIG.actor_config.stack_size_dedicated_os_thread,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Actor_Config {
	return actod.make_actor_config(
		children,
		spin_strategy,
		logging,
		message_batch,
		page_size,
		supervision_strategy,
		restart_policy,
		max_restarts,
		restart_window,
		home_worker,
		affinity,
		coro_stack_size,
		use_dedicated_os_thread,
		stack_size_dedicated_os_thread,
		loc,
	)
}

@(hot = "skip")
make_network_config :: proc(
	auth_password: string = actod.DEFAULT_NETWORK_CONFIG.auth_password,
	port: int = actod.DEFAULT_NETWORK_CONFIG.port,
	udp_port: int = actod.DEFAULT_NETWORK_CONFIG.udp_port,
	udp_max_datagram: int = actod.DEFAULT_NETWORK_CONFIG.udp_max_datagram,
	enable_encryption: bool = actod.DEFAULT_NETWORK_CONFIG.enable_encryption,
	heartbeat_interval: time.Duration = actod.DEFAULT_NETWORK_CONFIG.heartbeat_interval,
	heartbeat_timeout: time.Duration = actod.DEFAULT_NETWORK_CONFIG.heartbeat_timeout,
	reconnect_initial_delay: time.Duration = actod.DEFAULT_NETWORK_CONFIG.reconnect_initial_delay,
	reconnect_retry_delay: time.Duration = actod.DEFAULT_NETWORK_CONFIG.reconnect_retry_delay,
	connection_ring: Connection_Ring_Config = actod.DEFAULT_NETWORK_CONFIG.connection_ring,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Network_Config {
	return actod.make_network_config(
		auth_password,
		port,
		udp_port,
		udp_max_datagram,
		enable_encryption,
		heartbeat_interval,
		heartbeat_timeout,
		reconnect_initial_delay,
		reconnect_retry_delay,
		connection_ring,
		loc,
	)
}

@(hot = "skip")
make_log_config :: proc(
	level: Log_Level = actod.SYSTEM_CONFIG.actor_config.logging.level,
	console_opts: Log_Options = actod.SYSTEM_CONFIG.actor_config.logging.console_opts,
	file_opts: Log_Options = actod.SYSTEM_CONFIG.actor_config.logging.file_opts,
	ident: string = actod.SYSTEM_CONFIG.actor_config.logging.ident,
	enable_file: bool = actod.SYSTEM_CONFIG.actor_config.logging.enable_file,
	log_path: string = actod.SYSTEM_CONFIG.actor_config.logging.log_path,
	custom_logger: Log_Callback = actod.SYSTEM_CONFIG.actor_config.logging.custom_logger,
	custom_flush: Log_Flush = actod.SYSTEM_CONFIG.actor_config.logging.custom_flush,
) -> Log_Config {
	return actod.make_log_config(
		level,
		console_opts,
		file_opts,
		ident,
		enable_file,
		log_path,
		custom_logger,
		custom_flush,
	)
}

@(hot = "skip")
make_children :: proc(spawns: ..SPAWN) -> [dynamic]SPAWN {
	return actod.make_children(..spawns)
}

// Core
PID :: actod.PID
Actor_Ref :: actod.Actor_Ref
Handle :: actod.Handle
Actor_Type :: actod.Actor_Type
SPAWN :: actod.SPAWN
Actor_Behaviour :: actod.Actor_Behaviour
Actor_State :: actod.Actor_State
Send_Error :: actod.Send_Error
Message_Priority :: actod.Message_Priority
Termination_Reason :: actod.Termination_Reason
ACTOR_TYPE_UNTYPED :: actod.ACTOR_TYPE_UNTYPED

// Pub/Sub
Subscription :: actod.Subscription
Topic :: actod.Topic
Topic_Subscription :: actod.Topic_Subscription

// Supervision
Supervision_Strategy :: actod.Supervision_Strategy
Restart_Policy :: actod.Restart_Policy

// Configuration
System_Config :: actod.System_Config
Actor_Config :: actod.Actor_Config
Network_Config :: actod.Network_Config
Log_Config :: actod.Log_Config
Log_Callback :: actod.Log_Callback
Log_Flush :: actod.Log_Flush
Log_Level :: log.Level
Log_Options :: log.Options
Spin_Strategy :: actod.SPIN_STRATEGY

// Networking
Node_ID :: actod.Node_ID
Connection_Ring_Config :: actod.Connection_Ring_Config
Node_Info :: actod.Node_Info
Transport_Strategy :: actod.Transport_Strategy

// Observer
Actor_Stats :: actod.Actor_Stats
Stats_Snapshot :: actod.Stats_Snapshot
Stats_Response :: actod.Stats_Response

@(hot = "skip")
get_node_log_ctx :: proc() -> log.Logger {
	return actod.systemLogger
}
