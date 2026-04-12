package actod

import "../../test_harness/ti"
_ :: ti
import "../pkgs/coro"
import "../pkgs/threads_act"
import "base:intrinsics"
import "base:runtime"
import "core:c/libc"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

MAILBOX_PRIORITY_COUNT :: 3
DEFAULT_MAIL_BOX_SIZE :: 128
MAX_SEND_RETRIES :: 1000
SEND_RETRY_DELAY :: 1 * time.Microsecond
BATCH_SIZE :: DEFAULT_MAIL_BOX_SIZE / 4
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
	MAILBOX_FULL,
	POOL_FULL,
	SYSTEM_SHUTTING_DOWN,
	NETWORK_ERROR,
	NETWORK_RING_FULL, // Ring buffer backpressure
	NODE_NOT_FOUND,
	NODE_DISCONNECTED,
}

Message_Priority :: enum u8 {
	HIGH   = 0,
	NORMAL = 1,
	LOW    = 2,
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

ACTOR_MAILBOX :: [MAILBOX_PRIORITY_COUNT]MPSC_Queue(Message, DEFAULT_MAIL_BOX_SIZE)

Restart_Info :: struct {
	count:                int,
	first_restart:        time.Time,
	last_restart:         time.Time,
	child_index:          int,
	spawn_func_name_hash: u64,
	node_id:              Node_ID,
}

LOCAL_MAILBOX_SIZE :: 64

Actor :: struct($T: typeid) #align (CACHE_LINE_SIZE) {
	state:              Actor_State,
	local_write:        u64,
	local_read:         u64,
	local_buf:          ^[LOCAL_MAILBOX_SIZE]Message,
	pool_handle:        ^Pooled_Actor_Handle,
	data:               ^T,
	handle_message:     proc(data: ^T, from: PID, content: any),
	pid:                PID,
	pool:               Pool,
	mailbox:            ACTOR_MAILBOX,
	system_mailbox:     MPSC_Queue(Message, SYSTEM_MAILBOX_SIZE),
	wake_sema:          sync.Atomic_Sema,
	behaviour:          Actor_Behaviour(T),
	opts:               Actor_Config,
	allocator:          mem.Allocator,
	arena:              vmem.Arena,
	parent:             PID,
	name:               string,
	thread:             ^thread.Thread,
	restart_info:       Restart_Info,
	termination_reason: Termination_Reason,

	// keep unknown sizes at the bottom
	children:           [dynamic]PID,
	child_restarts:     map[PID]Restart_Info,
	started:            ^bool,
}

@(private)
Actor_Context :: struct {
	pid:                 PID,
	name:                string,
	send_priority:       Message_Priority,
	panic_jmp_buf:       libc.jmp_buf,
	panic_message:       [PANIC_MESSAGE_BUF_SIZE]u8,
	panic_message_len:   int,
	panic_location:      runtime.Source_Code_Location,
	subscriptions:       [dynamic]Subscription,
	topic_subscriptions: [dynamic]Topic_Subscription,
	timers:              [dynamic]Timer_Registration,
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
}

