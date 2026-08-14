package actod

import "../pkgs/coro"
import "base:intrinsics"
import "core:c/libc"
import "core:log"
import "core:mem"
import "base:runtime"
import "core:sync"

@(private)
actor_panic_handler :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	ctx := current_actor_context
	if ctx == nil do runtime.default_assertion_failure_proc(prefix, message, loc)

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

	coro.asan_before_longjmp()
	libc.longjmp(&ctx.panic_jmp_buf, 1)
}

@(private)
actor_loop :: proc(actor: ^Actor($T)) {
	if actor.state != .INIT {
		panic_at(actor.spawn_loc, "Actor '%v' already started or terminated\n", actor.name)
	}

	if actor.opts.blocking do log.warn("blocking caller thread")

	logger, actor_ctx := setup_actor_runtime(actor)
	context.allocator = actor.allocator
	context.logger = logger
	context.assertion_failure_proc = actor_panic_handler

	if actor.pool_handle != nil {
		actor.pool_handle.actor_ctx = actor_ctx
		actor.pool_handle.file_logger = current_actor_file_logger
		actor.pool_handle.logger = logger
	}

	if libc.setjmp(&actor_ctx.panic_jmp_buf) != 0 {
		// Landed here from longjmp, actor panicked
		actor_panic_teardown(actor, actor_ctx)
		return
	}

	spawn_initial_children(actor)

	ctx := new(Message_Processing_Context, actor.allocator)
	ctx^ = message_processing_context_init(actor, actor.allocator)
	actor.msg_ctx = ctx

	call_init_handler(actor)
	sync.atomic_store(&actor.state, .RUNNING)
	if actor.started != nil do sync.atomic_store_explicit(actor.started, true, .Release)

	actor_run_phase(actor, actor_ctx, ctx)
}

@(private)
actor_resume :: proc(actor: ^Actor($T)) {
	actor_ctx := current_actor_context
	if actor_ctx == nil do return

	context.allocator = actor.allocator
	context.logger = actor.pool_handle.logger
	context.assertion_failure_proc = actor_panic_handler

	if libc.setjmp(&actor_ctx.panic_jmp_buf) != 0 {
		actor_panic_teardown(actor, actor_ctx)
		return
	}

	actor_run_phase(actor, actor_ctx, actor.msg_ctx)
}

@(private)
actor_run_phase :: proc(
	actor: ^Actor($T),
	actor_ctx: ^Actor_Context,
	ctx: ^Message_Processing_Context,
) {
	run_message_loop(actor, ctx)

	if actor.pool_handle != nil && actor.pool_handle.lifecycle == .Parked_Cold do return

	actor_ctx.panic_teardown_started = true
	terminate_children(actor)
	call_terminate_handler(actor)

	flush_batch_free(&ctx.free_buffer)

	for {
		current := sync.atomic_load(&actor.state)
		if current != .STOPPING {
			log.errorf("Actor %v in unexpected state %v when thread stopping", actor.pid, current)
			break
		}
		if try_transition_state(&actor.state, .STOPPING, .THREAD_STOPPED) do break
	}

	notify_termination(actor)

	wi := sync.atomic_load_explicit(&actor.pool.write_index, .Relaxed)
	sync.atomic_store_explicit(&actor.pool.read_index, wi, .Release)

	log.infof("Terminating - Reason: %s", actor.termination_reason)
	cleanup_actor_context(actor_ctx)
}

@(private)
actor_panic_teardown :: proc(actor: ^Actor($T), actor_ctx: ^Actor_Context) {
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

	if actor_ctx.panic_recovery_done {
		log.fatalf(
			"actor %v panicked inside its own panic recovery, aborting instead of corrupting termination state",
			actor.pid,
		)
		runtime.trap()
	}
	actor_ctx.panic_recovery_done = true

	actor.termination_reason = .ABNORMAL
	sync.atomic_store(&actor.state, .STOPPING)

	if !actor_ctx.panic_teardown_started {
		actor_ctx.panic_teardown_started = true
		terminate_children(actor)
		call_terminate_handler(actor)
	}

	sync.atomic_store(&actor.state, .THREAD_STOPPED)

	if actor.started != nil do sync.atomic_store_explicit(actor.started, true, .Release)

	notify_termination(actor)

	wi := sync.atomic_load_explicit(&actor.pool.write_index, .Relaxed)
	sync.atomic_store_explicit(&actor.pool.read_index, wi, .Release)

	cleanup_actor_context(actor_ctx)
}

