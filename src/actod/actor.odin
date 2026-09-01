package actod

import "../../test_harness/ti"
_ :: ti
import "../pkgs/coro"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_MAIL_BOX_SIZE :: #config(ACTOD_MAILBOX_SIZE, 32)
#assert(
	DEFAULT_MAIL_BOX_SIZE > 0 && (DEFAULT_MAIL_BOX_SIZE & (DEFAULT_MAIL_BOX_SIZE - 1)) == 0,
	"-define:ACTOD_MAILBOX_SIZE must be a power of two",
)
SEND_RETRY_DELAY :: 1 * time.Microsecond
SEND_STALL_TIMEOUT :: #config(ACTOD_SEND_STALL_TIMEOUT_MS, 100) * time.Millisecond
SEND_MAX_BLOCK_TIMEOUT :: 100 * time.Millisecond
THREAD_SEND_SPIN_TRIES :: 4096
BATCH_SIZE :: LOCAL_MAILBOX_SIZE
FREE_BATCH_SIZE :: BATCH_SIZE
SPAWN :: proc(name: string, parent_pid: PID) -> (PID, bool)

Actor_State :: enum {
	ZERO,
	INIT,
	IDLE,
	RUNNING,
	STOPPING,
	THREAD_STOPPED,
	TERMINATED,
}
Actor_State_Set :: bit_set[Actor_State]

Send_Error :: enum {
	OK = 0,
	ACTOR_NOT_FOUND,
	RECEIVER_BACKLOGGED, // Mailbox full or message pool exhausted, receiver not draining
	MESSAGE_TOO_LARGE, // Message exceeds actor's configured page_size
	SYSTEM_SHUTTING_DOWN,
	NETWORK_ERROR,
	NETWORK_RING_FULL, // Ring buffer backpressure
	NODE_NOT_FOUND,
	NODE_DISCONNECTED,
	NOT_ASKED, // reply() without a pending ask, or ask() outside an actor
}

Supervision_Strategy :: enum {
	ONE_FOR_ONE, // Only restart the failed child
	ONE_FOR_ALL, // Restart all children if one fails
	REST_FOR_ONE, // Restart failed child and all started after it
}

Restart_Policy :: enum {
	PERMANENT, // Always restart
	TRANSIENT, // Restart only on abnormal termination
	TEMPORARY, // Never restart
}

Termination_Reason :: enum {
	NORMAL, // Clean shutdown requested by user
	ABNORMAL, // Crash or panic
	SHUTDOWN, // Parent or system requested shutdown
	MAX_RESTARTS, // Exceeded restart limit
	INTERNAL_ERROR, // Actor detected internal error and self-terminated
	KILLED, // Forcefully killed
}

// defines actor behaviour. All user code that interacts with $T should be done inside
// one of these functions for thread safety
Actor_Behaviour :: struct($T: typeid) {
	handle_message:           proc(data: ^T, from: PID, content: any), // Required
	init:                     proc(data: ^T), // this should be non blocking
	terminate:                proc(data: ^T),
	on_idle:                  proc(data: ^T),
	actor_type:               Actor_Type, // 0 = untyped (default), 1-255 = user-defined

	// Supervisor callbacks (all optional)
	on_child_started:         proc(data: ^T, child_pid: PID),
	on_child_terminated:      proc(
		data: ^T,
		child_pid: PID,
		reason: Termination_Reason,
		will_restart: bool,
	),
	on_child_restarted:       proc(data: ^T, old_pid: PID, new_pid: PID, restart_count: int),
	on_max_restarts_exceeded: proc(data: ^T, child_pid: PID),
}

ACTOR_MAILBOX :: MPSC_Queue(Message, 0)

Restart_Info :: struct {
	count:                int,
	first_restart:        time.Time,
	last_restart:         time.Time,
	child_index:          int,
	spawn_func_name_hash: u64,
	node_id:              Node_ID,
}

LOCAL_MAILBOX_SIZE :: 64

STOP_SIGNAL_NAME_CAP :: 64

STOP_SIGNAL_CHAIN_BOUND :: 1 << 24

Stop_Signal :: struct {
	next:     rawptr,
	pid:      PID,
	reason:   Termination_Reason,
	name_len: int,
	name_buf: [STOP_SIGNAL_NAME_CAP]u8,
}