spawn :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts := SYSTEM_CONFIG.actor_config,
	parent_pid: PID = 0,
) -> (
	PID,
	bool,
) {
	when ODIN_TEST {
		if pid, ok := ti.intercept_spawn(name, T); ok {
			return PID(pid), true
		}
	}

	if !NODE.started {
		log.panic("Must call actor.INIT_NODE() first.")
	}

	if behaviour.handle_message == nil {
		log.panic("Actor_Behaviour.handle_message must not be nil")
	}

	actor := new(Actor(T), actor_system_allocator)

	if actor.state != .ZERO {
		log.panic("reusing non zero memory")
	}

	arena_err := vmem.arena_init_static(&actor.arena)
	ensure(arena_err == nil)
	actor.allocator = vmem.arena_allocator(&actor.arena)
	context.allocator = actor.allocator

	actor.name = strings.clone(name, context.allocator)

	when size_of(T) > 0 {
		actor.data = new(T, actor.allocator)
		if actor.data == nil {
			log.errorf("Failed to allocate actor data for %s", name)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
		actor.data^ = data
	} else {
		ptr, err := mem.alloc(1, align_of(T), actor.allocator)
		if err != nil {
			log.errorf("Failed to allocate actor data for %s: %v", name, err)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
		actor.data = cast(^T)ptr
	}

	actor.behaviour = behaviour
	actor.handle_message = behaviour.handle_message

	actor.opts = opts
	if opts.children != nil {
		actor.opts.children = make([dynamic]SPAWN, 0, len(opts.children), actor.allocator)
		for child in opts.children {
			append(&actor.opts.children, child)
		}
	}
	if actor.opts.message_batch <= 0 {
		log.panicf(
			"Actor '%s' has message_batch=0 — use make_actor_config() instead of raw Actor_Config{{}}",
			name,
		)
	}

	if parent_pid > 0 {
		_, ok := get(&global_registry, parent_pid)

		if !ok do panic("provided parent pid does not exist")

		actor.parent = parent_pid
	}

	init_mpsc(&actor.system_mailbox)
	for i in 0 ..< MAILBOX_PRIORITY_COUNT {
		init_mpsc(&actor.mailbox[i])
	}

	pid, ok := add(&global_registry, rawptr(actor), name, behaviour.actor_type)
	if !ok {
		vmem.arena_destroy(&actor.arena)
		free(actor, actor_system_allocator)
		return 0, false
	}

	actor.pid = pid
	actor.state = .INIT
	actor.termination_reason = .NORMAL
	actor.child_restarts = make(map[PID]Restart_Info, actor.allocator)

	broadcast_actor_spawned(pid, name, behaviour.actor_type, parent_pid)

	if spawning_blocking_child {
		if current_actor_context != nil {
			log.panicf(
				"Cannot spawn blocking actor '%s' - blocking actors can only be spawned from main thread",
				name,
			)
		}
		actor.opts.blocking = true
		actor.opts.use_dedicated_os_thread = true
		spawning_blocking_child = false
		actor_loop(actor)
		return actor.pid, true
	}

	started: bool = false
	actor.started = &started

	if !opts.use_dedicated_os_thread && !opts.blocking && worker_pool.initialized {
		actor.local_buf = new([LOCAL_MAILBOX_SIZE]Message, actor.allocator)
		handle := new(Pooled_Actor_Handle, actor.allocator)
		handle.actor_ptr = actor
		handle.mailbox = &actor.mailbox
		handle.system_mailbox = &actor.system_mailbox
		handle.main_fn = proc(ptr: rawptr) {
			actor_loop(cast(^Actor(T))ptr)
		}

		coro_stack := uint(actor.opts.coro_stack_size)
		if coro_stack < coro.MIN_STACK_SIZE {
			coro_stack = coro.MIN_STACK_SIZE
		}
		desc := coro.desc_init(coro_entry, coro_stack, actor.allocator)
		desc.user_data = handle
		co, co_res := coro.create(&desc)
		if co_res != .Success {
			log.errorf("Failed to create coroutine for actor %s: %v", name, co_res)
			remove(&global_registry, pid)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
		handle.co = co
		actor.pool_handle = handle

		idx := -1
		if actor.opts.home_worker >= 0 {
			if actor.opts.home_worker >= worker_pool.worker_count {
				log.panicf(
					"Actor '%s' home_worker=%d exceeds worker_count=%d",
					name,
					actor.opts.home_worker,
					worker_pool.worker_count,
				)
			}
			idx = actor.opts.home_worker
		} else if affinity_pid, affinity_ok := resolve_actor_ref(actor.opts.affinity);
		   affinity_ok {
			affinity_actor := get(&global_registry, affinity_pid)
			if affinity_actor != nil {
				affinity_handle := (cast(^Actor(int))affinity_actor).pool_handle
				if affinity_handle != nil && affinity_handle.home_worker != nil {
					for i in 0 ..< worker_pool.worker_count {
						if &worker_pool.workers[i] == affinity_handle.home_worker {
							idx = i
							break
						}
					}
				}
			}
		}
		if idx < 0 {
			idx = sync.atomic_add(&worker_pool.next_worker, 1) % worker_pool.worker_count
			if current_worker != nil &&
			   &worker_pool.workers[idx] == current_worker &&
			   worker_pool.worker_count > 1 {
				idx = sync.atomic_add(&worker_pool.next_worker, 1) % worker_pool.worker_count
			}
		}
		handle.home_worker = &worker_pool.workers[idx]
		sync.atomic_store(&handle.in_ready_queue, true)
		mpsc_push(&handle.home_worker.ready_queue, rawptr(handle))
		sync.atomic_sema_post(&handle.home_worker.wake_sema)
	} else {
		actor.thread = threads_act.create_thread_with_stack_size(actor, proc(actor_ptr: rawptr) {
				actor_loop(cast(^Actor(T))actor_ptr)
			}, uint(actor.opts.stack_size_dedicated_os_thread))
		if actor.thread == nil {
			log.errorf("Failed to create thread for actor %s (PID %d)", name, pid)
			remove(&global_registry, pid)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
	}

	co := coro.running()
	if co != nil {
		for !sync.atomic_load_explicit(&started, .Acquire) {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		}
	} else {
		for !sync.atomic_load_explicit(&started, .Acquire) {
			intrinsics.cpu_relax()
		}
	}

	register_for_hot_reload(T, actor.pid, name)

	return actor.pid, true
}

spawn_child :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts := SYSTEM_CONFIG.actor_config,
) -> (
	PID,
	bool,
) {
	when ODIN_TEST {
		if pid, ok := ti.intercept_spawn_child(name, T); ok {
			return PID(pid), true
		}
	}

	self_pid := get_self_pid()
	if self_pid == 0 do panic("Call form inside actor context")
	return spawn(name, data, behaviour, opts, parent_pid = self_pid)
}

@(private)
actor_panic_handler :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	ctx := current_actor_context
	if ctx == nil {
		runtime.default_assertion_failure_proc(prefix, message, loc)
	}

	ctx.panic_location = loc
	ctx.panic_message_len = 0

	if len(prefix) > 0 {
		n := min(len(prefix), PANIC_MESSAGE_BUF_SIZE)
		mem.copy(&ctx.panic_message[0], raw_data(prefix), n)
		ctx.panic_message_len = n

		if ctx.panic_message_len < PANIC_MESSAGE_BUF_SIZE - 2 {
			ctx.panic_message[ctx.panic_message_len] = ':'
			ctx.panic_message[ctx.panic_message_len + 1] = ' '
			ctx.panic_message_len += 2
		}
	}

	if len(message) > 0 {
		remaining := PANIC_MESSAGE_BUF_SIZE - ctx.panic_message_len
		n := min(len(message), remaining)
		mem.copy(&ctx.panic_message[ctx.panic_message_len], raw_data(message), n)
		ctx.panic_message_len += n
	}

	libc.longjmp(&ctx.panic_jmp_buf, 1)
}

@(private)
actor_loop :: proc(actor: ^Actor($T)) {
	if actor.state != .INIT {
		log.panicf("Actor '%v' already started or terminated\n", actor.name)
	}

	if actor.opts.blocking {
		log.warn("blocking caller thread")
	}

	logger, actor_ctx := setup_actor_runtime(actor)
	context.allocator = actor.allocator
	context.logger = logger
	context.assertion_failure_proc = actor_panic_handler

	if actor.pool_handle != nil {
		actor.pool_handle.actor_ctx = actor_ctx
		actor.pool_handle.file_logger = current_actor_file_logger
	}

	if libc.setjmp(&actor_ctx.panic_jmp_buf) != 0 {
		// Landed here from longjmp — actor panicked
		panic_msg := string(actor_ctx.panic_message[:actor_ctx.panic_message_len])
		loc := actor_ctx.panic_location
		log.errorf(
			"ACTOR PANIC [%s (PID: %v)]: %s at %s:%d",
			actor.name,
			actor.pid,
			panic_msg,
			loc.file_path,
			loc.line,
		)

		actor.termination_reason = .ABNORMAL
		sync.atomic_store(&actor.state, .STOPPING)
		sync.atomic_store(&actor.state, .THREAD_STOPPED)

		if actor.started != nil {
			sync.atomic_store_explicit(actor.started, true, .Release)
		}

		notify_termination(actor)

		wi := sync.atomic_load_explicit(&actor.pool.write_index, .Relaxed)
		sync.atomic_store_explicit(&actor.pool.read_index, wi, .Release)

		cleanup_actor_context(actor_ctx)
		return
	}

	spawn_initial_children(actor)
	ctx := init_message_processing_context(actor, actor.allocator)

	call_init_handler(actor)
	sync.atomic_store(&actor.state, .RUNNING)
	if actor.started != nil {
		sync.atomic_store_explicit(actor.started, true, .Release)
	}

	run_message_loop(actor, &ctx)

	terminate_children(actor)
	call_terminate_handler(actor)

	flush_batch_free(&ctx.free_buffer)

	for {
		current := sync.atomic_load(&actor.state)
		if current != .STOPPING {
			log.errorf("Actor %v in unexpected state %v when thread stopping", actor.pid, current)
			break
		}
		if try_transition_state(&actor.state, .STOPPING, .THREAD_STOPPED) {
			break
		}
	}

	notify_termination(actor)

	wi := sync.atomic_load_explicit(&actor.pool.write_index, .Relaxed)
	sync.atomic_store_explicit(&actor.pool.read_index, wi, .Release)

	log.infof("Terminating - Reason: %s", actor.termination_reason)
	cleanup_actor_context(actor_ctx)
}

@(private)
setup_actor_runtime :: proc(actor: ^Actor($T)) -> (log.Logger, ^Actor_Context) {
	if actor.pid == 0 do log.panic("Actor started with PID 0!")

	context.allocator = actor.allocator
	init_pool(&actor.pool, actor.allocator, actor.opts.page_size)

	return setup_actor_context(actor.pid, actor.name, actor.opts.logging, actor.allocator)
}

@(private)
spawn_initial_children :: proc(actor: ^Actor($T)) {
	if actor.opts.children == nil do return

	log.info("Initializing children")
	actor.children = make([dynamic]PID, actor.allocator)

	for child_spawn, idx in actor.opts.children {
		pid, ok := child_spawn("", actor.pid)
		if !ok do log.panicf("Failed to start child in %s", actor.name)

		append(&actor.children, pid)

		child_node_id: Node_ID = 0
		if !is_local_pid(pid) {
			child_node_id = get_node_id(pid)
		}

		actor.child_restarts[pid] = Restart_Info {
			count         = 0,
			first_restart = time.now(),
			last_restart  = time.now(),
			child_index   = idx,
			node_id       = child_node_id,
		}

		if actor.behaviour.on_child_started != nil {
			actor.behaviour.on_child_started(actor.data, pid)
		}

		log.infof("Spawned child %s", get_actor_name(pid))
	}
}

@(private)
Message_Processing_Context :: struct {
	message_batch: []Message,
	batch_size:    int,
	header:        ^Type_Header,
	data:          any,
	is_node:       bool,
	free_buffer:   Batch_Free_Buffer,
}

@(private)
init_message_processing_context :: proc(
	actor: ^Actor($T),
	allocator: mem.Allocator,
) -> Message_Processing_Context {
	batch_size := actor.opts.message_batch
	return Message_Processing_Context {
		free_buffer = Batch_Free_Buffer {
			entries = make([]rawptr, FREE_BATCH_SIZE, allocator),
			sizes = make([]int, FREE_BATCH_SIZE, allocator),
			count = 0,
			pool = &actor.pool,
		},
		message_batch = make([]Message, batch_size, allocator),
		batch_size = batch_size,
		is_node = actor.pid == NODE.pid,
	}
}

@(private)
call_init_handler :: proc(actor: ^Actor($T)) {
	if actor.behaviour.init != nil do actor.behaviour.init(actor.data)
	if actor.pool_handle != nil {
		worker_idx := -1
		for i in 0 ..< worker_pool.worker_count {
			if &worker_pool.workers[i] == actor.pool_handle.home_worker {
				worker_idx = i
				break
			}
		}
		log.infof("Started on worker %d/%d", worker_idx, worker_pool.worker_count)
	} else {
		log.infof("Started on dedicated thread")
	}
}

@(private)
run_message_loop :: #force_inline proc(actor: ^Actor($T), ctx: ^Message_Processing_Context) {
	co := coro.running()
	rounds: u8 = 0
	for {
		if !process_system_mailbox(actor, ctx) do return
		if !process_user_mailboxes(actor, ctx) do return
		if sync.atomic_load(&actor.state) != .RUNNING do return
		if co == nil {
			wait_for_messages_if_idle(actor, ctx)
			continue
		}
		rounds += 1
		if rounds & 15 == 0 {
			coro.yield(co)
			continue
		}
		if mailbox_has_messages(actor) do continue
		if current_worker != nil &&
		   (current_worker.runnext != nil || mpsc_size(&current_worker.ready_queue) > 0) {
			coro.yield(co)
			continue
		}
		for _ in 0 ..< 64 {
			intrinsics.cpu_relax()
			if mailbox_has_messages(actor) do break
		}
		if !mailbox_has_messages(actor) {
			coro.yield(co)
		}
	}
}

@(private)
mailbox_has_messages :: #force_inline proc(actor: ^Actor($T)) -> bool {
	if actor.local_read != actor.local_write do return true
	for priority in 0 ..< MAILBOX_PRIORITY_COUNT {
		if mpsc_size(&actor.mailbox[priority]) > 0 do return true
	}
	return false
}