@(private)
setup_actor_runtime :: proc(actor: ^Actor($T)) -> (log.Logger, ^Actor_Context) {
	if actor.pid == 0 do panic_at(actor.spawn_loc, "Actor started with PID 0!")

	context.allocator = actor.allocator

	return setup_actor_context(actor.pid, actor.name, actor.opts.logging, actor.allocator)
}

@(private)
spawn_initial_children :: proc(actor: ^Actor($T)) {
	if actor.opts.children == nil do return

	log.info("Initializing children")
	actor.children = make([dynamic]PID, actor.allocator)

	for child_spawn, idx in actor.opts.children {
		pid, ok := child_spawn("", actor.pid)
		if !ok do panic_at(actor.spawn_loc, "Failed to start child in %s", actor.name)

		child_node_id: Node_ID = 0
		if !is_local_pid(pid) do child_node_id = get_node_id(pid)

		actor.child_restarts[pid] = Restart_Info {
			count         = 0,
			first_restart = now(),
			last_restart  = now(),
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
message_processing_context_init :: proc(
	actor: ^Actor($T),
	allocator: mem.Allocator,
) -> Message_Processing_Context {
	return Message_Processing_Context {
		free_buffer = Batch_Free_Buffer{count = 0, pool = &actor.pool},
		batch_size = BATCH_SIZE,
		is_node = actor.pid == NODE.pid,
	}
}

@(private)
ensure_message_batch :: #force_inline proc(
	actor: ^Actor($T),
	ctx: ^Message_Processing_Context,
) {
	if ctx.message_batch != nil do return
	ctx.message_batch = make([]Message, ctx.batch_size, actor.allocator)
	ctx.free_buffer.entries = make([]rawptr, FREE_BATCH_SIZE, actor.allocator)
}

@(private)
call_init_handler :: proc(actor: ^Actor($T)) {
	if actor.behaviour.init != nil do actor.behaviour.init(actor.data)
	if actor.pool_handle != nil {
		worker_idx := -1
		for i in 0 ..< NODE.worker_pool.worker_count {
			if &NODE.worker_pool.workers[i] == actor.pool_handle.home_worker {
				worker_idx = i
				break
			}
		}
		log.infof("Started on worker %d/%d", worker_idx, NODE.worker_pool.worker_count)
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
		process_stop_signals(actor)
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
		   (current_worker.runnext != nil || !ready_is_empty(current_worker)) {
			coro.yield(co)
			continue
		}
		for _ in 0 ..< 64 {
			intrinsics.cpu_relax()
			if mailbox_has_messages(actor) do break
		}
		if !mailbox_has_messages(actor) {
			if actor.pool_handle != nil {
				actor.pool_handle.lifecycle = .Parked_Cold
				return
			}
			coro.yield(co)
		}
	}
}

@(private)
mailbox_has_messages :: #force_inline proc(actor: ^Actor($T)) -> bool {
	if actor.local_read != actor.local_write do return true
	if sync.atomic_load_explicit(&actor.stopped_head, .Relaxed) != nil do return true
	return !mpsc_is_empty_relaxed(&actor.mailbox)
}

@(private)
process_system_mailbox :: #force_no_inline proc(
	actor: ^Actor($T),
	ctx: ^Message_Processing_Context,
) -> bool {
	if mpsc_is_empty_relaxed(&actor.system_mailbox) do return true
	ensure_message_batch(actor, ctx)
	batch_count := mpsc_pop_batch(&actor.system_mailbox, ctx.message_batch[0:ctx.batch_size])

	for i in 0 ..< batch_count {
		msg := &ctx.message_batch[i]
		reconstruct_msg(msg, &ctx.data, &ctx.header)

		if actor.pid == NODE.pid {
			actor.handle_message(actor.data, msg.from, ctx.data)
			if message_owns_page(msg.content) do free_message(&actor.pool, msg.content)
			continue
		}

		switch v in ctx.data {
		case Terminate:
			actor.termination_reason = v.reason

			for {
				current := sync.atomic_load(&actor.state)
				if current == .STOPPING || current == .THREAD_STOPPED do break
				if try_transition_state(&actor.state, current, .STOPPING) do break
			}

			if message_owns_page(msg.content) do free_message(&actor.pool, msg.content)
			return false

		case Actor_Stopped:
			stopped := v
			stopped.child_pid = msg.from
			handle_child_termination(actor, stopped)
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

		if message_owns_page(msg.content) do free_message(&actor.pool, msg.content)

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
		ensure_message_batch(actor, ctx)
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
				deliver_user_message(actor, msg, ctx.data)
				track_message_received(msg.from)
			}
			if message_owns_page(msg.content) do message_free_deferred(&ctx.free_buffer, msg.content)
		}
		flush_batch_free(&ctx.free_buffer)
		if sync.atomic_load(&actor.state) != .RUNNING do return false
	}

	// thread safe
	if !mpsc_has_ready_acquire(&actor.mailbox) do return true
	ensure_message_batch(actor, ctx)
	batch_count := mpsc_pop_batch(&actor.mailbox, ctx.message_batch[0:ctx.batch_size])
	if batch_count == 0 do return true

	is_running := sync.atomic_load(&actor.state) == .RUNNING

	for i in 0 ..< batch_count {
		msg := &ctx.message_batch[i]

		reconstruct_msg(msg, &ctx.data, &ctx.header)

		if !ctx.is_node || is_running {
			deliver_user_message(actor, msg, ctx.data)
			track_message_received(msg.from)
		}
		if message_owns_page(msg.content) do message_free_deferred(&ctx.free_buffer, msg.content)
	}

	flush_batch_free(&ctx.free_buffer)

	track_max_mailbox_size(&actor.mailbox)

	if sync.atomic_load(&actor.state) != .RUNNING do return false

	return true
}