Actor :: struct($T: typeid) #align (CACHE_LINE_SIZE) {
	state:              Actor_State,
	local_write:        u64,
	local_read:         u64,
	local_buf:          ^[LOCAL_MAILBOX_SIZE]Message,
	pool_handle:        ^Pooled_Actor_Handle,
	msg_ctx:            ^Message_Processing_Context,
	actor_ctx:          ^Actor_Context,
	data:               ^T,
	handle_message:     proc(data: ^T, from: PID, content: any),
	pid:                PID,
	pool:               Pool,
	mailbox:            ACTOR_MAILBOX,
	system_mailbox:     ACTOR_MAILBOX,
	wake_sema:          sync.Atomic_Sema,
	behaviour:          Actor_Behaviour(T),
	opts:               Actor_Config,
	allocator:          mem.Allocator,
	arena:              Actor_Arena,
	arena_slot:         u32,
	parent:             PID,
	name:               string,
	thread:             ^thread.Thread,
	restart_info:       Restart_Info,
	termination_reason: Termination_Reason,
	spawn_loc:          runtime.Source_Code_Location,
	stop_signal:        Stop_Signal,
	stopped_head:       rawptr,
	stopped_closed:     bool,
	blocking:           bool,
	system_drops:       u64,

	// keep unknown sizes at the bottom
	children:           [dynamic]PID,
	child_restarts:     map[PID]Restart_Info,
	started:            ^bool,
}

Panic_Jmp_Buf :: struct #align (16) {
	_: [512]byte,
}

@(private)
Actor_Context :: struct {
	pid:                 PID,
	name:                string,
	panic_teardown_started: bool,
	panic_recovery_done: bool,
	panic_jmp_buf:       Panic_Jmp_Buf,
	panic_message:       [PANIC_MESSAGE_BUF_SIZE]u8,
	panic_message_len:   int,
	panic_location:      runtime.Source_Code_Location,
	subscriptions:       [dynamic]Subscription,
	topic_subscriptions: [dynamic]Topic_Subscription,
	pending_asks:        map[u64]u32,
	timer_asks:          map[u32]u64,
	next_ask_token:      u64,
	current_ask_token:   u64,
	current_ask_from:    PID,
	current_reply_token: u64,
	ask_dirty:           bool,
	used_timers:         bool,
	stats:               struct {
		received_list:     [dynamic]PID,
		sent_list:         [dynamic]PID,
		messages_received: u64,
		messages_sent:     u64,
		start_time:        time.Time,
		max_mailbox_size:  int,
		// heap allocator managed by observer
		received_from:     map[PID]u64,
		sent_to:           map[PID]u64,
	},
	logger_data:         Actor_Logger_Data,
}

ARENA_COMMIT_SIZE :: mem.Kilobyte * 64
ARENA_FIXED_OVERHEAD :: mem.Kilobyte * 64

@(private)
actor_arena_reserve :: proc(data_size: int, mailbox_size: int, opts: Actor_Config) -> uint {
	max_pages := pool_max_pages(mailbox_size)
	pool_pages := max_pages * opts.page_size
	pool_bookkeeping :=
		next_power_of_two(max_pages) * size_of(Pool_Entry) + max_pages * size_of(rawptr)
	mailbox_bytes := (mailbox_size + SYSTEM_MAILBOX_SIZE) * size_of(Entry(Message))
	local_bytes := size_of([LOCAL_MAILBOX_SIZE]Message)
	static_worst :=
		data_size +
		mailbox_bytes +
		pool_pages +
		pool_bookkeeping +
		local_bytes +
		size_of(Actor_Context) +
		ARENA_FIXED_OVERHEAD
	return uint(static_worst + opts.arena_headroom)
}

DEFAULT_ACTOR_SLOT_BYTES :: 128 * mem.Kilobyte

@(private)
actor_arena_slot_size :: proc(opts: Actor_Config) -> uint {
	eager :=
		DEFAULT_MAIL_BOX_SIZE * size_of(Entry(Message)) +
		SYSTEM_MAILBOX_SIZE * size_of(Entry(Message)) +
		size_of(Actor_Context) +
		ARENA_FIXED_OVERHEAD
	slot := max(uint(DEFAULT_ACTOR_SLOT_BYTES), uint(eager))
	return slot
}

@(private)
reconstruct_msg :: #force_inline proc(msg: ^Message, data: ^any, header: ^^Type_Header) {
	if msg.content == nil {
		data.data = &msg.inline_data
		data.id = msg.inline_type
		header^ = nil
	} else if msg.content == INLINE_NEEDS_FIXUP {
		data.data = &msg.inline_data
		data.id = msg.inline_type
		header^ = nil
		fixup_inline_pointers(&msg.inline_data, msg.inline_type)
	} else {
		intrinsics.prefetch_read_data(msg.content, 3)
		header^ = cast(^Type_Header)msg.content
		data.data = rawptr(uintptr(msg.content) + uintptr(TYPE_HEADER_SIZE))
		data.id = header^.type_id
		if header^.size > CACHE_LINE_SIZE do intrinsics.prefetch_read_data(data.data, 3)
	}
}