@(private)
process_system_mailbox :: #force_no_inline proc(
	actor: ^Actor($T),
	ctx: ^Message_Processing_Context,
) -> bool {
	if mpsc_size(&actor.system_mailbox) == 0 do return true
	batch_count := mpsc_pop_batch(&actor.system_mailbox, ctx.message_batch[0:ctx.batch_size])

	for i in 0 ..< batch_count {
		msg := &ctx.message_batch[i]
		reconstruct_msg(msg, &ctx.data, &ctx.header)

		if actor.pid == NODE.pid {
			actor.handle_message(actor.data, msg.from, ctx.data)
			if msg.content != nil && msg.content != INLINE_NEEDS_FIXUP do free_message(&actor.pool, msg.content)
			continue
		}

		switch v in ctx.data {
		case Terminate:
			actor.termination_reason = v.reason

			_, ok := sync.atomic_compare_exchange_strong(
				&actor.state,
				sync.atomic_load(&actor.state),
				.STOPPING,
			)
			if !ok {
				log.panicf(
					"[PANIC] Actor %v (%s) failed to transition from %v to STOPPING",
					actor.pid,
					actor.name,
					sync.atomic_load(&actor.state),
				)
			}

			if msg.content != nil && msg.content != INLINE_NEEDS_FIXUP do free_message(&actor.pool, msg.content)
			return false

		case Actor_Stopped:
			handle_child_termination(actor, v)
		case Remove_Child:
			handle_remove_child(actor, v)
		case Add_Child:
			handle_add_child(actor, v)
		case Set_Parent:
			handle_set_parent(actor, v)
		case Get_Stats:
			handle_get_stats_request(actor, v)
		case Rename_Actor:
			handle_rename_actor(actor, v)
		case Reload_Behaviour:
			swap_behaviour(actor, v.generation)
		}

		track_message_received(msg.from)
	}

	return true
}

@(private)
process_user_mailboxes :: #force_inline proc(
	actor: ^Actor($T),
	ctx: ^Message_Processing_Context,
) -> bool {
	// local worker first
	if actor.local_read != actor.local_write {
		batch_count := 0
		for batch_count < ctx.batch_size && actor.local_read != actor.local_write {
			ctx.message_batch[batch_count] =
				actor.local_buf[actor.local_read & (LOCAL_MAILBOX_SIZE - 1)]
			actor.local_read += 1
			batch_count += 1
		}

		is_running := sync.atomic_load(&actor.state) == .RUNNING
		for i in 0 ..< batch_count {
			msg := &ctx.message_batch[i]
			reconstruct_msg(msg, &ctx.data, &ctx.header)
			if !ctx.is_node || is_running {
				actor.handle_message(actor.data, msg.from, ctx.data)
				track_message_received(msg.from)
			}
			if msg.content != nil && msg.content != INLINE_NEEDS_FIXUP do message_free_deferred(&ctx.free_buffer, msg.content, ctx.header.size)
		}
		flush_batch_free(&ctx.free_buffer)
		if sync.atomic_load(&actor.state) != .RUNNING do return false
	}

	// thread safe
	for priority in 0 ..< MAILBOX_PRIORITY_COUNT {
		batch_count := mpsc_pop_batch(
			&actor.mailbox[priority],
			ctx.message_batch[0:ctx.batch_size],
		)

		if batch_count == 0 do continue

		is_running := sync.atomic_load(&actor.state) == .RUNNING

		for i in 0 ..< batch_count {
			msg := &ctx.message_batch[i]

			reconstruct_msg(msg, &ctx.data, &ctx.header)

			if !ctx.is_node || is_running {
				actor.handle_message(actor.data, msg.from, ctx.data)
				track_message_received(msg.from)
			}
			if msg.content != nil && msg.content != INLINE_NEEDS_FIXUP do message_free_deferred(&ctx.free_buffer, msg.content, ctx.header.size)
		}

		if batch_count > 0 do flush_batch_free(&ctx.free_buffer)

		track_max_mailbox_size(&actor.mailbox)

		if sync.atomic_load(&actor.state) != .RUNNING do return false
	}

	return true
}

@(private)
wait_for_messages_if_idle :: #force_inline proc(
	actor: ^Actor($T),
	ctx: ^Message_Processing_Context,
) {
	if mpsc_size(&actor.mailbox[0]) == 0 &&
	   mpsc_size(&actor.mailbox[1]) == 0 &&
	   mpsc_size(&actor.mailbox[2]) == 0 &&
	   mpsc_size(&actor.system_mailbox) == 0 {
		#partial switch actor.opts.spin_strategy {
		case .WAKE_SEMA:
			sync.atomic_sema_wait(&actor.wake_sema)
		case .CPU_RELAX:
			for _ in 0 ..< 10 {
				intrinsics.cpu_relax()
			}
		}
	}
}

@(private)
wake_actor :: #force_inline proc(actor: ^Actor(int)) {
	if actor.pool_handle != nil {
		wake_pooled_actor(actor.pool_handle)
	} else if actor.opts.spin_strategy == .WAKE_SEMA {
		sync.atomic_sema_post(&actor.wake_sema)
	}
}

@(private)
shutdown_children :: proc(actor: ^Actor($T)) {
	for child_pid in actor.children {
		if !terminate_actor(child_pid, .SHUTDOWN) {
			log.panicf("Failed to shutdown %d", child_pid)
		}
	}
}

@(private)
terminate_children :: proc(actor: ^Actor($T)) {
	if actor.children == nil || len(actor.children) == 0 {
		return
	}

	children_to_wait: [dynamic]PID
	defer delete(children_to_wait)

	for child_pid in actor.children {
		if terminate_actor(child_pid, .SHUTDOWN) {
			append(&children_to_wait, child_pid)
		}
	}

	wait_for_pids(children_to_wait[:])
}

