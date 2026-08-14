package actod

import ti "../../test_harness/ti"
_ :: ti
import "base:runtime"
import pq "core:container/priority_queue"
import "core:log"
import "core:sync"
import "core:thread"
import "core:time"

Start_Timer :: struct {
	id:       u32,
	interval: time.Duration,
	repeat:   bool,
}

Cancel_Timer :: struct {
	id: u32,
}

Cancel_All_Timers :: struct {
	owner: PID,
}

Timer_Tick :: struct {
	id: u32,
}

Timer_Registration :: distinct u32

MAX_FIRE_BATCH :: 64
MAX_TIMERS :: 8192

@(private)
Timer_Key :: struct {
	id:    u32,
	owner: PID,
}

@(private)
Timer_Entry :: struct {
	id:        u32,
	owner:     PID,
	interval:  time.Duration,
	next_fire: time.Time,
	repeat:    bool,
}

@(private)
Fired_Timer :: struct {
	owner: PID,
	id:    u32,
}

Timer_Registry :: struct {
	heap:      pq.Priority_Queue(Timer_Entry),
	index_map: map[Timer_Key]int,
	lock:      sync.Mutex,
}


@(private)
Timer_Thread_Context :: struct {
	data:      ^Timer_Actor_Data,
	pid:       PID,
	allocator: runtime.Allocator,
	logger:    runtime.Logger,
}

@(private)
Timer_Actor_Data :: struct {
	should_stop:  i32,
	wake_sema:    sync.Sema,
	timer_thread: ^thread.Thread,
	thread_ctx:   ^Timer_Thread_Context,
}


@(private)
timer_heap_less :: proc(a, b: Timer_Entry) -> bool {
	return time.diff(a.next_fire, b.next_fire) > 0
}

@(private)
timer_heap_swap :: proc(q: []Timer_Entry, i, j: int) {
	NODE.timer_registry.index_map[Timer_Key{q[i].id, q[i].owner}] = j
	NODE.timer_registry.index_map[Timer_Key{q[j].id, q[j].owner}] = i
	q[i], q[j] = q[j], q[i]
}

@(init)
init_timer_messages :: proc "contextless" () {
	register_message_type(Start_Timer)
	register_message_type(Cancel_Timer)
	register_message_type(Cancel_All_Timers)
	register_message_type(Timer_Tick)
}

reset_timer_registry :: proc() {
	sync.mutex_lock(&NODE.timer_registry.lock)
	defer sync.mutex_unlock(&NODE.timer_registry.lock)
	pq.destroy(&NODE.timer_registry.heap)
	delete(NODE.timer_registry.index_map)
	NODE.timer_registry.index_map = {}
}

@(private)
spawn_timer_child :: proc(_name: string, parent_pid: PID) -> (PID, bool) {
	pid, ok := start_timer_actor(parent_pid)
	if !ok {
		panic_at(
			NODE.config.loc,
			"node startup failed: the timer actor could not be spawned, set_timer and cancel_timer would never fire",
		)
	}
	return pid, ok
}

@(private)
fire_due_timers :: proc() -> int {
	fire_time := now()
	fired_buf: [MAX_FIRE_BATCH]Fired_Timer
	fired_count := 0
	reg := &NODE.timer_registry

	sync.mutex_lock(&reg.lock)
	for pq.len(reg.heap) > 0 && fired_count < MAX_FIRE_BATCH {
		top := pq.peek(reg.heap)
		if time.diff(fire_time, top.next_fire) > 0 do break

		entry, _ := pq.pop_safe(&reg.heap)
		delete_key(&reg.index_map, Timer_Key{entry.id, entry.owner})

		if entry.repeat {
			entry.next_fire = time.time_add(entry.next_fire, entry.interval)
			if time.diff(fire_time, entry.next_fire) <= 0 {
				entry.next_fire = time.time_add(fire_time, entry.interval)
			}
			reg.index_map[Timer_Key{entry.id, entry.owner}] = pq.len(reg.heap)
			pq.push(&reg.heap, entry)
		}

		fired_buf[fired_count] = Fired_Timer {
			owner = entry.owner,
			id    = entry.id,
		}
		fired_count += 1
	}
	sync.mutex_unlock(&reg.lock)

	for i in 0 ..< fired_count {
		if NODE.config.sim_mode {
			sim_trace_record(.Timer_Fire, u64(fired_buf[i].owner), u64(fired_buf[i].id))
		}
		_ = send_message(fired_buf[i].owner, Timer_Tick{id = fired_buf[i].id})
	}
	return fired_count
}