@(require_results)
send_self :: #force_inline proc(content: $T, loc := #caller_location) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_self(content); ok do return Send_Error(r)}
	v := content
	info := get_validated_message_info_ptr(T, loc)
	CLASS :: Msg_Class.System when intrinsics.type_is_variant_of(SYSTEM_MSG, T) else Msg_Class.User
	return send_self_impl(&v, size_of(T), typeid_of(T), info, CLASS, loc)
}

@(require_results)
send_message :: #force_inline proc(to: PID, content: $T, loc := #caller_location) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message(u64(to), content); ok do return Send_Error(r)}
	v := content
	info := get_validated_message_info_ptr(T, loc)
	CLASS :: Msg_Class.System when intrinsics.type_is_variant_of(SYSTEM_MSG, T) else Msg_Class.User
	return send_message_impl(to, &v, size_of(T), typeid_of(T), info, CLASS, loc)
}

// Send message by actor name. Supports both local and remote actors.
// For remote actors, use format: "actor_name@node_name"
// Examples:
//   send_message_name("my_actor", msg)                // Local actor
//   send_message_name("my_actor@remote_node", msg)    // Remote actor on "remote_node"
// For dynamic node/actor names, use send_to(actor, node, msg) instead.
// For performance with known PIDs, use send_message(to: PID, content) instead.
@(require_results)
send_message_name :: proc(to: string, content: $T, loc := #caller_location) -> Send_Error {
	context.logger = diagnostic_logger(context.logger)
	when ODIN_TEST {if r, ok := ti.intercept_send_message_name(to, content); ok do return Send_Error(r)}

	for c, i in to {
		if c == '@' {
			actor_name := to[:i]
			node_name := to[i + 1:]

			if _, exists := get_node_by_name(node_name); exists {
				return send_remote_by_name(node_name, actor_name, content, loc)
			}

			log.errorf(
				"send_message_name('%s') failed: no node named '%s' is registered. Call register_node() first",
				to,
				node_name,
				location = loc,
			)
			return .NODE_NOT_FOUND
		}
	}

	local_pid, found := get_actor_pid(to)
	if !found {
		log.errorf(
			"send_message_name('%s') failed: no local actor is registered under that name. Use \"actor@node\" to reach a remote actor",
			to,
			location = loc,
		)
		return .ACTOR_NOT_FOUND
	}
	return send_message(local_pid, content, loc)
}

// Send message to a remote actor with dynamic node and actor names.
@(require_results)
send_to :: proc(
	actor_name: string,
	node_name: string,
	content: $T,
	loc := #caller_location,
) -> Send_Error {
	context.logger = diagnostic_logger(context.logger)
	when ODIN_TEST {if r, ok := ti.intercept_send_to(actor_name, node_name, content); ok do return Send_Error(r)}

	if _, exists := get_node_by_name(node_name); exists {
		return send_remote_by_name(node_name, actor_name, content, loc)
	}
	log.errorf(
		"send_to('%s', '%s') failed: no node named '%s' is registered. Call register_node() first",
		actor_name,
		node_name,
		node_name,
		location = loc,
	)
	return .NODE_NOT_FOUND
}

@(require_results)
send_message_to_children :: #force_inline proc(content: $T, loc := #caller_location) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_to_children(content); ok do return Send_Error(r)}
	v := content
	info := get_validated_message_info_ptr(T, loc)
	CLASS :: Msg_Class.System when intrinsics.type_is_variant_of(SYSTEM_MSG, T) else Msg_Class.User
	return send_message_to_children_impl(&v, size_of(T), typeid_of(T), info, CLASS, loc)
}

@(require_results)
send_message_to_parent :: #force_inline proc(content: $T, loc := #caller_location) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_to_parent(content); ok do return Send_Error(r)}
	v := content
	info := get_validated_message_info_ptr(T, loc)
	CLASS :: Msg_Class.System when intrinsics.type_is_variant_of(SYSTEM_MSG, T) else Msg_Class.User
	return send_message_to_parent_impl(&v, size_of(T), typeid_of(T), info, CLASS, loc)
}