@(private)
call_terminate_handler :: proc(actor: ^Actor($T)) {
	if actor.behaviour.terminate != nil do actor.behaviour.terminate(actor.data)
}

@(private)
notify_termination :: proc(actor: ^Actor($T)) {
	if current_actor_context != nil {
		for sub in current_actor_context.subscriptions {
			remove_subscriber(sub.actor_type, sub.pid)
		}

		for sub in current_actor_context.topic_subscriptions {
			topic_remove_subscriber(sub.topic, sub.pid)
		}

		if TIMER_PID != 0 && actor.pid != TIMER_PID && len(current_actor_context.timers) > 0 {
			if _, timer_active := get(&global_registry, TIMER_PID); timer_active {
				timer_actor, timer_ok := get_actor_from_pointer(
					get(&global_registry, TIMER_PID),
					true,
				)
				if timer_ok {
					send(TIMER_PID, Cancel_All_Timers{owner = actor.pid}, timer_actor)
				}
			}
		}
	}

	broadcast_actor_terminated(actor.pid, actor.name, actor.termination_reason)

	defer {
		if actor.parent != 0 {
			notify_parent_of_termination(actor)
		} else if NODE.pid != actor.pid {
			notify_node_of_termination(actor)
		}
	}

	if _, active := get(&global_registry, OBSERVER_PID); !active {
		return
	}

	if actor.pid == OBSERVER_PID && NODE.shutting_down {
		return
	}

	if current_actor_context == nil do return

	final_stats := Actor_Stats {
		pid                = actor.pid,
		name               = actor.name,
		messages_received  = current_actor_context.stats.messages_received,
		messages_sent      = current_actor_context.stats.messages_sent,
		start_time         = current_actor_context.stats.start_time,
		uptime             = time.since(current_actor_context.stats.start_time),
		last_update        = time.now(),
		max_mailbox_size   = current_actor_context.stats.max_mailbox_size,
		state              = sync.atomic_load(&actor.state),
		terminated         = true,
		termination_time   = time.now(),
		termination_reason = actor.termination_reason,
	}

	for _, i in actor.mailbox {
		final_stats.mailbox_sizes[i] = mpsc_size(&actor.mailbox[i])
	}
	final_stats.system_mailbox_size = mpsc_size(&actor.system_mailbox)

	saved_allocator := context.allocator
	context.allocator = actor_system_allocator
	defer context.allocator = saved_allocator

	final_stats.received_from = make(map[PID]u64)
	for pid in current_actor_context.stats.received_list {
		if count, exists := final_stats.received_from[pid]; exists {
			final_stats.received_from[pid] = count + 1
		} else {
			final_stats.received_from[pid] = 1
		}
	}

	final_stats.sent_to = make(map[PID]u64)
	for pid in current_actor_context.stats.sent_list {
		if count, exists := final_stats.sent_to[pid]; exists {
			final_stats.sent_to[pid] = count + 1
		} else {
			final_stats.sent_to[pid] = 1
		}
	}

	response := Stats_Response {
		stats = final_stats,
	}
	observer_actor, ok := get_actor_from_pointer(get(&global_registry, OBSERVER_PID), true)
	if ok {
		send(OBSERVER_PID, response, observer_actor)
	} else {
		delete(final_stats.sent_to)
		delete(final_stats.received_from)
	}
}

@(private)
notify_parent_of_termination :: proc(actor: ^Actor($T)) {
	if actor.termination_reason == .SHUTDOWN || actor.termination_reason == .KILLED {
		notify_node_of_termination(actor)
		return
	}

	if actor.parent == 0 {
		notify_node_of_termination(actor)
		return
	}

	if is_local_pid(actor.parent) {
		parent_actor, ok := get_actor_from_pointer(get(&global_registry, actor.parent), true)
		if ok {
			parent_state := sync.atomic_load(&parent_actor.state)
			if parent_state == .STOPPING ||
			   parent_state == .THREAD_STOPPED ||
			   parent_state == .TERMINATED {
				notify_node_of_termination(actor)
				return
			}
		}
	}

	msg := Actor_Stopped {
		child_pid   = actor.pid,
		reason      = actor.termination_reason,
		child_name  = actor.name,
		child_index = -1,
	}

	if err := send_message(actor.parent, msg); err != .OK {
		log.warnf(
			"Failed to notify parent %d about child %d termination: %v",
			actor.parent,
			actor.pid,
			err,
		)
	}
	notify_node_of_termination(actor)
}

@(private)
notify_node_of_termination :: proc(actor: ^Actor($T)) {
	msg := Actor_Stopped {
		child_pid  = actor.pid,
		reason     = actor.termination_reason,
		child_name = actor.name,
	}

	backoff := 1 * time.Microsecond
	max_backoff := 10 * time.Millisecond

	for _ in 0 ..< 100 {
		if send_node_msg(msg) do return

		co := coro.running()
		if co != nil {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		} else {
			time.sleep(backoff)
		}
		backoff = min(backoff * 2, max_backoff)
	}

	log.errorf("Failed to notify node of termination for actor %v after retries", actor.pid)
}

@(private)
fixup_inline_pointers :: proc(inline_data: ^[INLINE_MESSAGE_SIZE]byte, type_id: typeid) {
	info, ok := get_type_info(type_id)
	if !ok || info.flags == {} {
		return
	}

	struct_size := info.type_info.size
	offset := struct_size

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str := cast(^mem.Raw_Slice)(uintptr(inline_data) + field.offset)
			if str.len > 0 {
				str.data = rawptr(uintptr(inline_data) + uintptr(offset))
				offset += str.len
			}
		}
	}

	if .Has_Byte_Slices in info.flags && info.byte_slice_fields != nil {
		for field in info.byte_slice_fields {
			slice := cast(^mem.Raw_Slice)(uintptr(inline_data) + field.offset)
			if slice.len > 0 {
				slice.data = rawptr(uintptr(inline_data) + uintptr(offset))
				offset += slice.len
			}
		}
	}
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
		if header^.size > CACHE_LINE_SIZE {
			intrinsics.prefetch_read_data(data.data, 3)
		}
	}
}

send_self :: proc(content: $T) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_self(content); ok do return Send_Error(r)}

	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if ok {
		return send(actor.pid, content, actor)
	}

	return .ACTOR_NOT_FOUND
}

send_message :: proc(to: PID, content: $T) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message(u64(to), content); ok do return Send_Error(r)}

	if to == 0 {
		return .ACTOR_NOT_FOUND
	}

	when !intrinsics.type_is_variant_of(SYSTEM_MSG, T) {
		if sync.atomic_load_explicit(&NODE.shutting_down, .Relaxed) {
			return .SYSTEM_SHUTTING_DOWN
		}
	}

	if !is_local_pid(to) {
		return send_remote(to, content)
	}

	actor_ptr := get_relaxed(&global_registry, to)
	if actor_ptr == nil {
		return .ACTOR_NOT_FOUND
	}
	return send(to, content, cast(^Actor(int))actor_ptr)
}

// Send message by actor name. Supports both local and remote actors.
// For remote actors, use format: "actor_name@node_name"
// Examples:
//   send_message_name("my_actor", msg)                // Local actor
//   send_message_name("my_actor@remote_node", msg)    // Remote actor on "remote_node"
// For dynamic node/actor names, use send_to(actor, node, msg) instead.
// For performance with known PIDs, use send_message(to: PID, content) instead.
send_message_name :: proc(to: string, content: $T) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_name(to, content); ok do return Send_Error(r)}

	for c, i in to {
		if c == '@' {
			actor_name := to[:i]
			node_name := to[i + 1:]

			if _, exists := get_node_by_name(node_name); exists {
				return send_remote_by_name(node_name, actor_name, content)
			}

			return .NODE_NOT_FOUND
		}
	}

	local_pid, found := get_actor_pid(to)
	if !found {
		return .ACTOR_NOT_FOUND
	}
	return send_message(local_pid, content)
}