@(private)
timer_actor_init :: proc(data: ^Timer_Actor_Data) {
	sync.atomic_store(&data.should_stop, 0)
	pq.init(&NODE.timer_registry.heap, timer_heap_less, timer_heap_swap)

	if NODE.config.sim_mode do return

	ctx := new(Timer_Thread_Context)
	ctx.data = data
	ctx.pid = get_self_pid()
	ctx.allocator = context.allocator
	ctx.logger = context.logger
	data.thread_ctx = ctx

	timer_thread_proc :: proc(t: ^thread.Thread) {
		ctx := cast(^Timer_Thread_Context)t.user_args[0]
		if ctx == nil do return
		context.allocator = ctx.allocator
		context.logger = ctx.logger
		data := ctx.data
		reg := &NODE.timer_registry

		for sync.atomic_load(&data.should_stop) == 0 {
			sync.mutex_lock(&reg.lock)
			heap_len := pq.len(reg.heap)
			sleep_duration: time.Duration
			if heap_len > 0 {
				top := pq.peek(reg.heap)
				sleep_duration = time.diff(now(), top.next_fire)
				if sleep_duration < 0 do sleep_duration = 0
			}
			sync.mutex_unlock(&reg.lock)

			if heap_len == 0 {
				sync.sema_wait(&data.wake_sema)
				continue
			} else if sleep_duration > 0 {
				if sync.sema_wait_with_timeout(&data.wake_sema, sleep_duration) do continue
			}

			if sync.atomic_load(&data.should_stop) != 0 do break

			fire_due_timers()
		}
	}

	prev_allocator := context.allocator
	context.allocator = get_system_allocator()
	t := thread.create(timer_thread_proc)
	context.allocator = prev_allocator
	if t != nil {
		t.user_args[0] = ctx
		thread.start(t)
		data.timer_thread = t
	} else {
		log.error(
			"timer actor init failed: could not create the timer thread, NO TIMER WILL EVER FIRE on this node, set_timer will appear to succeed but Timer_Tick will never be delivered",
		)
	}
}

@(private)
timer_actor_terminate :: proc(data: ^Timer_Actor_Data) {
	sync.atomic_store(&data.should_stop, 1)
	sync.sema_post(&data.wake_sema)

	if data.timer_thread != nil {
		thread.join(data.timer_thread)
		thread.destroy(data.timer_thread)
		data.timer_thread = nil
	}

	if data.thread_ctx != nil {
		free(data.thread_ctx)
		data.thread_ctx = nil
	}
}

@(private)
timer_actor_handle_message :: proc(data: ^Timer_Actor_Data, from: PID, msg: any) {
	switch v in msg {
	case Start_Timer:
		sync.mutex_lock(&NODE.timer_registry.lock)
		defer sync.mutex_unlock(&NODE.timer_registry.lock)

		if pq.len(NODE.timer_registry.heap) >= MAX_TIMERS {
			log.errorf(
				"Timer capacity exceeded (%d, MAX_TIMERS), dropping timer id=%d requested by %s",
				MAX_TIMERS,
				v.id,
				actor_origin(from),
			)
			return
		}

		key := Timer_Key{v.id, from}
		if key in NODE.timer_registry.index_map {
			panic_at(
				NODE.config.loc,
				"Duplicate timer: id=%d is already registered for owner %s",
				v.id,
				actor_origin(from),
			)
		}

		entry := Timer_Entry {
			id        = v.id,
			owner     = from,
			interval  = v.interval,
			next_fire = time.time_add(now(), v.interval),
			repeat    = v.repeat,
		}
		NODE.timer_registry.index_map[key] = pq.len(NODE.timer_registry.heap)
		pq.push(&NODE.timer_registry.heap, entry)

		sync.sema_post(&data.wake_sema)

	case Cancel_Timer:
		sync.mutex_lock(&NODE.timer_registry.lock)
		defer sync.mutex_unlock(&NODE.timer_registry.lock)

		key := Timer_Key{v.id, from}
		if idx, ok := NODE.timer_registry.index_map[key]; ok {
			pq.remove(&NODE.timer_registry.heap, idx)
			delete_key(&NODE.timer_registry.index_map, key)
		}

		sync.sema_post(&data.wake_sema)

	case Cancel_All_Timers:
		sync.mutex_lock(&NODE.timer_registry.lock)
		defer sync.mutex_unlock(&NODE.timer_registry.lock)

		i := 0
		for i < pq.len(NODE.timer_registry.heap) {
			entry := NODE.timer_registry.heap.queue[i]
			if entry.owner == v.owner {
				pq.remove(&NODE.timer_registry.heap, i)
				delete_key(&NODE.timer_registry.index_map, Timer_Key{entry.id, entry.owner})
			} else {
				i += 1
			}
		}

		sync.sema_post(&data.wake_sema)
	}
}