@(private)
retry_local_send :: #force_no_inline proc(
	actor: ^Actor(int),
	msg: Message,
	to: PID,
	loc := #caller_location,
) -> Send_Error {
	co := coro.running()
	if co == nil {
		msg := msg
		release_undelivered(actor, &msg, true)
		log.errorf(
			"send to %s failed: local mailbox is full and the sender cannot yield, receiver is not draining",
			actor_origin(to),
			location = loc,
		)
		return .RECEIVER_BACKLOGGED
	}

	return retry_local_send_loop(co, msg, to, actor.local_read, loc)
}

@(private)
retry_local_send_loop :: proc(
	co: ^coro.Coro,
	msg: Message,
	to: PID,
	initial_read: u64,
	loc := #caller_location,
) -> Send_Error {
	msg := msg
	handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
	observed_read := initial_read
	stall_start := mono_now()
	for {
		handle.wants_reschedule = true
		coro.yield(co)
		reclaim_pin()
		fresh, ok := get_relaxed(&NODE.actor_registry, to)
		if !ok || fresh == nil {
			reclaim_unpin()
			return .ACTOR_NOT_FOUND
		}
		target := cast(^Actor(int))fresh
		state := sync.atomic_load(&target.state)
		if state != .RUNNING && state != .IDLE && state != .INIT {
			release_undelivered(target, &msg, true)
			reclaim_unpin()
			return .ACTOR_NOT_FOUND
		}
		if target.local_write - target.local_read < LOCAL_MAILBOX_SIZE {
			ensure_local_buf(target)
			target.local_buf[target.local_write & (LOCAL_MAILBOX_SIZE - 1)] = msg
			target.local_write += 1
			if !sync.atomic_load_explicit(&target.pool_handle.in_ready_queue, .Relaxed) {
				wake_actor(target)
			}
			handle_set_message_stats(msg.from, to)
			reclaim_unpin()
			return .OK
		}
		if sync.atomic_load(&NODE.shutting_down) {
			release_undelivered(target, &msg, true)
			reclaim_unpin()
			return .SYSTEM_SHUTTING_DOWN
		}
		if target.local_read != observed_read {
			observed_read = target.local_read
			stall_start = mono_now()
		} else if mono_since(stall_start) > SEND_STALL_TIMEOUT {
			release_undelivered(target, &msg, true)
			reclaim_unpin()
			log.errorf(
				"send to %s failed: local mailbox still full after %v with the receiver making no progress",
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
ensure_local_buf :: #force_inline proc(actor: ^Actor(int)) {
	if actor.local_buf == nil {
		raw, err := mem.alloc_bytes_non_zeroed(
			size_of([LOCAL_MAILBOX_SIZE]Message),
			align_of([LOCAL_MAILBOX_SIZE]Message),
			actor.allocator,
		)
		if err == nil do actor.local_buf = cast(^[LOCAL_MAILBOX_SIZE]Message)raw_data(raw)
	}
}

@(private)
push_to_mailbox :: #force_inline proc(
	actor: ^Actor(int),
	msg: Message,
	to: PID,
	loc := #caller_location,
) -> Send_Error {
	// Local if on same worker. A sender's messages must never split between
	// local_buf and the MPSC: local drains first, so a split reorders them.
	if current_worker != nil &&
	   actor.pool_handle != nil &&
	   actor.pool_handle.home_worker == current_worker {
		if actor.local_write - actor.local_read < LOCAL_MAILBOX_SIZE {
			ensure_local_buf(actor)
			actor.local_buf[actor.local_write & (LOCAL_MAILBOX_SIZE - 1)] = msg
			actor.local_write += 1
			if !sync.atomic_load_explicit(&actor.pool_handle.in_ready_queue, .Relaxed) {
				wake_actor(actor)
			}
			handle_set_message_stats(msg.from, to)
			return .OK
		}
		return retry_local_send(actor, msg, to, loc)
	}

	if mpsc_push(&actor.mailbox, msg) {
		wake_actor(actor)
		handle_set_message_stats(msg.from, to)
		return .OK
	}

	blocked_msg := msg
	return send_user_backpressure(to, &blocked_msg, true, nil, 0, nil, nil, 0, loc)
}

@(private)
report_alloc_error :: #force_no_inline proc(
	err: Alloc_Error,
	attempted_size: int,
	pool: ^Pool,
	to: PID,
	loc := #caller_location,
) -> Send_Error {
	switch err {
	case .OK:
		return .OK
	case .SIZE_EXCEEDS_PAGE:
		log.errorf(
			"send to %s failed: message needs %d B but the receiver's page size is %d B. Raise page_size in make_actor_config() for that actor",
			actor_origin(to),
			attempted_size,
			pool.page_size,
			location = loc,
		)
		return .MESSAGE_TOO_LARGE
	case .POOL_EXHAUSTED:
		log.errorf(
			"send to %s failed: message pool is at its %d page cap, receiver is not draining its mailbox",
			actor_origin(to),
			pool.max_pages,
			location = loc,
		)
		return .RECEIVER_BACKLOGGED
	case .OUT_OF_MEMORY:
		log.errorf(
			"send to %s failed: the host is out of memory (could not allocate a %d B message page)",
			actor_origin(to),
			attempted_size,
			location = loc,
		)
		return .RECEIVER_BACKLOGGED
	case .ALLOC_CONTENDED:
		log.errorf(
			"send to %s failed: message page allocation lost %d contended attempts, the pool is thrashing under load",
			actor_origin(to),
			MAX_ALLOC_RETRIES,
			location = loc,
		)
		return .RECEIVER_BACKLOGGED
	case .MALFORMED_PAYLOAD:
		log.errorf(
			"send to %s failed: network payload truncated or malformed (variable data exceeds payload)",
			actor_origin(to),
			location = loc,
		)
		return .NETWORK_ERROR
	}
	return .RECEIVER_BACKLOGGED
}

@(private)
send :: #force_inline proc(
	to: PID,
	content: $T,
	actor: ^Actor(int),
	loc := #caller_location,
) -> Send_Error {
	v := content
	info := get_validated_message_info_ptr(T, loc)
	CLASS :: Msg_Class.System when intrinsics.type_is_variant_of(SYSTEM_MSG, T) else Msg_Class.User
	return send_to_actor_impl(to, actor, &v, size_of(T), typeid_of(T), info, CLASS, loc)
}