// Send by name with a local PID cache. Resolves name→PID on first call, then
// reuses the cached PID. If the target actor dies and restarts (new PID, same name),
// the cache auto-refreshes on the next ACTOR_NOT_FOUND error.
// Local actors only — does not support "actor@node" remote format.
// The cache is a simple linear scan — intended for a small number of target names
// per message type. If you're sending to many distinct names, use get_actor_pid + send_message.
send_by_name_cached :: proc(to: string, content: $T) -> Send_Error {
	NAME_CACHE_MAX :: 16

	Name_PID_Entry :: struct {
		name: string,
		pid:  PID,
	}

	@(static) cache: [NAME_CACHE_MAX]Name_PID_Entry
	@(static) cache_count: int

	pid: PID = 0
	cache_idx := -1

	for i in 0 ..< cache_count {
		if cache[i].name == to {
			pid = cache[i].pid
			cache_idx = i
			break
		}
	}

	if pid == 0 {
		resolved, found := get_actor_pid(to)
		if !found do return .ACTOR_NOT_FOUND
		pid = resolved

		if cache_count < NAME_CACHE_MAX {
			cache[cache_count] = {
				name = to,
				pid  = pid,
			}
			cache_idx = cache_count
			cache_count += 1
		}
	}

	err := send_message(pid, content)

	if err == .ACTOR_NOT_FOUND {
		resolved, found := get_actor_pid(to)
		if !found do return .ACTOR_NOT_FOUND
		pid = resolved

		if cache_idx >= 0 {
			cache[cache_idx].pid = pid
		}

		err = send_message(pid, content)
	}

	return err
}

// Send message to a remote actor with dynamic node and actor names.
send_to :: proc(actor_name: string, node_name: string, content: $T) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_to(actor_name, node_name, content); ok do return Send_Error(r)}

	if _, exists := get_node_by_name(node_name); exists {
		return send_remote_by_name(node_name, actor_name, content)
	}
	return .NODE_NOT_FOUND
}

send_message_to_children :: proc(content: $T) -> bool {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_to_children(content); ok do return r}

	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return false
	}
	for child_pid in actor.children {
		child_actor, child_ok := get_actor_from_pointer(get(&global_registry, child_pid))
		if !child_ok {
			return false
		}

		if send(child_pid, content, child_actor) != .OK {
			return false
		}
	}

	return true
}

send_message_to_parent :: proc(content: $T) -> bool {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_to_parent(content); ok do return r}

	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok {
		return false
	}

	parent_actor, got_parent_pid := get_actor_from_pointer(get(&global_registry, actor.parent))
	if !got_parent_pid {
		return false
	}

	return send(actor.parent, content, parent_actor) == .OK
}

send_message_high :: proc(to: PID, content: $T) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_high(u64(to), content); ok do return Send_Error(r)}

	if current_actor_context != nil do current_actor_context.send_priority = .HIGH
	err := send_message(to, content)
	if current_actor_context != nil do current_actor_context.send_priority = .NORMAL
	return err
}

send_message_low :: proc(to: PID, content: $T) -> Send_Error {
	when ODIN_TEST {if r, ok := ti.intercept_send_message_low(u64(to), content); ok do return Send_Error(r)}

	if current_actor_context != nil do current_actor_context.send_priority = .LOW
	err := send_message(to, content)
	if current_actor_context != nil do current_actor_context.send_priority = .NORMAL
	return err
}

set_send_priority :: proc(p: Message_Priority) {
	if current_actor_context != nil do current_actor_context.send_priority = p
}

reset_send_priority :: proc() {
	if current_actor_context != nil do current_actor_context.send_priority = .NORMAL
}

@(private)
get_send_priority :: #force_inline proc() -> int {
	if current_actor_context != nil {
		return int(current_actor_context.send_priority)
	}
	return 1
}

@(private)
priority_to_flags :: #force_inline proc(p: Message_Priority) -> Network_Message_Flags {
	switch p {
	case .HIGH:
		return {.PRIORITY_HIGH}
	case .LOW:
		return {.PRIORITY_LOW}
	case .NORMAL:
		return {}
	}
	return {}
}

@(private)
flags_to_priority :: #force_inline proc(flags: Network_Message_Flags) -> int {
	if .PRIORITY_HIGH in flags do return 0
	if .PRIORITY_LOW in flags do return 2
	return 1
}

@(private)
yield_and_retry_local :: #force_no_inline proc(actor: ^Actor(int), msg: Message, to: PID) -> bool {
	co := coro.running()
	if co == nil do return false
	handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
	handle.wants_reschedule = true
	coro.yield(co)
	if actor.local_write - actor.local_read < LOCAL_MAILBOX_SIZE {
		actor.local_buf[actor.local_write & (LOCAL_MAILBOX_SIZE - 1)] = msg
		actor.local_write += 1
		if !sync.atomic_load_explicit(&actor.pool_handle.in_ready_queue, .Relaxed) {
			wake_actor(actor)
		}
		handle_set_message_stats(msg, to)
		return true
	}
	return false
}

@(private)
push_to_mailbox :: #force_inline proc(
	actor: ^Actor(int),
	msg: Message,
	to: PID,
	priority: int = 1,
) -> Send_Error {
	// Local if on same worker
	if current_worker != nil &&
	   actor.pool_handle != nil &&
	   actor.pool_handle.home_worker == current_worker {
		if actor.local_write - actor.local_read < LOCAL_MAILBOX_SIZE {
			actor.local_buf[actor.local_write & (LOCAL_MAILBOX_SIZE - 1)] = msg
			actor.local_write += 1
			if !sync.atomic_load_explicit(&actor.pool_handle.in_ready_queue, .Relaxed) {
				wake_actor(actor)
			}
			handle_set_message_stats(msg, to)
			return .OK
		}

		if yield_and_retry_local(actor, msg, to) {
			return .OK
		}
	}

	if mpsc_try_push(&actor.mailbox[priority], msg) {
		wake_actor(actor)
		handle_set_message_stats(msg, to)
		return .OK
	}

	co := coro.running()
	retries := MAX_SEND_RETRIES
	for attempt := 0; attempt < retries; attempt += 1 {
		for _, i in actor.mailbox {
			if mpsc_try_push(&actor.mailbox[i], msg) {
				wake_actor(actor)
				handle_set_message_stats(msg, to)
				return .OK
			}
		}
		if sync.atomic_load(&NODE.shutting_down) {
			return .SYSTEM_SHUTTING_DOWN
		}
		if co != nil {
			if attempt >= retries - 1 {
				attempt = 0
			}
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		} else {
			time.sleep(SEND_RETRY_DELAY)
		}
	}

	log.errorf("mailbox full - failed to send message to %s", get_actor_name(to))
	return .MAILBOX_FULL
}

@(private)
send :: #force_inline proc(to: PID, content: $T, actor: ^Actor(int)) -> Send_Error {
	when !intrinsics.type_is_variant_of(SYSTEM_MSG, T) {
		if sync.atomic_load_explicit(&NODE.shutting_down, .Relaxed) {
			return .SYSTEM_SHUTTING_DOWN
		}
	}

	current_state := sync.atomic_load(&actor.state)

	when intrinsics.type_is_variant_of(SYSTEM_MSG, T) {
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
	info := get_validated_message_info(T)

	if current_state == .STOPPING {
		when intrinsics.type_is_variant_of(SYSTEM_MSG, T) {
			if create_message(&msg, &actor.pool, content, info) {
				return .OK
			}
		}
		return .ACTOR_NOT_FOUND
	}

	if !create_message(&msg, &actor.pool, content, info) {
		log.errorf("pool full - failed to allocate message for %s", get_actor_name(to))
		return .POOL_FULL
	}

	when intrinsics.type_is_variant_of(SYSTEM_MSG, T) {
		if !mpsc_push(&actor.system_mailbox, msg) {
			log.panicf("Couldn't send system message to %v", to)
		}
		wake_actor(actor)
		handle_set_message_stats(msg, to)
		return .OK
	}

	result := push_to_mailbox(actor, msg, to, get_send_priority())
	if result != .OK {
		free_message(&actor.pool, msg.content)
	}

	return result
}

