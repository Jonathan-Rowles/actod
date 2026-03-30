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

timer_registry: Timer_Registry
next_timer_id: u32

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

TIMER_PID: PID

@(private)
timer_heap_less :: proc(a, b: Timer_Entry) -> bool {
	return time.diff(a.next_fire, b.next_fire) > 0
}

@(private)
timer_heap_swap :: proc(q: []Timer_Entry, i, j: int) {
	timer_registry.index_map[Timer_Key{q[i].id, q[i].owner}] = j
	timer_registry.index_map[Timer_Key{q[j].id, q[j].owner}] = i
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
	sync.mutex_lock(&timer_registry.lock)
	defer sync.mutex_unlock(&timer_registry.lock)
	pq.destroy(&timer_registry.heap)
	delete(timer_registry.index_map)
	timer_registry.index_map = {}
}

@(private)
spawn_timer_child :: proc(_name: string, parent_pid: PID) -> (PID, bool) {
	pid, ok := start_timer_actor(parent_pid)
	if !ok {
		log.panic("timer actor failed to start")
	}
	return pid, ok
}

@(private)
timer_actor_init :: proc(data: ^Timer_Actor_Data) {
	sync.atomic_store(&data.should_stop, 0)
	pq.init(&timer_registry.heap, timer_heap_less, timer_heap_swap)

	ctx := new(Timer_Thread_Context)
	ctx.data = data
	ctx.pid = get_self_pid()
	ctx.allocator = context.allocator
	ctx.logger = context.logger
	data.thread_ctx = ctx

	timer_thread_proc :: proc(t: ^thread.Thread) {
		ctx := cast(^Timer_Thread_Context)t.user_args[0]
		if ctx == nil {
			return
		}
		context.allocator = ctx.allocator
		context.logger = ctx.logger
		data := ctx.data
		reg := &timer_registry

		for sync.atomic_load(&data.should_stop) == 0 {
			sync.mutex_lock(&reg.lock)
			heap_len := pq.len(reg.heap)
			sleep_duration: time.Duration
			if heap_len > 0 {
				top := pq.peek(reg.heap)
				sleep_duration = time.diff(time.now(), top.next_fire)
				if sleep_duration < 0 {
					sleep_duration = 0
				}
			}
			sync.mutex_unlock(&reg.lock)

			if heap_len == 0 {
				sync.sema_wait(&data.wake_sema)
				continue
			} else if sleep_duration > 0 {
				if sync.sema_wait_with_timeout(&data.wake_sema, sleep_duration) {
					continue
				}
			}

			if sync.atomic_load(&data.should_stop) != 0 {
				break
			}

			now := time.now()
			fired_buf: [MAX_FIRE_BATCH]Fired_Timer
			fired_count := 0

			sync.mutex_lock(&reg.lock)
			for pq.len(reg.heap) > 0 && fired_count < MAX_FIRE_BATCH {
				top := pq.peek(reg.heap)
				if time.diff(now, top.next_fire) > 0 {
					break
				}

				entry, _ := pq.pop_safe(&reg.heap)
				delete_key(&reg.index_map, Timer_Key{entry.id, entry.owner})

				if entry.repeat {
					entry.next_fire = time.time_add(entry.next_fire, entry.interval)
					if time.diff(now, entry.next_fire) <= 0 {
						entry.next_fire = time.time_add(now, entry.interval)
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
				send_message(fired_buf[i].owner, Timer_Tick{id = fired_buf[i].id})
			}
		}
	}

	t := thread.create(timer_thread_proc)
	if t != nil {
		t.user_args[0] = ctx
		thread.start(t)
		data.timer_thread = t
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
		sync.mutex_lock(&timer_registry.lock)
		defer sync.mutex_unlock(&timer_registry.lock)

		if pq.len(timer_registry.heap) >= MAX_TIMERS {
			log.errorf(
				"Timer capacity exceeded (%d), dropping timer id=%d from %v",
				MAX_TIMERS,
				v.id,
				from,
			)
			return
		}

		key := Timer_Key{v.id, from}
		if key in timer_registry.index_map {
			log.panicf("Duplicate timer: id=%d already registered for owner %v", v.id, from)
		}

		entry := Timer_Entry {
			id        = v.id,
			owner     = from,
			interval  = v.interval,
			next_fire = time.time_add(time.now(), v.interval),
			repeat    = v.repeat,
		}
		timer_registry.index_map[key] = pq.len(timer_registry.heap)
		pq.push(&timer_registry.heap, entry)

		sync.sema_post(&data.wake_sema)

	case Cancel_Timer:
		sync.mutex_lock(&timer_registry.lock)
		defer sync.mutex_unlock(&timer_registry.lock)

		key := Timer_Key{v.id, from}
		if idx, ok := timer_registry.index_map[key]; ok {
			pq.remove(&timer_registry.heap, idx)
			delete_key(&timer_registry.index_map, key)
		}

		sync.sema_post(&data.wake_sema)

	case Cancel_All_Timers:
		sync.mutex_lock(&timer_registry.lock)
		defer sync.mutex_unlock(&timer_registry.lock)

		i := 0
		for i < pq.len(timer_registry.heap) {
			entry := timer_registry.heap.queue[i]
			if entry.owner == v.owner {
				pq.remove(&timer_registry.heap, i)
				delete_key(&timer_registry.index_map, Timer_Key{entry.id, entry.owner})
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
		TIMER_PID = pid
	}
	return pid, ok
}

stop_timer_actor :: proc() {
	if TIMER_PID != 0 {
		terminate_actor(TIMER_PID)
		wait_for_pids([]PID{TIMER_PID})
		TIMER_PID = 0
	}
}

set_timer :: proc(interval: time.Duration, repeat: bool) -> (u32, Send_Error) {
	when ODIN_TEST {if id, err, ok := ti.intercept_set_timer(interval, repeat); ok do return id, Send_Error(err)}

	id := sync.atomic_add(&next_timer_id, 1) + 1
	if current_actor_context != nil {
		append(&current_actor_context.timers, Timer_Registration(id))
	}
	err := send_message(TIMER_PID, Start_Timer{id = id, interval = interval, repeat = repeat})
	return id, err
}

now :: proc() -> time.Time {
	when ODIN_TEST {if t, ok := ti.intercept_now(); ok do return t}
	return time.now()
}

cancel_timer :: proc(id: u32) -> Send_Error {
	when ODIN_TEST {if err, ok := ti.intercept_cancel_timer(id); ok do return Send_Error(err)}

	if current_actor_context != nil {
		for i := 0; i < len(current_actor_context.timers); i += 1 {
			if current_actor_context.timers[i] == Timer_Registration(id) {
				unordered_remove(&current_actor_context.timers, i)
				break
			}
		}
	}
	return send_message(TIMER_PID, Cancel_Timer{id = id})
}