@(private)
wait_for_messages_if_idle :: #force_inline proc(
	actor: ^Actor($T),
	ctx: ^Message_Processing_Context,
) {
	if mpsc_size(&actor.mailbox) == 0 &&
	   mpsc_size(&actor.system_mailbox) == 0 &&
	   sync.atomic_load(&actor.stopped_head) == nil {
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
terminate_children :: proc(actor: ^Actor($T)) {
	if len(actor.children) == 0 do return

	children_to_wait: [dynamic]PID
	defer delete(children_to_wait)

	for child_pid in actor.children {
		if terminate_actor(child_pid, .SHUTDOWN) do append(&children_to_wait, child_pid)
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

		if NODE.timer_pid != 0 && actor.pid != NODE.timer_pid && len(current_actor_context.timers) > 0 {
			if _, timer_active := get(&NODE.actor_registry, NODE.timer_pid); timer_active {
				timer_actor, timer_ok := get_actor_from_pointer(
					get(&NODE.actor_registry, NODE.timer_pid),
					true,
				)
				if timer_ok {
					send(NODE.timer_pid, Cancel_All_Timers{owner = actor.pid}, timer_actor)
				}
			}
		}
	}

	broadcast_actor_terminated(actor.pid, actor.name, actor.termination_reason)

	defer {
		if NODE.pid != actor.pid do push_termination_signal(actor)
	}

	if _, active := get(&NODE.actor_registry, NODE.observer_pid); !active do return

	if actor.pid == NODE.observer_pid && NODE.shutting_down do return

	if current_actor_context == nil do return

	final_stats := Actor_Stats {
		pid                = actor.pid,
		name               = actor.name,
		messages_received  = current_actor_context.stats.messages_received,
		messages_sent      = current_actor_context.stats.messages_sent,
		start_time         = current_actor_context.stats.start_time,
		uptime             = wall_since(current_actor_context.stats.start_time),
		last_update        = now(),
		max_mailbox_size   = current_actor_context.stats.max_mailbox_size,
		state              = sync.atomic_load(&actor.state),
		terminated         = true,
		termination_time   = now(),
		termination_reason = actor.termination_reason,
	}

	final_stats.mailbox_size = mpsc_size(&actor.mailbox)
	final_stats.system_mailbox_size = mpsc_size(&actor.system_mailbox)

	saved_allocator := context.allocator
	context.allocator = actor_system_allocator
	defer context.allocator = saved_allocator

	final_stats.received_from = build_pid_histogram(current_actor_context.stats.received_list[:])
	final_stats.sent_to = build_pid_histogram(current_actor_context.stats.sent_list[:])

	response := Stats_Response {
		stats = final_stats,
	}
	observer_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, NODE.observer_pid), true)
	if ok {
		send(NODE.observer_pid, response, observer_actor)
	} else {
		delete(final_stats.sent_to)
		delete(final_stats.received_from)
	}
}

@(private)
push_stop_signal :: proc(target: ^Actor(int), child: ^Actor(int)) {
	for {
		old := sync.atomic_load(&target.stopped_head)
		child.stop_signal.next = old
		_, swapped := sync.atomic_compare_exchange_weak(
			&target.stopped_head,
			old,
			rawptr(child),
		)
		if swapped do return
	}
}

