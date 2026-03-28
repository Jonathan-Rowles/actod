package actod

import ti "../../test_harness/ti"
_ :: ti
import "base:runtime"
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

//TODO:  dynamic array
MAX_TIMERS :: 256
MAX_TIMER_SLEEP :: 1 * time.Millisecond

@(private)
Timer_Entry :: struct {
	id:        u32,
	owner:     PID,
	interval:  time.Duration,
	next_fire: time.Time,
	repeat:    bool,
	active:    bool,
}

Timer_Registry :: struct {
	timers:      [MAX_TIMERS]Timer_Entry,
	timer_count: int,
	lock:        sync.Mutex,
}

timer_registry: Timer_Registry
next_timer_id: u32

@(private)
Timer_Actor_Data :: struct {
	should_stop:  i32,
	wake_sema:    sync.Sema,
	timer_thread: ^thread.Thread,
}

TIMER_PID: PID

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
	timer_registry.timer_count = 0
	for i in 0 ..< MAX_TIMERS {
		timer_registry.timers[i] = {}
	}
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

	Timer_Thread_Context :: struct {
		data:      ^Timer_Actor_Data,
		pid:       PID,
		allocator: runtime.Allocator,
		logger:    runtime.Logger,
	}

	ctx := new(Timer_Thread_Context)
	ctx.data = data
	ctx.pid = get_self_pid()
	ctx.allocator = context.allocator
	ctx.logger = context.logger

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
			now := time.now()
			sleep_duration := MAX_TIMER_SLEEP
			has_active := false

			sync.mutex_lock(&reg.lock)
			for i in 0 ..< reg.timer_count {
				entry := &reg.timers[i]
				if !entry.active do continue
				has_active = true

				diff := time.diff(now, entry.next_fire)
				if diff <= 0 {
					sleep_duration = 0
					break
				}
				if diff < sleep_duration {
					sleep_duration = diff
				}
			}
			sync.mutex_unlock(&reg.lock)

			if !has_active {
				sleep_duration = MAX_TIMER_SLEEP
			}

			if sleep_duration > 0 {
				if sync.sema_wait_with_timeout(&data.wake_sema, sleep_duration) {
					continue
				}
			}

			if sync.atomic_load(&data.should_stop) != 0 {
				break
			}

			now = time.now()
			sync.mutex_lock(&reg.lock)
			i := 0
			for i < reg.timer_count {
				entry := &reg.timers[i]
				if !entry.active {
					i += 1
					continue
				}

				if time.diff(now, entry.next_fire) <= 0 {
					owner := entry.owner
					id := entry.id

					if entry.repeat {
						entry.next_fire = time.time_add(now, entry.interval)
						i += 1
					} else {
						entry.active = false
						reg.timer_count -= 1
						if i < reg.timer_count {
							reg.timers[i] = reg.timers[reg.timer_count]
						}
					}

					sync.mutex_unlock(&reg.lock)
					send_message(owner, Timer_Tick{id = id})
					sync.mutex_lock(&reg.lock)

					if !entry.repeat {
						continue
					}
				} else {
					i += 1
				}
			}
			sync.mutex_unlock(&reg.lock)
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
}

@(private)
timer_actor_handle_message :: proc(data: ^Timer_Actor_Data, from: PID, msg: any) {
	switch v in msg {
	case Start_Timer:
		sync.mutex_lock(&timer_registry.lock)
		defer sync.mutex_unlock(&timer_registry.lock)

		for i in 0 ..< timer_registry.timer_count {
			entry := &timer_registry.timers[i]
			if entry.active && entry.id == v.id && entry.owner == from {
				log.panicf("Duplicate timer: id=%d already registered for owner %v", v.id, from)
			}
		}

		if timer_registry.timer_count >= MAX_TIMERS {
			log.errorf(
				"Timer capacity exceeded (%d), dropping timer id=%d from %v",
				MAX_TIMERS,
				v.id,
				from,
			)
			return
		}

		entry := &timer_registry.timers[timer_registry.timer_count]
		entry.id = v.id
		entry.owner = from
		entry.interval = v.interval
		entry.next_fire = time.time_add(time.now(), v.interval)
		entry.repeat = v.repeat
		entry.active = true
		timer_registry.timer_count += 1

		sync.sema_post(&data.wake_sema)

	case Cancel_Timer:
		sync.mutex_lock(&timer_registry.lock)
		defer sync.mutex_unlock(&timer_registry.lock)

		for i in 0 ..< timer_registry.timer_count {
			entry := &timer_registry.timers[i]
			if entry.active && entry.id == v.id && entry.owner == from {
				entry.active = false
				timer_registry.timer_count -= 1
				if i < timer_registry.timer_count {
					timer_registry.timers[i] = timer_registry.timers[timer_registry.timer_count]
				}
				sync.sema_post(&data.wake_sema)
				return
			}
		}

	case Cancel_All_Timers:
		sync.mutex_lock(&timer_registry.lock)
		defer sync.mutex_unlock(&timer_registry.lock)

		i := 0
		for i < timer_registry.timer_count {
			entry := &timer_registry.timers[i]
			if entry.active && entry.owner == v.owner {
				entry.active = false
				timer_registry.timer_count -= 1
				if i < timer_registry.timer_count {
					timer_registry.timers[i] = timer_registry.timers[timer_registry.timer_count]
				}
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
