package act

import "core:log"
import "core:net"
import "core:time"
import "src/actod"

// Initialize the actor system. Must be called before spawning any actors.
@(hot = "skip")
NODE_INIT :: proc(name: string, opts: System_Config = actod.SYSTEM_CONFIG) {
	actod.NODE_INIT(name, opts)
}

// Gracefully shutdown the actor system and terminate all actors.
@(hot = "skip")
SHUTDOWN_NODE :: proc() {
	actod.SHUTDOWN_NODE()
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
return hot_api.spawn_raw(name, &val, size_of(T), raw_beh, opts, parent_pid)
`)
spawn :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
	parent_pid: PID = 0,
) -> (
	PID,
	bool,
) {
	return actod.spawn(name, data, behaviour, opts, parent_pid)
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
return hot_api.spawn_child_raw(name, &val, size_of(T), raw_beh, opts)
`)
spawn_child :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts: Actor_Config = actod.SYSTEM_CONFIG.actor_config,
) -> (
	PID,
	bool,
) {
	return actod.spawn_child(name, data, behaviour, opts)
}

// Spawn an actor using a registered spawn function name. N.B. register_spawn_func
spawn_by_name :: proc(
	spawn_func_name: string,
	actor_name: string,
	parent_pid: PID = 0,
) -> (
	PID,
	bool,
) {
	return actod.spawn_by_name(spawn_func_name, actor_name, parent_pid)
}

// Spawn an actor on a remote node. Blocks until response or timeout.
@(hot = "skip")
spawn_remote :: proc(
	spawn_func_name: string,
	actor_name: string,
	target_node: string,
	parent_pid: PID = 0,
	timeout: time.Duration = actod.SPAWN_REMOTE_TIMEOUT,
) -> (
	PID,
	bool,
) {
	return actod.spawn_remote(spawn_func_name, actor_name, target_node, parent_pid, timeout)
}

// Terminate an actor by PID.
terminate_actor :: proc(to: PID, reason: Termination_Reason = .SHUTDOWN) -> bool {
	return actod.terminate_actor(to, reason)
}

// Rename an actor by PID.
rename_actor :: proc(pid: PID, new_name: string) -> bool {
	return actod.rename_actor(pid, new_name)
}

// Send a message to an actor by PID. Routes to local or remote transparently.
send_message :: proc(to: PID, content: $T) -> Send_Error {
	return actod.send_message(to, content)
}

// Send a message by name. Use "actor@node" for remote actors.
@(hot = `compose
pid, found := hot_api.get_actor_pid(to)
if !found do return .ACTOR_NOT_FOUND
return hot_api.send_message(pid, content)
`)
send_message_name :: proc(to: string, content: $T) -> Send_Error {
	return actod.send_message_name(to, content)
}

// Send by name with a local PID cache. Caches the name->PID resolution so repeated
// sends to the same name skip the lookup. If the actor restarts (new PID), the cache
// auto-refreshes. Local actors only. Linear scan — best for a small number of target names.
@(hot = "skip")
send_by_name_cached :: proc(to: string, content: $T) -> Send_Error {
	return actod.send_by_name_cached(to, content)
}

// Send a message to a remote actor with explicit node and actor names.
@(hot = "skip")
send_to :: proc(actor_name: string, node_name: string, content: $T) -> Send_Error {
	return actod.send_to(actor_name, node_name, content)
}

// Send a message to self. Must be called from within an actor.
@(hot = `compose
return hot_api.send_message(hot_api.get_self_pid(), content)
`)
send_self :: proc(content: $T) -> Send_Error {
	return actod.send_self(content)
}

// Send a message to the parent. Must be called from within an actor.
@(hot = `compose
parent := hot_api.get_parent_pid()
if parent == 0 do return false
return hot_api.send_message(parent, content) == .OK
`)
send_message_to_parent :: proc(content: $T) -> bool {
	return actod.send_message_to_parent(content)
}

// Send a message to all children. Must be called from within an actor.
@(hot = `compose
for child in hot_api.get_children(hot_api.get_self_pid()) {
	if hot_api.send_message(child, content) != .OK do return false
}
return true
`)
send_message_to_children :: proc(content: $T) -> bool {
	return actod.send_message_to_children(content)
}