terminate_actor :: proc(to: PID, reason: Termination_Reason = .SHUTDOWN) -> bool {
	when ODIN_TEST {if ti.intercept_terminate_actor(u64(to), ti.Termination_Reason(reason)) do return true}

	// TODO: shutdown remote actor here
	if !is_local_pid(to) {
		remove_remote(&global_registry, to)
		return true
	}

	is_system_op := reason == .SHUTDOWN
	actor_ptr := get(&global_registry, to)

	if actor_ptr == nil {
		return true
	}

	state_ptr := cast(^Actor_State)(uintptr(actor_ptr) + offset_of(Actor(int), state))
	state := sync.atomic_load(state_ptr)
	if state == .STOPPING || state == .THREAD_STOPPED || state == .TERMINATED {
		return true
	}

	actor, ok := get_actor_from_pointer(actor_ptr, is_system_op)
	if !ok {
		return false
	}
	return send(to, Terminate{reason = reason}, actor) == .OK
}

// Dynamically add a child to a supervisor
add_child :: proc(parent: PID, child_spawn: SPAWN) -> (PID, bool) {
	if child_spawn == nil {
		log.panic("need spawn func")
	}

	parent_actor, ok := get_actor_from_pointer(get(&global_registry, parent))
	if !ok {
		return 0, false
	}

	// Send system message to supervisor to handle child addition
	msg := Add_Child {
		spawn_func   = child_spawn,
		existing_pid = 0,
	}
	err := send(parent, msg, parent_actor)
	if err != .OK {
		log.errorf("Failed to send Add_Child message: %v", err)
		return 0, false
	}

	return 0, true
}

// Dynamically adopt an existing actor as a child of a supervisor
add_child_existing :: proc(
	parent: PID,
	existing_child: PID,
	child_spawn: SPAWN,
	spawn_func_name_hash: u64 = 0,
) -> (
	PID,
	bool,
) {
	parent_actor, ok := get_actor_from_pointer(get(&global_registry, parent))
	if !ok {
		return 0, false
	}

	msg := Add_Child {
		spawn_func           = child_spawn,
		existing_pid         = existing_child,
		spawn_func_name_hash = spawn_func_name_hash,
	}
	err := send(parent, msg, parent_actor)
	if err != .OK {
		log.errorf("Failed to send Add_Child message for existing actor: %v", err)
		return 0, false
	}

	return existing_child, true
}

// Remove a child from a supervisor
// remote??
remove_child :: proc(parent: PID, child: PID) -> bool {
	parent_actor, ok := get_actor_from_pointer(get(&global_registry, parent))
	if !ok {
		return false
	}

	msg := Remove_Child {
		child_pid = child,
	}

	return send(parent, msg, parent_actor) == .OK
}

// Get list of children for an actor
// remote??
get_children :: proc(parent: PID) -> []PID {
	parent_actor, ok := get_actor_from_pointer(get(&global_registry, parent))
	if !ok {
		return nil
	}

	// Return a copy to avoid external modifications
	result := make([]PID, len(parent_actor.children))
	copy(result, parent_actor.children[:])
	return result
}

get_parent_pid :: proc() -> PID {
	actor, ok := get_actor_from_pointer(get(&global_registry, get_self_pid()))
	if !ok do return 0
	return actor.parent
}

// remote??
get_actor_name :: #force_inline proc(pid: PID) -> string {
	actor_ptr, active := get(&global_registry, pid)
	if !active || actor_ptr == nil do return "<unknown>"

	name_offset := offset_of(Actor(int), name)
	name_ptr := cast(^string)(uintptr(actor_ptr) + name_offset)
	return name_ptr^
}

get_actor_pid :: #force_inline proc(name: string) -> (PID, bool) {
	when ODIN_TEST {if pid, found, ok := ti.intercept_get_actor_pid(name); ok do return PID(pid), found}

	return get_by_name(&global_registry, name)
}

get_actor_parent :: #force_inline proc(pid: PID) -> PID {
	actor_ptr, active := get(&global_registry, pid)
	if !active || actor_ptr == nil do return 0
	parent_offset := offset_of(Actor(int), parent)
	parent_ptr := cast(^PID)(uintptr(actor_ptr) + parent_offset)
	return parent_ptr^
}

get_self_name :: #force_inline proc() -> string {
	when ODIN_TEST {if name, ok := ti.intercept_get_self_name(); ok do return name}

	if current_actor_context != nil do return current_actor_context.name
	return ""
}

get_self_pid :: #force_inline proc() -> PID {
	when ODIN_TEST {if pid, ok := ti.intercept_get_self_pid(); ok do return PID(pid)}

	if current_actor_context != nil do return current_actor_context.pid
	return pack_pid(Handle{idx = 0, gen = 0, actor_type = 0}, current_node_id)
}

self_terminate :: proc(reason: Termination_Reason = .NORMAL) -> bool {
	when ODIN_TEST {if ti.intercept_self_terminate(ti.Termination_Reason(reason)) do return true}

	pid := get_self_pid()
	if pid == 0 do return false
	return terminate_actor(pid, reason)
}

rename_actor :: proc(pid: PID, new_name: string) -> bool {
	when ODIN_TEST {if ti.intercept_rename_actor(u64(pid), new_name) do return true}

	actor, ok := get_actor_from_pointer(get(&global_registry, pid), true)
	if !ok do return false

	msg := Rename_Actor {
		new_name = new_name,
	}

	return send(pid, msg, actor) == .OK
}

self_rename :: proc(new_name: string) -> bool {
	when ODIN_TEST {if ti.intercept_self_rename(new_name) do return true}

	pid := get_self_pid()
	if pid == 0 {
		return false
	}
	return rename_actor(pid, new_name)
}

yield :: proc() {
	co := coro.running()
	if co == nil {
		log.panic("yield called outside of pooled actor context")
	}
	handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
	handle.wants_reschedule = true
	coro.yield(co)
}

@(private)
calculate_variable_data_size :: #force_inline proc(
	value_ptr: rawptr,
	info: Message_Type_Info,
) -> int {
	total := 0

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(value_ptr) + field.offset)
			total += len(str_ptr^)
		}
	}

	if .Has_Byte_Slices in info.flags && info.byte_slice_fields != nil {
		for field in info.byte_slice_fields {
			slice_ptr := cast(^[]byte)(uintptr(value_ptr) + field.offset)
			total += len(slice_ptr^)
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(value_ptr, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(value_ptr) + field.offset)
				total += len(str_ptr^)
			}
			for field in variant.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(value_ptr) + field.offset)
				total += len(slice_ptr^)
			}
		}
	}

	return total
}