@(require_results)
terminate_actor :: proc(
	to: PID,
	reason: Termination_Reason = .SHUTDOWN,
	loc := #caller_location,
) -> bool {
	context.logger = diagnostic_logger(context.logger)
	when ODIN_TEST {if ti.intercept_terminate_actor(u64(to), ti.Termination_Reason(reason)) do return true}

	if !is_local_pid(to) {
		err := send_message(to, Terminate{reason = reason}, loc = loc)
		if err == .NODE_DISCONNECTED || err == .ACTOR_NOT_FOUND do return true
		return err == .OK
	}

	is_system_op := reason == .SHUTDOWN
	actor_ptr := get(&NODE.actor_registry, to)

	if actor_ptr == nil do return true

	state_ptr := cast(^Actor_State)(uintptr(actor_ptr) + offset_of(Actor(int), state))
	state := sync.atomic_load(state_ptr)
	if state == .STOPPING || state == .THREAD_STOPPED || state == .TERMINATED do return true

	actor, ok := get_actor_from_pointer(actor_ptr, is_system_op)
	if !ok {
		log.errorf(
			"terminate_actor(%v) failed: the PID is stale, it refers to a slot that has since been reused",
			to,
			location = loc,
		)
		return false
	}
	err := send(to, Terminate{reason = reason}, actor, loc)
	if err == .ACTOR_NOT_FOUND do return true
	if err != .OK {
		log.errorf(
			"terminate_actor failed for %s: could not deliver Terminate: %v",
			actor_origin(to),
			err,
			location = loc,
		)
		return false
	}
	return true
}

// Dynamically add a child to a supervisor
@(require_results)
add_child :: proc(parent: PID, child_spawn: SPAWN, loc := #caller_location) -> bool {
	context.logger = diagnostic_logger(context.logger)
	if child_spawn == nil {
		panic_at(loc, "add_child(parent=%v): child_spawn must not be nil", parent)
	}

	parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, parent))
	if !ok {
		log.errorf(
			"add_child failed: parent %v is not a live actor (never spawned, already terminated, or a stale PID)",
			parent,
			location = loc,
		)
		return false
	}

	// Send system message to supervisor to handle child addition
	msg := Add_Child {
		spawn_func   = child_spawn,
		existing_pid = 0,
	}
	err := send(parent, msg, parent_actor, loc)
	if err != .OK {
		log.errorf(
			"add_child failed: could not deliver Add_Child to parent %s: %v",
			actor_origin(parent),
			err,
			location = loc,
		)
		return false
	}

	return true
}

adopt_child :: add_child_existing

