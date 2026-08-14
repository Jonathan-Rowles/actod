package actod

import "../../test_harness/ti"
_ :: ti
import "../pkgs/coro"
import "base:intrinsics"
import "core:log"
import "core:mem"
_ :: mem
import "core:strings"
import "core:sync"
import "../pkgs/threads_act"

@(private)
spawn_fail :: proc(actor: ^Actor($T), pid: PID) {
	if pid != 0 do remove(&NODE.actor_registry, pid)
	actor_arena_release(&actor.arena, &actor.arena_slot)
	free(actor, actor_system_allocator)
}

spawn :: proc {
	spawn_default,
	spawn_sized,
}

@(require_results)
spawn_default :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts := NODE.config.actor_config,
	parent_pid: PID = 0,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	return spawn_impl(name, data, behaviour, DEFAULT_MAIL_BOX_SIZE, opts, parent_pid, loc)
}

@(require_results)
spawn_sized :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	$MAILBOX_SIZE: int,
	opts := NODE.config.actor_config,
	parent_pid: PID = 0,
	loc := #caller_location,
) -> (
	PID,
	bool,
) where MAILBOX_SIZE > 0, (MAILBOX_SIZE & (MAILBOX_SIZE - 1)) == 0 {
	return spawn_impl(name, data, behaviour, MAILBOX_SIZE, opts, parent_pid, loc)
}