start_timer_actor :: proc(parent_pid: PID = 0) -> (PID, bool) {
	pid, ok := spawn(
		"timer",
		Timer_Actor_Data{},
		Actor_Behaviour(Timer_Actor_Data) {
			handle_message = timer_actor_handle_message,
			init = timer_actor_init,
			terminate = timer_actor_terminate,
		},
		make_actor_config(restart_policy = .PERMANENT, supervision_strategy = .ONE_FOR_ONE),
		parent_pid = parent_pid,
	)
	if ok {
		NODE.timer_pid = pid
	} else {
		log.error(
			"start_timer_actor failed: could not spawn the timer actor, set_timer and cancel_timer will fail and no Timer_Tick will ever be delivered",
		)
	}
	return pid, ok
}

stop_timer_actor :: proc() {
	if NODE.timer_pid != 0 {
		_ = terminate_actor(NODE.timer_pid)
		wait_for_pids([]PID{NODE.timer_pid})
		NODE.timer_pid = 0
	}
}

@(require_results)
set_timer :: proc(
	interval: time.Duration,
	repeat: bool,
	loc := #caller_location,
) -> (
	u32,
	Send_Error,
) {
	when ODIN_TEST {if id, err, ok := ti.intercept_set_timer(interval, repeat); ok do return id, Send_Error(err)}

	id := sync.atomic_add(&NODE.next_timer_id, 1) + 1
	if current_actor_context != nil do append(&current_actor_context.timers, Timer_Registration(id))

	if NODE.timer_pid == 0 {
		log.errorf(
			"set_timer failed: the timer actor is not running, timer id=%d will never fire, start the node with node_init or call start_timer_actor",
			id,
			location = loc,
		)
		return id, .ACTOR_NOT_FOUND
	}

	err := send_message(
		NODE.timer_pid,
		Start_Timer{id = id, interval = interval, repeat = repeat},
		loc,
	)
	if err != .OK {
		if err == .SYSTEM_SHUTTING_DOWN {
			log.warnf(
				"set_timer skipped during shutdown, timer id=%d will never fire",
				id,
				location = loc,
			)
		} else {
			log.errorf(
				"set_timer failed: could not reach the timer actor (%v), timer id=%d will never fire",
				err,
				id,
				location = loc,
			)
		}
	}
	return id, err
}

now :: proc() -> time.Time {
	when ODIN_TEST {if t, ok := ti.intercept_now(); ok do return t}
	return time.now()
}

cancel_timer :: proc(id: u32, loc := #caller_location) -> Send_Error {
	when ODIN_TEST {if err, ok := ti.intercept_cancel_timer(id); ok do return Send_Error(err)}

	if id == 0 do return .OK

	if current_actor_context != nil {
		for i := 0; i < len(current_actor_context.timers); i += 1 {
			if current_actor_context.timers[i] == Timer_Registration(id) {
				unordered_remove(&current_actor_context.timers, i)
				break
			}
		}
	}

	if NODE.timer_pid == 0 {
		log.errorf(
			"cancel_timer failed: the timer actor is not running, timer id=%d was not cancelled",
			id,
			location = loc,
		)
		return .ACTOR_NOT_FOUND
	}

	err := send_message(NODE.timer_pid, Cancel_Timer{id = id}, loc)
	if err == .SYSTEM_SHUTTING_DOWN {
		log.debugf(
			"cancel_timer skipped during shutdown, timer id=%d dies with the timer actor",
			id,
			location = loc,
		)
	} else if err != .OK {
		log.errorf(
			"cancel_timer failed: could not reach the timer actor (%v), timer id=%d was not cancelled and may still fire",
			err,
			id,
			location = loc,
		)
	}
	return err
}