// Send a high priority message. Targets mailbox[0], processed before normal messages.
@(hot = `compose
hot_api.set_send_priority(.HIGH)
err := hot_api.send_message(to, content)
hot_api.set_send_priority(.NORMAL)
return err
`)
send_message_high :: proc(to: PID, content: $T) -> Send_Error {
	return actod.send_message_high(to, content)
}

// Send a low priority message. Targets mailbox[2], processed after normal messages.
@(hot = `compose
hot_api.set_send_priority(.LOW)
err := hot_api.send_message(to, content)
hot_api.set_send_priority(.NORMAL)
return err
`)
send_message_low :: proc(to: PID, content: $T) -> Send_Error {
	return actod.send_message_low(to, content)
}

// Set priority for subsequent sends. Use reset_send_priority() after.
// Useful for batch sends at the same priority.
set_send_priority :: proc(p: Message_Priority) {
	actod.set_send_priority(p)
}

// Reset send priority back to NORMAL. Must be called from within an actor.
reset_send_priority :: proc() {
	actod.reset_send_priority()
}

// Register a message type for deep-copy support and network serialization. Use with @(init).
@(hot = "noop")
register_message_type :: proc "contextless" ($T: typeid) {
	actod.register_message_type(T)
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

self_terminate :: proc(reason: Termination_Reason = .NORMAL) -> bool {
	return actod.self_terminate(reason)
}

self_rename :: proc(new_name: string) -> bool {
	return actod.self_rename(new_name)
}

// Cooperatively yield from a pooled actor, allowing other actors on the same worker to run.
// Must be called from within a pooled (non-dedicated-thread) actor.
// If you need this think about actor design
yield :: proc() {
	actod.yield()
}

// Returns real time in production, virtual time in tests.
now :: proc() -> time.Time {
	return actod.now()
}

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

set_timer :: proc(interval: time.Duration, repeat: bool) -> (u32, Send_Error) {
	return actod.set_timer(interval, repeat)
}

cancel_timer :: proc(id: u32) -> Send_Error {
	return actod.cancel_timer(id)
}

// =============================================================================
// Supervision
// =============================================================================

get_children :: proc(parent: PID) -> []PID {
	return actod.get_children(parent)
}

// Dynamically spawn and add a new child to a supervisor.
add_child :: proc(parent: PID, child_spawn: SPAWN) -> (PID, bool) {
	return actod.add_child(parent, child_spawn)
}

// Adopt an existing actor as a child of a supervisor.
@(hot = "extra_param spawn_func_name_hash: u64 = 0")
add_child_existing :: proc(parent: PID, existing_child: PID, child_spawn: SPAWN) -> (PID, bool) {
	return actod.add_child_existing(parent, existing_child, child_spawn)
}

remove_child :: proc(parent: PID, child: PID) -> bool {
	return actod.remove_child(parent, child)
}

// Register a named actor type. Returns the local Actor_Type ID.
register_actor_type :: proc(name: string) -> (Actor_Type, bool) {
	return actod.register_actor_type(name)
}

// Get the string name of a registered actor type.
get_actor_type_name :: proc(actor_type: Actor_Type) -> (string, bool) {
	return actod.get_actor_type_name(actor_type)
}

// Subscribe to broadcasts from actors of the given type. Must be called from within an actor.
// Subscriptions are automatically cleaned up on actor termination.
subscribe_type :: proc(actor_type: Actor_Type) -> (Subscription, bool) {
	return actod.subscribe_type(actor_type)
}

// Unsubscribe from a previously subscribed actor type.
@(hot = "host_name pubsub_unsubscribe")
unsubscribe :: proc(sub: Subscription) -> bool {
	return actod.pubsub_unsubscribe(sub)
}

// Broadcast a message to all subscribers of the current actor's type.
// Must be called from within a typed actor (actor_type set on behaviour).
broadcast :: proc(msg: $T) {
	actod.broadcast(msg)
}

get_subscriber_count :: proc(actor_type: Actor_Type) -> u32 {
	return actod.get_subscriber_count(actor_type)
}

subscribe_topic :: proc(topic: ^Topic) -> (Topic_Subscription, bool) {
	return actod.subscribe_topic(topic)
}

unsubscribe_topic :: proc(sub: Topic_Subscription) -> bool {
	return actod.unsubscribe_topic(sub)
}

publish :: proc(topic: ^Topic, msg: $T) {
	actod.publish(topic, msg)
}

@(hot = "skip")
register_node :: proc(
	name: string,
	address: net.Endpoint,
	transport: Transport_Strategy,
) -> (
	Node_ID,
	bool,
) {
	return actod.register_node(name, address, transport)
}

// Register a named spawn function for remote spawning and spawn_by_name.
register_spawn_func :: proc(name: string, func: SPAWN) -> bool {
	return actod.register_spawn_func(name, func)
}

@(hot = "skip")
get_node_info :: proc(node_id: Node_ID) -> (Node_Info, bool) {
	return actod.get_node_info(node_id)
}

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
start_observer :: proc(collection_interval: time.Duration = 0) -> (PID, bool) {
	return actod.start_observer(collection_interval)
}

@(hot = "skip")
stop_observer :: proc() {
	actod.stop_observer()
}

@(hot = "skip")
trigger_stats_collection :: proc() -> bool {
	return actod.trigger_stats_collection()
}

@(hot = "skip")
request_actor_stats :: proc(actor_pid: PID, requester: PID) -> bool {
	return actod.request_actor_stats(actor_pid, requester)
}

@(hot = "skip")
request_all_stats :: proc(requester: PID) -> bool {
	return actod.request_all_stats(requester)
}

@(hot = "skip")
set_stats_collection_interval :: proc(interval: time.Duration) -> bool {
	return actod.set_stats_collection_interval(interval)
}

@(hot = "skip")
clear_terminated_stats :: proc() -> bool {
	return actod.clear_terminated_stats()
}

// Subscribe to observer stats snapshots. Must be called from within an actor.
@(hot = "skip")
subscribe_to_stats :: proc() -> (Subscription, bool) {
	return actod.subscribe_to_stats()
}

@(hot = "skip")
unsubscribe_from_stats :: proc(sub: Subscription) -> bool {
	return actod.unsubscribe_from_stats(sub)
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
	)
}