// Dynamically adopt an existing actor as a child of a supervisor
@(require_results)
add_child_existing :: proc(
	parent: PID,
	existing_child: PID,
	child_spawn: SPAWN,
	spawn_func_name_hash: u64 = 0,
	loc := #caller_location,
) -> bool {
	context.logger = diagnostic_logger(context.logger)
	if child_spawn == nil && spawn_func_name_hash == 0 {
		panic_at(
			loc,
			"add_child_existing(parent=%v, child=%v): child_spawn must not be nil unless spawn_func_name_hash identifies a registered remote spawn function",
			parent,
			existing_child,
		)
	}

	parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, parent))
	if !ok {
		log.errorf(
			"add_child_existing failed: parent %v is not a live actor (never spawned, already terminated, or a stale PID)",
			parent,
			location = loc,
		)
		return false
	}

	msg := Add_Child {
		spawn_func           = child_spawn,
		existing_pid         = existing_child,
		spawn_func_name_hash = spawn_func_name_hash,
	}
	err := send(parent, msg, parent_actor, loc)
	if err != .OK {
		log.errorf(
			"add_child_existing(child=%v) failed: could not deliver Add_Child to parent %s: %v",
			existing_child,
			actor_origin(parent),
			err,
			location = loc,
		)
		return false
	}

	return true
}

// Remove a child from a supervisor
@(require_results)
remove_child :: proc(parent: PID, child: PID, loc := #caller_location) -> bool {
	context.logger = diagnostic_logger(context.logger)
	parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, parent))
	if !ok {
		log.errorf(
			"remove_child(child=%v) failed: parent %v is not a live actor",
			child,
			parent,
			location = loc,
		)
		return false
	}

	msg := Remove_Child {
		child_pid = child,
	}

	err := send(parent, msg, parent_actor, loc)
	if err != .OK {
		log.errorf(
			"remove_child(child=%v) failed: could not deliver Remove_Child to parent %s: %v",
			child,
			actor_origin(parent),
			err,
			location = loc,
		)
		return false
	}
	return true
}

// Get list of children for an actor
get_children :: proc(parent: PID) -> []PID {
	parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, parent))
	if !ok do return nil

	// Return a copy to avoid external modifications
	result := make([]PID, len(parent_actor.children))
	copy(result, parent_actor.children[:])
	return result
}

get_parent_pid :: proc() -> PID {
	actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, get_self_pid()))
	if !ok do return 0
	return actor.parent
}

get_actor_name :: #force_inline proc(pid: PID) -> string {
	actor_ptr, active := get(&NODE.actor_registry, pid)
	if !active || actor_ptr == nil do return "<unknown>"

	name_offset := offset_of(Actor(int), name)
	name_ptr := cast(^string)(uintptr(actor_ptr) + name_offset)
	return name_ptr^
}

@(require_results)
get_actor_pid :: #force_inline proc(name: string) -> (PID, bool) {
	when ODIN_TEST {if pid, found, ok := ti.intercept_get_actor_pid(name); ok do return PID(pid), found}

	return get_by_name(&NODE.actor_registry, name)
}

get_actor_parent :: #force_inline proc(pid: PID) -> PID {
	actor_ptr, active := get(&NODE.actor_registry, pid)
	if !active || actor_ptr == nil do return 0
	parent_offset := offset_of(Actor(int), parent)
	parent_ptr := cast(^PID)(uintptr(actor_ptr) + parent_offset)
	return parent_ptr^
}

// Scary: Raw pointer to the live Actor struct for a PID, or nil if the PID is not
// active on this node. The returned pointer is only valid while the actor is
// alive; callers doing field reads via offset_of(Actor(T), ...) must not
// retain it past the operation. Returns nil for remote PIDs.
get_actor_ptr :: #force_inline proc(pid: PID) -> rawptr {
	ptr, _ := get(&NODE.actor_registry, pid)
	return ptr
}

get_self_name :: #force_inline proc() -> string {
	when ODIN_TEST {if name, ok := ti.intercept_get_self_name(); ok do return name}

	if current_actor_context != nil do return current_actor_context.name
	return ""
}

get_self_pid :: #force_inline proc() -> PID {
	when ODIN_TEST {if pid, ok := ti.intercept_get_self_pid(); ok do return PID(pid)}

	if current_actor_context != nil do return current_actor_context.pid
	return pack_pid(Handle{idx = 0, gen = 0, actor_type = 0}, NODE.node_id)
}