@(private)
take_stop_signals :: proc(actor: ^Actor($T)) -> ^Actor(int) {
	if sync.atomic_load(&actor.stopped_head) == nil do return nil
	chain := sync.atomic_exchange(&actor.stopped_head, nil)

	reversed: rawptr
	links := 0
	for chain != nil {
		links += 1
		assert(links <= STOP_SIGNAL_CHAIN_BOUND, "stop-signal chain exceeds any possible actor count, the intrusive list is cyclic")
		child := cast(^Actor(int))chain
		next := child.stop_signal.next
		child.stop_signal.next = reversed
		reversed = chain
		chain = next
	}
	return cast(^Actor(int))reversed
}

@(private)
process_stop_signals :: proc(actor: ^Actor($T)) {
	child := take_stop_signals(actor)
	for child != nil {
		next := cast(^Actor(int))child.stop_signal.next

		if actor.pid == NODE.pid {
			if stop_signal_ready(child) {
				cleanup_terminated_actor(child.stop_signal.pid, rawptr(child))
			} else {
				push_stop_signal(cast(^Actor(int))rawptr(actor), child)
			}
		} else {
			name_buf: [STOP_SIGNAL_NAME_CAP]u8
			name_len := copy(name_buf[:], child.stop_signal.name_buf[:child.stop_signal.name_len])
			stopped := Actor_Stopped {
				child_pid   = child.stop_signal.pid,
				reason      = child.stop_signal.reason,
				child_name  = string(name_buf[:name_len]),
				child_index = -1,
			}
			forward_stop_signal_to_node(child)
			handle_child_termination(actor, stopped)
		}

		child = next
	}
}

@(private)
stop_signal_ready :: proc(child: ^Actor(int)) -> bool {
	if child.pool_handle == nil do return true
	return sync.atomic_load_explicit(&child.pool_handle.terminated, .Acquire)
}

@(private)
forward_stop_signal_to_node :: proc(child: ^Actor(int)) {
	if NODE.pid == 0 || NODE.pid == child.stop_signal.pid do return
	node_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, NODE.pid), true)
	if !ok || node_actor == nil {
		log.debugf(
			"no node actor to receive the stop signal of %d (%v)",
			child.stop_signal.pid,
			child.stop_signal.reason,
		)
		return
	}
	push_stop_signal(node_actor, child)
	wake_actor(node_actor)
}

@(private)
drain_stop_signals_to_node :: proc(actor: ^Actor(int)) {
	chain := sync.atomic_exchange(&actor.stopped_head, nil)
	links := 0
	for chain != nil {
		links += 1
		assert(links <= STOP_SIGNAL_CHAIN_BOUND, "stop-signal chain exceeds any possible actor count, the intrusive list is cyclic")
		child := cast(^Actor(int))chain
		next := child.stop_signal.next
		forward_stop_signal_to_node(child)
		chain = next
	}
}

@(private)
push_termination_signal :: proc(actor: ^Actor($T)) {
	assert(
		!sync.atomic_load(&actor.stopped_closed),
		"push_termination_signal called twice for the same actor, its stop-signal node would be linked into two chains",
	)

	self := cast(^Actor(int))rawptr(actor)
	sig := &actor.stop_signal
	sig.pid = actor.pid
	sig.reason = actor.termination_reason
	sig.name_len = copy(sig.name_buf[:], actor.name)

	sync.atomic_store(&actor.stopped_closed, true)

	reclaim_pin()
	defer reclaim_unpin()

	drain_stop_signals_to_node(self)

	if actor.parent != 0 && !is_local_pid(actor.parent) {
		remote_msg := Actor_Stopped {
			child_pid   = actor.pid,
			reason      = actor.termination_reason,
			child_name  = actor.name,
			child_index = -1,
		}
		err := send_message(actor.parent, remote_msg)
		if err != .OK && err != .ACTOR_NOT_FOUND {
			log.errorf(
				"failed to notify remote parent %d that actor %d terminated: %v",
				actor.parent,
				actor.pid,
				err,
			)
		}
		forward_stop_signal_to_node(self)
		return
	}

	deliver_to_parent :=
		actor.parent != 0 &&
		actor.termination_reason != .SHUTDOWN &&
		actor.termination_reason != .KILLED

	if deliver_to_parent {
		parent_actor, ok := get_actor_from_pointer(get(&NODE.actor_registry, actor.parent), true)
		if ok && parent_actor != nil {
			parent_state := sync.atomic_load(&parent_actor.state)
			if parent_state != .STOPPING &&
			   parent_state != .THREAD_STOPPED &&
			   parent_state != .TERMINATED {
				push_stop_signal(parent_actor, self)
				if sync.atomic_load(&parent_actor.stopped_closed) {
					drain_stop_signals_to_node(parent_actor)
				} else {
					wake_actor(parent_actor)
				}
				return
			}
		}
	}

	forward_stop_signal_to_node(self)
}