@(private)
copy_variable_data :: #force_inline proc(
	dest_base: rawptr,
	struct_ptr: rawptr,
	src_value_ptr: rawptr,
	info: Message_Type_Info,
	start_offset: int,
) {
	offset := start_offset

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			src_str := cast(^string)(uintptr(src_value_ptr) + field.offset)
			dst_str := cast(^string)(uintptr(struct_ptr) + field.offset)

			if len(src_str^) > 0 {
				dest := rawptr(uintptr(dest_base) + uintptr(offset))
				intrinsics.mem_copy_non_overlapping(dest, raw_data(src_str^), len(src_str^))
				dst_str^ = transmute(string)mem.Raw_Slice{data = dest, len = len(src_str^)}
				offset += len(src_str^)
			} else {
				dst_str^ = ""
			}
		}
	}

	if .Has_Byte_Slices in info.flags && info.byte_slice_fields != nil {
		for field in info.byte_slice_fields {
			src_slice := cast(^[]byte)(uintptr(src_value_ptr) + field.offset)
			dst_slice := cast(^[]byte)(uintptr(struct_ptr) + field.offset)

			if len(src_slice^) > 0 {
				dest := rawptr(uintptr(dest_base) + uintptr(offset))
				intrinsics.mem_copy_non_overlapping(dest, raw_data(src_slice^), len(src_slice^))
				dst_slice^ = transmute([]byte)mem.Raw_Slice{data = dest, len = len(src_slice^)}
				offset += len(src_slice^)
			} else {
				dst_slice^ = nil
			}
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(src_value_ptr, uf)
			if !ok do continue
			for field in variant.string_fields {
				src_str := cast(^string)(uintptr(src_value_ptr) + field.offset)
				dst_str := cast(^string)(uintptr(struct_ptr) + field.offset)

				if len(src_str^) > 0 {
					dest := rawptr(uintptr(dest_base) + uintptr(offset))
					intrinsics.mem_copy_non_overlapping(dest, raw_data(src_str^), len(src_str^))
					dst_str^ = transmute(string)mem.Raw_Slice{data = dest, len = len(src_str^)}
					offset += len(src_str^)
				} else {
					dst_str^ = ""
				}
			}
			for field in variant.byte_slice_fields {
				src_slice := cast(^[]byte)(uintptr(src_value_ptr) + field.offset)
				dst_slice := cast(^[]byte)(uintptr(struct_ptr) + field.offset)

				if len(src_slice^) > 0 {
					dest := rawptr(uintptr(dest_base) + uintptr(offset))
					intrinsics.mem_copy_non_overlapping(
						dest,
						raw_data(src_slice^),
						len(src_slice^),
					)
					dst_slice^ = transmute([]byte)mem.Raw_Slice{data = dest, len = len(src_slice^)}
					offset += len(src_slice^)
				} else {
					dst_slice^ = nil
				}
			}
		}
	}
}

@(private)
create_message :: #force_inline proc(
	msg: ^Message,
	pool: ^Pool,
	value: $T,
	info: Message_Type_Info,
) -> bool {
	if info.flags == {} {
		when size_of(T) <= INLINE_MESSAGE_SIZE {
			msg.inline_type = T
			msg.content = nil
			(cast(^T)&msg.inline_data)^ = value
		} else {
			aligned_size := mem.align_forward_int(TYPE_HEADER_SIZE + size_of(T), CACHE_LINE_SIZE)

			buffer := message_alloc(pool, aligned_size)
			if buffer == nil {
				return false
			}

			header := cast(^Type_Header)buffer
			header.type_id = T
			header.size = aligned_size

			data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
			when size_of(T) > 64 {
				val := value
				intrinsics.mem_copy_non_overlapping(data_ptr, &val, size_of(T))
			} else {
				(cast(^T)data_ptr)^ = value
			}

			msg.content = buffer
			msg.inline_type = nil
		}
		return true
	}

	val := value
	variable_size := calculate_variable_data_size(&val, info)
	total_message_size := size_of(T) + variable_size

	if total_message_size <= INLINE_MESSAGE_SIZE {
		msg.inline_type = T
		msg.content = INLINE_NEEDS_FIXUP
		intrinsics.mem_copy_non_overlapping(&msg.inline_data[0], &val, size_of(T))
		copy_variable_data(&msg.inline_data[0], &msg.inline_data[0], &val, info, size_of(T))
	} else {
		aligned_size := mem.align_forward_int(
			TYPE_HEADER_SIZE + size_of(T) + variable_size,
			CACHE_LINE_SIZE,
		)

		buffer := message_alloc(pool, aligned_size)
		if buffer == nil {
			return false
		}

		header := cast(^Type_Header)buffer
		header.type_id = T
		header.size = aligned_size

		data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
		intrinsics.mem_copy_non_overlapping(data_ptr, &val, size_of(T))
		copy_variable_data(buffer, data_ptr, &val, info, TYPE_HEADER_SIZE + size_of(T))

		msg.content = buffer
		msg.inline_type = nil
	}

	return true
}

@(private)
create_message_from_payload :: #force_inline proc(
	msg: ^Message,
	pool: ^Pool,
	payload: []byte,
	info: Message_Type_Info,
) -> bool {
	struct_size := info.size

	if info.flags == {} {
		if struct_size <= INLINE_MESSAGE_SIZE {
			msg.inline_type = info.type_id
			msg.content = nil
			intrinsics.mem_copy_non_overlapping(
				&msg.inline_data[0],
				raw_data(payload),
				struct_size,
			)
			return true
		}

		aligned_size := mem.align_forward_int(TYPE_HEADER_SIZE + struct_size, CACHE_LINE_SIZE)
		buffer := message_alloc(pool, aligned_size)
		if buffer == nil {
			return false
		}

		header := cast(^Type_Header)buffer
		header.type_id = info.type_id
		header.size = aligned_size
		intrinsics.mem_copy_non_overlapping(
			rawptr(uintptr(buffer) + TYPE_HEADER_SIZE),
			raw_data(payload),
			struct_size,
		)

		msg.content = buffer
		msg.inline_type = nil
		return true
	}

	// SLOW PATH
	variable_size := len(payload) - struct_size
	total_message_size := struct_size + variable_size

	if total_message_size <= INLINE_MESSAGE_SIZE {
		msg.inline_type = info.type_id
		msg.content = INLINE_NEEDS_FIXUP
		intrinsics.mem_copy_non_overlapping(&msg.inline_data[0], raw_data(payload), struct_size)
		copy_variable_data_from_payload(
			&msg.inline_data[0],
			&msg.inline_data[0],
			payload,
			info,
			struct_size,
		)
		return true
	}

	aligned_size := mem.align_forward_int(TYPE_HEADER_SIZE + total_message_size, CACHE_LINE_SIZE)
	buffer := message_alloc(pool, aligned_size)
	if buffer == nil {
		return false
	}

	header := cast(^Type_Header)buffer
	header.type_id = info.type_id
	header.size = aligned_size

	data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
	intrinsics.mem_copy_non_overlapping(data_ptr, raw_data(payload), struct_size)
	copy_variable_data_from_payload(
		buffer,
		data_ptr,
		payload,
		info,
		TYPE_HEADER_SIZE + struct_size,
	)

	msg.content = buffer
	msg.inline_type = nil
	return true
}

@(private)
copy_variable_data_from_payload :: #force_inline proc(
	dest_base: rawptr,
	struct_ptr: rawptr,
	payload: []byte,
	info: Message_Type_Info,
	dest_start_offset: int,
) {
	dest_offset := dest_start_offset
	payload_offset := info.size

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			dst_str := cast(^string)(uintptr(struct_ptr) + field.offset)
			str_len := len(dst_str^)

			if str_len > 0 {
				dest := rawptr(uintptr(dest_base) + uintptr(dest_offset))
				intrinsics.mem_copy_non_overlapping(
					dest,
					raw_data(payload[payload_offset:]),
					str_len,
				)
				dst_str^ = transmute(string)mem.Raw_Slice{data = dest, len = str_len}
				dest_offset += str_len
				payload_offset += str_len
			} else {
				dst_str^ = ""
			}
		}
	}

	if .Has_Byte_Slices in info.flags && info.byte_slice_fields != nil {
		for field in info.byte_slice_fields {
			dst_slice := cast(^[]byte)(uintptr(struct_ptr) + field.offset)
			slice_len := len(dst_slice^)

			if slice_len > 0 {
				dest := rawptr(uintptr(dest_base) + uintptr(dest_offset))
				intrinsics.mem_copy_non_overlapping(
					dest,
					raw_data(payload[payload_offset:]),
					slice_len,
				)
				dst_slice^ = transmute([]byte)mem.Raw_Slice{data = dest, len = slice_len}
				dest_offset += slice_len
				payload_offset += slice_len
			} else {
				dst_slice^ = nil
			}
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(struct_ptr, uf)
			if !ok do continue
			for field in variant.string_fields {
				dst_str := cast(^string)(uintptr(struct_ptr) + field.offset)
				str_len := len(dst_str^)

				if str_len > 0 {
					dest := rawptr(uintptr(dest_base) + uintptr(dest_offset))
					intrinsics.mem_copy_non_overlapping(
						dest,
						raw_data(payload[payload_offset:]),
						str_len,
					)
					dst_str^ = transmute(string)mem.Raw_Slice{data = dest, len = str_len}
					dest_offset += str_len
					payload_offset += str_len
				} else {
					dst_str^ = ""
				}
			}
			for field in variant.byte_slice_fields {
				dst_slice := cast(^[]byte)(uintptr(struct_ptr) + field.offset)
				slice_len := len(dst_slice^)

				if slice_len > 0 {
					dest := rawptr(uintptr(dest_base) + uintptr(dest_offset))
					intrinsics.mem_copy_non_overlapping(
						dest,
						raw_data(payload[payload_offset:]),
						slice_len,
					)
					dst_slice^ = transmute([]byte)mem.Raw_Slice{data = dest, len = slice_len}
					dest_offset += slice_len
					payload_offset += slice_len
				} else {
					dst_slice^ = nil
				}
			}
		}
	}
}