self_terminate :: proc(reason: Termination_Reason = .NORMAL, loc := #caller_location) -> bool {
	when ODIN_TEST {if ti.intercept_self_terminate(ti.Termination_Reason(reason)) do return true}

	if current_actor_context == nil {
		log.error(
			"self_terminate failed: must be called from inside an actor",
			location = loc,
		)
		return false
	}
	pid := get_self_pid()
	return terminate_actor(pid, reason, loc)
}

@(require_results)
rename_actor :: proc(pid: PID, new_name: string, loc := #caller_location) -> bool {
	context.logger = diagnostic_logger(context.logger)
	when ODIN_TEST {if ti.intercept_rename_actor(u64(pid), new_name) do return true}

	actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, pid), true)
	if !ok {
		log.errorf(
			"rename_actor(%v, '%s') failed: no live actor with that PID",
			pid,
			new_name,
			location = loc,
		)
		return false
	}

	msg := Rename_Actor {
		new_name = new_name,
	}

	err := send(pid, msg, actor, loc)
	if err != .OK {
		log.errorf(
			"rename_actor('%s') failed: could not deliver Rename_Actor to %s: %v",
			new_name,
			actor_origin(pid),
			err,
			location = loc,
		)
		return false
	}
	return true
}

self_rename :: proc(new_name: string, loc := #caller_location) -> bool {
	when ODIN_TEST {if ti.intercept_self_rename(new_name) do return true}

	if current_actor_context == nil {
		log.errorf(
			"self_rename('%s') failed: must be called from inside an actor",
			new_name,
			location = loc,
		)
		return false
	}
	pid := get_self_pid()
	return rename_actor(pid, new_name, loc)
}

yield :: proc(loc := #caller_location) {
	co := coro.running()
	if co == nil {
		panic_at(
			loc,
			"yield() must be called from inside a pooled actor. It is not available on the main thread, or in an actor spawned with use_dedicated_os_thread or blocking",
		)
	}
	handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
	handle.wants_reschedule = true
	coro.yield(co)
}

@(private)
create_message :: #force_inline proc(
	msg: ^Message,
	pool: ^Pool,
	value: $T,
	info: ^Message_Type_Info,
) -> (
	Alloc_Error,
	int,
) {
	v := value
	return make_message_impl(msg, pool, &v, size_of(T), typeid_of(T), info)
}

// Send message directly from network payload to actor's mailbox
// Bypasses the typed intermediate copy in the normal send path
send_from_payload :: #force_inline proc(
	to_pid: PID,
	from_pid: PID,
	payload: []byte,
	info: ^Message_Type_Info,
	token: u64 = 0,
) -> Send_Error {
	actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, to_pid))
	if !ok do return .ACTOR_NOT_FOUND

	current_state := sync.atomic_load(&actor.state)
	if current_state != .RUNNING && current_state != .IDLE do return .ACTOR_NOT_FOUND

	msg: Message
	msg.from = from_pid

	alloc_err, attempted_size := create_message_from_payload(&msg, &actor.pool, payload, info, token)
	if alloc_err != .OK do return report_alloc_error(alloc_err, attempted_size, &actor.pool, to_pid)

	return push_to_mailbox(actor, msg, to_pid)
}

send_system_from_payload :: #force_inline proc(
	to_pid: PID,
	from_pid: PID,
	payload: []byte,
	info: ^Message_Type_Info,
) -> Send_Error {
	actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, to_pid))
	if !ok do return .ACTOR_NOT_FOUND

	current_state := sync.atomic_load(&actor.state)
	if current_state == .TERMINATED ||
	   current_state == .THREAD_STOPPED ||
	   current_state == .STOPPING {
		return .ACTOR_NOT_FOUND
	}

	msg: Message
	msg.from = from_pid

	alloc_err, attempted_size := create_message_from_payload(&msg, &actor.pool, payload, info)
	if alloc_err != .OK do return report_alloc_error(alloc_err, attempted_size, &actor.pool, to_pid)

	if !mpsc_push(&actor.system_mailbox, msg) {
		log.errorf(
			"system mailbox of %s is full, dropping a remote %v",
			actor_origin(to_pid),
			info.name,
		)
		if message_owns_page(msg.content) {
			free_message(&actor.pool, msg.content)
		}
		return .RECEIVER_BACKLOGGED
	}

	wake_actor(actor)
	return .OK
}

@(private)
track_message_received :: proc(from: PID) {
	if NODE.observer_pid != {} {
		current_actor_context.stats.messages_received += 1
		if from != 0 do append(&current_actor_context.stats.received_list, from)
	}
}