@(hot = `compose
default children = nil
default spin_strategy = .CPU_RELAX
default logging = {}
default message_batch = 32
default page_size = 4096
default supervision_strategy = .ONE_FOR_ONE
default restart_policy = .TEMPORARY
default max_restarts = 3
default restart_window = 60 * time.Second
default home_worker = -1
default affinity = nil
default coro_stack_size = 16384
default use_dedicated_os_thread = false
default stack_size_dedicated_os_thread = 1048576
return hot_api.make_actor_config(children, spin_strategy, logging, message_batch, page_size, supervision_strategy, restart_policy, max_restarts, restart_window, home_worker, affinity, coro_stack_size, use_dedicated_os_thread, stack_size_dedicated_os_thread)
`)
make_actor_config :: proc(
	children: [dynamic]SPAWN = nil,
	spin_strategy: SPIN_STRATEGY = actod.SYSTEM_CONFIG.actor_config.spin_strategy,
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
	)
}

@(hot = "skip")
make_network_config :: proc(
	auth_password: string = actod.DEFAULT_NETWORK_CONFIG.auth_password,
	port: int = actod.DEFAULT_NETWORK_CONFIG.port,
	heartbeat_interval: time.Duration = actod.DEFAULT_NETWORK_CONFIG.heartbeat_interval,
	heartbeat_timeout: time.Duration = actod.DEFAULT_NETWORK_CONFIG.heartbeat_timeout,
	reconnect_initial_delay: time.Duration = actod.DEFAULT_NETWORK_CONFIG.reconnect_initial_delay,
	reconnect_retry_delay: time.Duration = actod.DEFAULT_NETWORK_CONFIG.reconnect_retry_delay,
	connection_ring: Connection_Ring_Config = actod.DEFAULT_NETWORK_CONFIG.connection_ring,
) -> Network_Config {
	return actod.make_network_config(
		auth_password,
		port,
		heartbeat_interval,
		heartbeat_timeout,
		reconnect_initial_delay,
		reconnect_retry_delay,
		connection_ring,
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
SPIN_STRATEGY :: actod.SPIN_STRATEGY

// Networking
Node_ID :: actod.Node_ID
Connection_Ring_Config :: actod.Connection_Ring_Config
Node_Info :: actod.Node_Info
Transport_Strategy :: actod.Transport_Strategy

// Observer
Actor_Stats :: actod.Actor_Stats
Stats_Snapshot :: actod.Stats_Snapshot
Stats_Response :: actod.Stats_Response