@(private)
spawn_alloc_actor :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	mailbox_size: int,
	opts: Actor_Config,
	parent_pid: PID,
	loc := #caller_location,
) -> (
	actor: ^Actor(T),
	pid: PID,
	ok: bool,
) {
	actor = new(Actor(T), actor_system_allocator)

	if actor.state != .ZERO {
		panic_at(loc, "spawn('%s'): allocator returned non-zeroed memory for Actor(%v)", name, typeid_of(T))
	}

	if !actor_arena_acquire(&actor.arena, &actor.arena_slot, size_of(T), mailbox_size, opts) {
		panic_at(loc, "spawn('%s'): failed to reserve actor arena", name)
	}
	actor.allocator = actor_arena_allocator(&actor.arena)
	context.allocator = actor.allocator

	actor.name = strings.clone(name, context.allocator)
	actor.spawn_loc = loc

	when size_of(T) > 0 {
		actor.data = new(T, actor.allocator)
		if actor.data == nil {
			log.errorf(
				"spawn('%s') failed: could not allocate %d B of actor data for %v",
				name,
				size_of(T),
				typeid_of(T),
				location = loc,
			)
			return actor, 0, false
		}
		actor.data^ = data
	} else {
		ptr, err := mem.alloc(1, align_of(T), actor.allocator)
		if err != nil {
			log.errorf(
				"spawn('%s') failed: could not allocate actor data for %v: %v",
				name,
				typeid_of(T),
				err,
				location = loc,
			)
			return actor, 0, false
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
	if actor.opts.page_size <= 0 {
		panic_at(
			loc,
			"spawn('%s'): opts.page_size is %d. Build the config with make_actor_config() rather than a raw Actor_Config{{}}%s",
			name,
			actor.opts.page_size,
			config_origin(actor.opts.loc),
		)
	}

	if parent_pid > 0 {
		if is_local_pid(parent_pid) {
			_, parent_alive := get(&NODE.actor_registry, parent_pid)

			if !parent_alive {
				panic_at(
					loc,
					"spawn('%s'): parent_pid %v is not a live actor (never spawned, or already terminated)",
					name,
					parent_pid,
				)
			}
		}

		actor.parent = parent_pid
	}

	assert(
		mailbox_size > 0 && (mailbox_size & (mailbox_size - 1)) == 0,
		"mailbox size must be a power of two",
		loc,
	)
	mailbox_entries, mailbox_alloc_err := make([]Entry(Message), mailbox_size, actor.allocator)
	if mailbox_alloc_err != nil {
		log.errorf(
			"spawn('%s') failed: could not allocate a %d-slot mailbox (%d B) from the actor arena: %v",
			name,
			mailbox_size,
			mailbox_size * size_of(Entry(Message)),
			mailbox_alloc_err,
			location = loc,
		)
		return actor, 0, false
	}
	mpsc_init(&actor.system_mailbox)
	mpsc_init_external(&actor.mailbox, mailbox_entries)
	pool_init(&actor.pool, actor.allocator, actor.opts.page_size, pool_max_pages(mailbox_size))

	pid, ok = add(&NODE.actor_registry, rawptr(actor), name, behaviour.actor_type, loc)
	if !ok {
		log.errorf(
			"spawn('%s') failed: actor registry is full (%d live actors). Raise actor_registry_size or enable allow_registry_growth in make_node_config()",
			name,
			NODE.actor_registry.num_items,
			location = loc,
		)
		return actor, 0, false
	}

	actor.pid = pid
	actor.state = .INIT
	actor.termination_reason = .NORMAL
	actor.child_restarts = make(map[PID]Restart_Info, actor.allocator)

	return actor, pid, true
}

@(private)
spawn_impl :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	mailbox_size: int,
	opts := NODE.config.actor_config,
	parent_pid: PID = 0,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	context.logger = diagnostic_logger(context.logger)
	when ODIN_TEST {
		if pid, ok := ti.intercept_spawn(name, T); ok do return PID(pid), true
	}

	if !NODE.started {
		panic_at(loc, "spawn('%s'): node_init() must be called before spawning any actor", name)
	}

	if behaviour.handle_message == nil {
		panic_at(
			loc,
			"spawn('%s'): Actor_Behaviour(%v).handle_message must not be nil",
			name,
			typeid_of(T),
		)
	}

	actor, pid, allocated := spawn_alloc_actor(name, data, behaviour, mailbox_size, opts, parent_pid, loc)
	if !allocated {
		spawn_fail(actor, 0)
		return 0, false
	}
	context.allocator = actor.allocator

	if parent_pid > 0 && is_local_pid(parent_pid) {
		parent_ptr := get(&NODE.actor_registry, parent_pid)
		if parent_ptr != nil {
			parent_actor := cast(^Actor(int))parent_ptr
			if parent_actor.children == nil {
				parent_actor.children = make([dynamic]PID, parent_actor.allocator)
			}
			append(&parent_actor.children, pid)
			parent_actor.child_restarts[pid] = Restart_Info {
				count         = 0,
				first_restart = now(),
				last_restart  = now(),
				child_index   = len(parent_actor.children) - 1,
				node_id       = 0,
			}
		}
	}

	broadcast_actor_spawned(pid, name, behaviour.actor_type, parent_pid)

	if spawning_blocking_child {
		if current_actor_context != nil {
			panic_at(
				loc,
				"spawn('%s'): a blocking actor can only be spawned from the main thread, not from inside actor '%s'",
				name,
				current_actor_context.name,
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

	pool_this_actor := !opts.use_dedicated_os_thread && !opts.blocking
	if NODE.config.sim_mode do pool_this_actor = true
	if pool_this_actor && NODE.worker_pool.initialized {
		if !spawn_schedule_pooled(actor, name, pid, loc) {
			spawn_fail(actor, pid)
			return 0, false
		}
	} else {
		actor.thread = threads_act.make_thread_with_stack_size(actor, proc(actor_ptr: rawptr) {
				actor_loop(cast(^Actor(T))actor_ptr)
			}, uint(actor.opts.stack_size_dedicated_os_thread))
		if actor.thread == nil {
			log.errorf(
				"spawn('%s') failed: could not create a dedicated OS thread with a %d B stack (PID %v)",
				name,
				actor.opts.stack_size_dedicated_os_thread,
				pid,
				location = loc,
			)
			spawn_fail(actor, pid)
			return 0, false
		}
	}

	spawn_wait_started(&started)

	register_for_hot_reload(T, actor.pid, name)

	return actor.pid, true
}

@(private)
spawn_schedule_pooled :: proc(actor: ^Actor($T), name: string, pid: PID, loc := #caller_location) -> bool {
	handle := new(Pooled_Actor_Handle, actor.allocator)
	handle.actor_ptr = actor
	handle.mailbox = &actor.mailbox
	handle.system_mailbox = &actor.system_mailbox
	handle.main_fn = proc(ptr: rawptr) {
		actor_loop(cast(^Actor(T))ptr)
	}
	handle.resume_fn = proc(ptr: rawptr) {
		actor_resume(cast(^Actor(T))ptr)
	}

	coro_stack := uint(actor.opts.coro_stack_size)
	if coro_stack < coro.MIN_STACK_SIZE do coro_stack = coro.MIN_STACK_SIZE
	handle.coro_stack = coro_stack
	desc := coro.desc_init(coro_entry, coro_stack)
	desc.user_data = handle
	co, co_res := coro_acquire(&desc, &handle.coro_slot, coro_stack)
	if co_res != .Success {
		log.errorf(
			"spawn('%s') failed: could not create coroutine with a %d B stack: %v",
			name,
			coro_stack,
			co_res,
			location = loc,
		)
		return false
	}
	handle.co = co
	actor.pool_handle = handle

	idx := -1
	if actor.opts.home_worker >= 0 {
		if actor.opts.home_worker >= NODE.worker_pool.worker_count {
			panic_at(
				loc,
				"spawn('%s'): home_worker=%d but this node has only %d workers (valid indices 0-%d)%s",
				name,
				actor.opts.home_worker,
				NODE.worker_pool.worker_count,
				NODE.worker_pool.worker_count - 1,
				config_origin(actor.opts.loc),
			)
		}
		idx = actor.opts.home_worker
	} else if affinity_pid, affinity_ok := resolve_actor_ref(actor.opts.affinity);
	   affinity_ok {
		affinity_actor := get(&NODE.actor_registry, affinity_pid)
		if affinity_actor != nil {
			affinity_handle := (cast(^Actor(int))affinity_actor).pool_handle
			if affinity_handle != nil && affinity_handle.home_worker != nil {
				for i in 0 ..< NODE.worker_pool.worker_count {
					if &NODE.worker_pool.workers[i] == affinity_handle.home_worker {
						idx = i
						break
					}
				}
			}
		}
	}
	if idx < 0 {
		idx = sync.atomic_add(&NODE.worker_pool.next_worker, 1) % NODE.worker_pool.worker_count
		if current_worker != nil &&
		   &NODE.worker_pool.workers[idx] == current_worker &&
		   NODE.worker_pool.worker_count > 1 {
			idx = sync.atomic_add(&NODE.worker_pool.next_worker, 1) % NODE.worker_pool.worker_count
		}
	}
	handle.home_worker = &NODE.worker_pool.workers[idx]
	set_entry_home_worker(&NODE.actor_registry, pid, idx)
	sync.atomic_store(&handle.in_ready_queue, true)
	ready_push(handle.home_worker, handle)
	sync.atomic_sema_post(&handle.home_worker.wake_sema)

	return true
}

@(private)
spawn_wait_started :: proc(started: ^bool) {
	co := coro.running()
	if co != nil {
		for !sync.atomic_load_explicit(started, .Acquire) {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		}
	} else {
		for !sync.atomic_load_explicit(started, .Acquire) {
			if NODE.config.sim_mode {
				sim_pump()
			} else {
				intrinsics.cpu_relax()
			}
		}
	}
}

spawn_child :: proc {
	spawn_child_default,
	spawn_child_sized,
}

@(require_results)
spawn_child_default :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	opts := NODE.config.actor_config,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	when ODIN_TEST {
		if pid, ok := ti.intercept_spawn_child(name, T); ok do return PID(pid), true
	}

	if current_actor_context == nil {
		panic_at(
			loc,
			"spawn_child('%s'): must be called from inside an actor. Use spawn() with an explicit parent_pid outside one",
			name,
		)
	}
	self_pid := get_self_pid()
	return spawn_impl(name, data, behaviour, DEFAULT_MAIL_BOX_SIZE, opts, self_pid, loc)
}

@(require_results)
spawn_child_sized :: proc(
	name: string,
	data: $T,
	behaviour: Actor_Behaviour(T),
	$MAILBOX_SIZE: int,
	opts := NODE.config.actor_config,
	loc := #caller_location,
) -> (
	PID,
	bool,
) where MAILBOX_SIZE > 0, (MAILBOX_SIZE & (MAILBOX_SIZE - 1)) == 0 {
	when ODIN_TEST {
		if pid, ok := ti.intercept_spawn_child(name, T); ok do return PID(pid), true
	}

	if current_actor_context == nil {
		panic_at(
			loc,
			"spawn_child('%s'): must be called from inside an actor. Use spawn() with an explicit parent_pid outside one",
			name,
		)
	}
	self_pid := get_self_pid()
	return spawn_impl(name, data, behaviour, MAILBOX_SIZE, opts, self_pid, loc)
}