@(private)
track_max_mailbox_size :: proc(mailbox: ^ACTOR_MAILBOX) {
	if NODE.observer_pid != {} {
		current_size := mpsc_size(mailbox)
		if current_size > current_actor_context.stats.max_mailbox_size {
			current_actor_context.stats.max_mailbox_size = current_size
		}
	}
}

@(private)
build_pid_histogram :: proc(list: []PID) -> map[PID]u64 {
	histogram := make(map[PID]u64)
	for pid in list do histogram[pid] += 1
	return histogram
}

@(private)
collect_actor_stats :: proc(actor: ^Actor($T)) -> Actor_Stats {
	stats := Actor_Stats {
		pid        = actor.pid,
		name       = actor.name,
		parent_pid = actor.parent,
		state      = sync.atomic_load(&actor.state),
		terminated = false,
	}

	if current_actor_context != nil {
		stats.messages_received = current_actor_context.stats.messages_received
		stats.messages_sent = current_actor_context.stats.messages_sent
		stats.start_time = current_actor_context.stats.start_time
		stats.uptime = wall_since(current_actor_context.stats.start_time)
		stats.last_update = now()
		stats.max_mailbox_size = current_actor_context.stats.max_mailbox_size

		stats.mailbox_size = mpsc_size(&actor.mailbox)
		stats.system_mailbox_size = mpsc_size(&actor.system_mailbox)

		saved_allocator := context.allocator
		context.allocator = actor_system_allocator
		defer context.allocator = saved_allocator

		stats.received_from = build_pid_histogram(current_actor_context.stats.received_list[:])
		stats.sent_to = build_pid_histogram(current_actor_context.stats.sent_list[:])

		clear_dynamic_array(&current_actor_context.stats.received_list)
		clear_dynamic_array(&current_actor_context.stats.sent_list)
	}

	return stats
}

@(private)
handle_set_message_stats :: #force_inline proc(from: PID, to: PID) {
	if NODE.observer_pid != {} {
		if current_actor_context != nil && current_actor_context.pid == from {
			current_actor_context.stats.messages_sent += 1
			append(&current_actor_context.stats.sent_list, to)
		}
	}
}

@(private)
handle_get_stats_request :: proc(actor: ^Actor($T), request: Get_Stats) {
	current_state := sync.atomic_load(&actor.state)
	if current_state == .STOPPING ||
	   current_state == .THREAD_STOPPED ||
	   current_state == .TERMINATED {
		return
	}

	stats := collect_actor_stats(actor)
	response := Stats_Response {
		stats = stats,
	}

	requester_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, request.requester))
	if ok {
		send(request.requester, response, requester_actor)
	} else {
		delete(stats.received_from)
		delete(stats.sent_to)
	}
}

@(private)
handle_rename_actor :: proc(actor: ^Actor($T), msg: Rename_Actor) {
	old_name := strings.clone(actor.name)
	defer delete(old_name)

	if actor.name != "" do delete(actor.name, actor.allocator)

	actor.name = strings.clone(msg.new_name, actor.allocator)
	current_actor_context.name = actor.name

	pid_map_rename(&NODE.actor_registry, actor.pid, msg.new_name)

	h, _ := unpack_pid(current_actor_context.pid)
	log.infof("Actor [%s|%v:%v] renamed to '%s'", old_name, h.idx, h.gen, msg.new_name)
}

cleanup_actor_thread :: proc(actor_ptr: rawptr) {
	thread_offset := offset_of(Actor(int), thread)
	thread_ptr_ptr := cast(^^thread.Thread)(uintptr(actor_ptr) + thread_offset)

	if thread_ptr_ptr^ != nil {
		thread.join(thread_ptr_ptr^)
		thread.destroy(thread_ptr_ptr^)
	}
}

try_transition_state :: proc(state_ptr: ^Actor_State, from: Actor_State, to: Actor_State) -> bool {
	_, swapped := sync.atomic_compare_exchange_strong(state_ptr, from, to)
	return swapped
}

get_actor_from_pointer :: #force_inline proc(
	actor_ptr: rawptr,
	system_operation := false,
) -> (
	^Actor(int),
	bool,
) {
	if actor_ptr == nil {
		return {}, false
	}

	if sync.atomic_load(&NODE.shutting_down) && !system_operation {
		current_pid := get_self_pid()
		if current_pid != NODE.pid {
			return {}, false
		}
	}

	actor_ptr_typed := cast(^Actor(int))actor_ptr
	return actor_ptr_typed, true
}