// Send message directly from network payload to actor's mailbox
// Bypasses the typed intermediate copy in the normal send path
send_from_payload :: #force_inline proc(
	to_pid: PID,
	from_pid: PID,
	payload: []byte,
	info: Message_Type_Info,
	priority: int = 1,
) -> Send_Error {
	actor, ok := get_actor_from_pointer(get(&global_registry, to_pid))
	if !ok {
		return .ACTOR_NOT_FOUND
	}

	current_state := sync.atomic_load(&actor.state)
	if current_state != .RUNNING && current_state != .IDLE {
		return .ACTOR_NOT_FOUND
	}

	msg: Message
	msg.from = from_pid

	if !create_message_from_payload(&msg, &actor.pool, payload, info) {
		log.errorf("pool full - failed to allocate message for %s", get_actor_name(to_pid))
		return .POOL_FULL
	}

	result := push_to_mailbox(actor, msg, to_pid, priority)
	if result != .OK {
		free_message(&actor.pool, msg.content)
	}

	return result
}

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
		if actual_index == -1 {
			return
		}
	}

	ordered_remove(&actor.children, actual_index)

	delete_key(&actor.child_restarts, child_pid)

	for j := actual_index; j < len(actor.children); j += 1 {
		remaining_pid := actor.children[j]
		if info, has := &actor.child_restarts[remaining_pid]; has {
			info.child_index = j
		}
	}
}

@(private)
handle_remove_child :: proc(actor: ^Actor($T), msg: Remove_Child) {
	for child_pid, idx in actor.children {
		if child_pid == msg.child_pid {
			ordered_remove(&actor.children, idx)

			delete_key(&actor.child_restarts, child_pid)

			for j := idx; j < len(actor.children); j += 1 {
				remaining_pid := actor.children[j]
				if info, has := &actor.child_restarts[remaining_pid]; has {
					info.child_index = j
				}
			}

			child_actor, ok := get_actor_from_pointer(get(&global_registry, child_pid))
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

		child_actor, child_ok := get_actor_from_pointer(get(&global_registry, child_pid))
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

		ok = true
	} else {
		child_pid, ok = msg.spawn_func("", actor.pid)
		if !ok {
			log.errorf("Failed to spawn child for parent %d", actor.pid)
			return
		}
	}

	append(&actor.children, child_pid)

	if actor.opts.children == nil {
		actor.opts.children = make([dynamic]SPAWN)
	}

	append(&actor.opts.children, msg.spawn_func)

	child_node_id: Node_ID = 0
	if !is_local_pid(child_pid) {
		child_node_id = get_node_id(child_pid)
	}

	child_index := len(actor.children) - 1

	actor.child_restarts[child_pid] = Restart_Info {
		count                = 0,
		first_restart        = time.now(),
		last_restart         = time.now(),
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
		old_parent_actor, ok := get_actor_from_pointer(get(&global_registry, old_parent))
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
	new_parent_actor, ok := get_actor_from_pointer(get(&global_registry, msg.new_parent))
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
	if child_index == -1 {
		child_index = restart_info.child_index
	}

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

	now := time.now()
	if time.diff(restart_info.first_restart, now) > actor.opts.restart_window {
		restart_info.count = 0
		restart_info.first_restart = now
	}

	restart_info.count += 1
	restart_info.last_restart = now

	if restart_info.count > actor.opts.max_restarts {
		log.errorf(
			"Child %s exceeded max restarts (%d) in window",
			msg.child_name,
			actor.opts.max_restarts,
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
				if terminate_actor(child_pid, .KILLED) {
					append(&pids_to_wait, child_pid)
				}
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

	if restart_info.node_id == 0 || restart_info.node_id == current_node_id {
		// Local child - use existing SPAWN proc
		new_pid, ok = actor.opts.children[child_index]("", actor.pid)
	} else {
		// Remote child - use spawn_remote with behaviour registry
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

		new_pid, ok = spawn_remote(spawn_func_name, get_actor_name(old_pid), node_name, actor.pid)
	}

	if !ok {
		log.errorf("Failed to restart child at index %d", child_index)
		return
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

@(private)
track_message_received :: proc(from: PID) {
	if SYSTEM_CONFIG.enable_observer {
		current_actor_context.stats.messages_received += 1
		if from != 0 do append(&current_actor_context.stats.received_list, from)
	}
}

@(private)
track_max_mailbox_size :: proc(mailbox: ^ACTOR_MAILBOX) {
	if SYSTEM_CONFIG.enable_observer {
		current_size := 0
		for priority in 0 ..< MAILBOX_PRIORITY_COUNT {
			current_size += mpsc_size(&mailbox[priority])
		}

		if current_size > current_actor_context.stats.max_mailbox_size {
			current_actor_context.stats.max_mailbox_size = current_size
		}
	}
}

// TODO: slow for hot path
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
		stats.uptime = time.since(current_actor_context.stats.start_time)
		stats.last_update = time.now()
		stats.max_mailbox_size = current_actor_context.stats.max_mailbox_size

		for _, j in actor.mailbox {
			stats.mailbox_sizes[j] = mpsc_size(&actor.mailbox[j])
		}
		stats.system_mailbox_size = mpsc_size(&actor.system_mailbox)

		saved_allocator := context.allocator
		context.allocator = actor_system_allocator
		defer context.allocator = saved_allocator

		stats.received_from = make(map[PID]u64)
		for pid in current_actor_context.stats.received_list {
			if count, exists := stats.received_from[pid]; exists {
				stats.received_from[pid] = count + 1
			} else {
				stats.received_from[pid] = 1
			}
		}

		stats.sent_to = make(map[PID]u64)
		for pid in current_actor_context.stats.sent_list {
			if count, exists := stats.sent_to[pid]; exists {
				stats.sent_to[pid] = count + 1
			} else {
				stats.sent_to[pid] = 1
			}
		}

		clear_dynamic_array(&current_actor_context.stats.received_list)
		clear_dynamic_array(&current_actor_context.stats.sent_list)
	}

	return stats
}

@(private)
handle_set_message_stats :: proc(msg: Message, to: PID) {
	if SYSTEM_CONFIG.enable_observer {
		if current_actor_context != nil && current_actor_context.pid == msg.from {
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

	requester_actor, ok := get_actor_from_pointer(get(&global_registry, request.requester))
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

	pid_map_rename(&global_registry, actor.pid, msg.new_name)

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

// cleanup_actor_pool is no longer needed - arena handles all pool memory
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
