package sim

import "../../src/actod"
import "../ti"
import "core:mem"
import "core:testing"
import "core:time"

MAX_SIM_ACTORS :: 32
MAX_SIM_QUEUE :: 1024
MAX_SIM_TIMERS :: 128
MAX_SIM_TOPICS :: 64
MAX_SIM_TOPIC_SUBS :: 16
MAX_SIM_FAULTS :: 16

EXTERNAL_PID :: u64(999)

Sim :: struct {
	actors:          [MAX_SIM_ACTORS]Sim_Actor,
	actor_count:     int,
	queue:           [MAX_SIM_QUEUE]Sim_Message,
	queue_head:      int,
	queue_tail:      int,
	queue_count:     int,
	timers:          [MAX_SIM_TIMERS]Sim_Timer,
	timer_count:     int,
	clock:           time.Time,
	pid_registry:    map[string]u64,
	topic_subs:      [MAX_SIM_TOPICS]Sim_Topic_Sub,
	topic_sub_count: int,
	next_pid:        u64,
	next_timer_id:   u32,
	send_capture:    [dynamic]ti.Captured_Send,
	publish_capture: [dynamic]ti.Captured_Publish,
	timer_capture:   [dynamic]ti.Captured_Timer,
	spawn_capture:   [dynamic]ti.Captured_Spawn,
	term_capture:    [dynamic]ti.Captured_Terminate,
	topic_sub_cap:   [dynamic]ti.Captured_Topic_Subscribe,
	broadcast_cap:   [dynamic]ti.Captured_Broadcast,
	rename_cap:      [dynamic]ti.Captured_Rename,
	subscribe_cap:   [dynamic]ti.Captured_Subscribe,
	children_pids:   [dynamic]u64,
	intercept:       ti.Test_Intercept,
	all_spawns:      [dynamic]ti.Captured_Spawn,
	faults:          [MAX_SIM_FAULTS]Fault_Rule,
	fault_count:     int,
	delayed:         [dynamic]Delayed_Message,
	rng_state:       u64,
}

Sim_Actor :: struct {
	name:           string,
	pid:            u64,
	data:           rawptr,
	handle_message: proc(data: rawptr, from: u64, content: any),
	init_fn:        proc(data: rawptr),
	terminate_fn:   proc(data: rawptr),
	parent_pid:     u64,
	alive:          bool,
}

Sim_Message :: struct {
	to:      u64,
	from:    u64,
	data:    rawptr,
	type_id: typeid,
}

Sim_Timer :: struct {
	id:        u32,
	owner_pid: u64,
	interval:  time.Duration,
	next_fire: time.Time,
	repeat:    bool,
	active:    bool,
}

Sim_Topic_Sub :: struct {
	topic: rawptr,
	pids:  [MAX_SIM_TOPIC_SUBS]u64,
	count: int,
}

Fault_Action :: enum {
	Drop,
	Delay,
	Duplicate,
}

Fault_Match :: struct {
	to_name:   Maybe(string),
	from_name: Maybe(string),
	msg_type:  Maybe(typeid),
}

Fault_Rule :: struct {
	match:       Fault_Match,
	action:      Fault_Action,
	delay_steps: int,
	remaining:   int, // -1 = forever
	fired:       int,
	probability: f64, // 0 = always fire (default), 0.0-1.0 = probabilistic
}

Delayed_Message :: struct {
	msg:             Sim_Message,
	steps_remaining: int,
}


create :: proc() -> Sim {
	s: Sim
	s.clock = time.Time {
		_nsec = 1_000_000_000_000,
	} // 1000s — avoids zero-time edge cases
	s.next_pid = 1
	return s
}

create_seeded :: proc(seed: u64) -> Sim {
	s := create()
	s.rng_state = seed
	return s
}

rng_next :: proc(s: ^Sim) -> u64 {
	s.rng_state = s.rng_state * 6364136223846793005 + 1442695040888963407
	return s.rng_state
}

rng_f64 :: proc(s: ^Sim) -> f64 {
	return f64(rng_next(s) >> 11) / f64(1 << 53)
}

destroy :: proc(s: ^Sim) {
	drain_queue(s)
	for i in 0 ..< s.actor_count {
		if s.actors[i].data != nil do free(s.actors[i].data)
	}
	for &cap in s.send_capture do free(cap.data)
	for &cap in s.publish_capture do free(cap.data)
	for &cap in s.broadcast_cap do free(cap.data)
	delete(s.send_capture)
	delete(s.publish_capture)
	delete(s.timer_capture)
	delete(s.spawn_capture)
	delete(s.term_capture)
	delete(s.topic_sub_cap)
	delete(s.broadcast_cap)
	delete(s.rename_cap)
	delete(s.subscribe_cap)
	delete(s.children_pids)
	delete(s.all_spawns)
	delete(s.pid_registry)
	for &d in s.delayed {
		if d.msg.data != nil do free(d.msg.data)
	}
	delete(s.delayed)
}

drain_queue :: proc(s: ^Sim) {
	for s.queue_count > 0 {
		msg := &s.queue[s.queue_head]
		if msg.data != nil do free(msg.data)
		msg^ = {}
		s.queue_head = (s.queue_head + 1) % MAX_SIM_QUEUE
		s.queue_count -= 1
	}
}

spawn :: proc(s: ^Sim, name: string, data: $T, behaviour: actod.Actor_Behaviour(T)) -> actod.PID {
	assert(s.actor_count < MAX_SIM_ACTORS, "sim: too many actors")

	pid := s.next_pid
	s.next_pid += 1

	actor := &s.actors[s.actor_count]
	s.actor_count += 1

	actor.name = name
	actor.pid = pid
	actor.data = new(T)
	(cast(^T)actor.data)^ = data
	actor.handle_message = transmute(proc(_: rawptr, _: u64, _: any))behaviour.handle_message
	actor.init_fn = transmute(proc(_: rawptr))behaviour.init
	actor.terminate_fn = transmute(proc(_: rawptr))behaviour.terminate
	actor.alive = true

	s.pid_registry[name] = pid
	return actod.PID(pid)
}

init_all :: proc(s: ^Sim) {
	for i in 0 ..< s.actor_count {
		actor := &s.actors[i]
		if !actor.alive do continue
		if actor.init_fn == nil do continue

		install_intercept(s, actor)
		defer uninstall_intercept()
		actor.init_fn(actor.data)
		process_captures(s, actor.pid)
	}
}

install_intercept :: proc(s: ^Sim, actor: ^Sim_Actor) {
	s.intercept.send_capture = &s.send_capture
	s.intercept.publish_capture = &s.publish_capture
	s.intercept.timer_capture = &s.timer_capture
	s.intercept.pid_registry = &s.pid_registry
	s.intercept.spawn_capture = &s.spawn_capture
	s.intercept.terminate_capture = &s.term_capture
	s.intercept.broadcast_capture = &s.broadcast_cap
	s.intercept.rename_capture = &s.rename_cap
	s.intercept.subscribe_capture = &s.subscribe_cap
	s.intercept.topic_subscribe_capture = &s.topic_sub_cap
	s.intercept.children_pids = &s.children_pids
	s.intercept.self_pid = actor.pid
	s.intercept.self_name = actor.name
	s.intercept.parent_pid = actor.parent_pid
	s.intercept.next_timer_id = s.next_timer_id
	s.intercept.next_spawn_pid = s.next_pid
	s.intercept.virtual_now = s.clock
	ti.test_intercept = &s.intercept
}

uninstall_intercept :: proc() {
	ti.test_intercept = nil
}

enqueue :: proc(s: ^Sim, to, from: u64, data: rawptr, type_id: typeid) {
	assert(s.queue_count < MAX_SIM_QUEUE, "sim: message queue full")
	s.queue[s.queue_tail] = Sim_Message {
		to      = to,
		from    = from,
		data    = data,
		type_id = type_id,
	}
	s.queue_tail = (s.queue_tail + 1) % MAX_SIM_QUEUE
	s.queue_count += 1
}

@(private)
enqueue_clone :: proc(s: ^Sim, to, from: u64, content: $T) {
	ptr, _ := mem.alloc(size_of(T))
	clone := cast(^T)ptr
	clone^ = content
	enqueue(s, to, from, ptr, T)
}

dequeue :: proc(s: ^Sim) -> (Sim_Message, bool) {
	if s.queue_count == 0 do return {}, false
	msg := s.queue[s.queue_head]
	s.queue[s.queue_head] = {}
	s.queue_head = (s.queue_head + 1) % MAX_SIM_QUEUE
	s.queue_count -= 1
	return msg, true
}

step :: proc(s: ^Sim) -> bool {
	tick_delayed(s)

	msg, ok := dequeue(s)
	if !ok do return false

	if rule := match_fault(s, msg); rule != nil {
		rule.fired += 1
		if rule.remaining > 0 do rule.remaining -= 1

		switch rule.action {
		case .Drop:
			if msg.data != nil do free(msg.data)
			return true
		case .Delay:
			append(&s.delayed, Delayed_Message{msg = msg, steps_remaining = rule.delay_steps})
			return true
		case .Duplicate:
			clone_data := clone_msg(msg.data, msg.type_id)
			enqueue(s, msg.to, msg.from, clone_data, msg.type_id)
		}
	}

	actor := find_actor_by_pid(s, msg.to)
	if actor == nil || !actor.alive {
		if msg.data != nil do free(msg.data)
		return true
	}

	install_intercept(s, actor)
	content := any {
		data = msg.data,
		id   = msg.type_id,
	}
	actor.handle_message(actor.data, msg.from, content)
	uninstall_intercept()

	s.next_timer_id = s.intercept.next_timer_id
	s.next_pid = s.intercept.next_spawn_pid

	process_captures(s, actor.pid)

	if msg.data != nil do free(msg.data)
	return true
}

run_until_idle :: proc(s: ^Sim) {
	for {
		if !step(s) do break
	}
}

process_captures :: proc(s: ^Sim, sender_pid: u64) {
	for &cap in s.send_capture {
		enqueue(s, cap.to, sender_pid, cap.data, cap.type_id)
		cap.data = nil // ownership transferred
	}
	clear(&s.send_capture)

	for &cap in s.publish_capture {
		route_publish(s, sender_pid, cap.topic, cap.data, cap.type_id)
		cap.data = nil
	}
	clear(&s.publish_capture)

	for &cap in s.timer_capture {
		if cap.active {
			add_timer(s, cap.id, sender_pid, cap.interval, cap.repeat)
		}
	}
	clear(&s.timer_capture)

	for &cap in s.topic_sub_cap {
		add_topic_sub(s, cap.topic, sender_pid)
	}
	clear(&s.topic_sub_cap)

	for &cap in s.spawn_capture {
		append(&s.all_spawns, cap)
	}
	clear(&s.spawn_capture)

	for &cap in s.term_capture {
		a := find_actor_by_pid(s, cap.pid)
		if a != nil do a.alive = false
	}
	clear(&s.term_capture)

	for &cap in s.broadcast_cap {
		first := true
		for i in 0 ..< s.actor_count {
			a := &s.actors[i]
			if !a.alive || a.pid == sender_pid do continue
			if first {
				enqueue(s, a.pid, sender_pid, cap.data, cap.type_id)
				first = false
			} else {
				clone := clone_msg(cap.data, cap.type_id)
				enqueue(s, a.pid, sender_pid, clone, cap.type_id)
			}
		}
		if first && cap.data != nil {
			free(cap.data)
		}
		cap.data = nil
	}
	clear(&s.broadcast_cap)

	for &cap in s.rename_cap {
		a := find_actor_by_pid(s, cap.pid)
		if a != nil {
			delete_key(&s.pid_registry, a.name)
			s.pid_registry[cap.new_name] = cap.pid
			a.name = cap.new_name
		}
	}
	clear(&s.rename_cap)

	clear(&s.subscribe_cap)
	clear(&s.children_pids)
}

add_topic_sub :: proc(s: ^Sim, topic: rawptr, pid: u64) {
	for i in 0 ..< s.topic_sub_count {
		if s.topic_subs[i].topic == topic {
			ts := &s.topic_subs[i]
			assert(ts.count < MAX_SIM_TOPIC_SUBS, "sim: too many topic subscribers")
			ts.pids[ts.count] = pid
			ts.count += 1
			return
		}
	}
	assert(s.topic_sub_count < MAX_SIM_TOPICS, "sim: too many topics")
	ts := &s.topic_subs[s.topic_sub_count]
	s.topic_sub_count += 1
	ts.topic = topic
	ts.pids[0] = pid
	ts.count = 1
}

route_publish :: proc(s: ^Sim, sender_pid: u64, topic: rawptr, data: rawptr, type_id: typeid) {
	for i in 0 ..< s.topic_sub_count {
		if s.topic_subs[i].topic != topic do continue
		ts := &s.topic_subs[i]
		first := true
		for j in 0 ..< ts.count {
			if ts.pids[j] == sender_pid do continue // don't send to self
			if first {
				enqueue(s, ts.pids[j], sender_pid, data, type_id)
				first = false
			} else {
				clone := clone_msg(data, type_id)
				enqueue(s, ts.pids[j], sender_pid, clone, type_id)
			}
		}
		if first && data != nil {
			free(data)
		}
		return
	}
	if data != nil do free(data)
}

clone_msg :: proc(data: rawptr, type_id: typeid) -> rawptr {
	info := type_info_of(type_id)
	size := info.size
	ptr, _ := mem.alloc(size)
	mem.copy(ptr, data, size)
	return ptr
}

add_timer :: proc(s: ^Sim, id: u32, owner: u64, interval: time.Duration, repeat: bool) {
	assert(s.timer_count < MAX_SIM_TIMERS, "sim: too many timers")
	s.timers[s.timer_count] = Sim_Timer {
		id        = id,
		owner_pid = owner,
		interval  = interval,
		next_fire = time.time_add(s.clock, interval),
		repeat    = repeat,
		active    = true,
	}
	s.timer_count += 1
}

cancel_timer :: proc(s: ^Sim, id: u32) {
	for i in 0 ..< s.timer_count {
		if s.timers[i].id == id {
			s.timers[i].active = false
			return
		}
	}
}

advance_time :: proc(s: ^Sim, d: time.Duration) {
	s.clock = time.time_add(s.clock, d)
	s.intercept.virtual_now = s.clock
	fire_expired_timers(s)
}

fire_expired_timers :: proc(s: ^Sim) {
	for {
		fired := false
		for i in 0 ..< s.timer_count {
			t := &s.timers[i]
			if !t.active do continue
			if time.diff(t.next_fire, s.clock) >= 0 {
				enqueue_clone(s, t.owner_pid, t.owner_pid, actod.Timer_Tick{id = t.id})
				if t.repeat {
					t.next_fire = time.time_add(t.next_fire, t.interval)
				} else {
					t.active = false
				}
				fired = true
			}
		}
		if !fired do break
	}
}

publish :: proc(s: ^Sim, topic: rawptr, content: $T) {
	for i in 0 ..< s.topic_sub_count {
		if s.topic_subs[i].topic != topic do continue
		ts := &s.topic_subs[i]
		for j in 0 ..< ts.count {
			enqueue_clone(s, ts.pids[j], EXTERNAL_PID, content)
		}
		return
	}
}

send_from :: proc(s: ^Sim, to, from: actod.PID, content: $T) {
	enqueue_clone(s, u64(to), u64(from), content)
}

send :: proc(s: ^Sim, actor_name: string, content: $T) {
	pid, ok := s.pid_registry[actor_name]
	if !ok do return
	enqueue_clone(s, pid, EXTERNAL_PID, content)
}

send_to :: proc(s: ^Sim, pid: actod.PID, content: $T) {
	enqueue_clone(s, u64(pid), EXTERNAL_PID, content)
}

find_actor_by_pid :: proc(s: ^Sim, pid: u64) -> ^Sim_Actor {
	for i in 0 ..< s.actor_count {
		if s.actors[i].pid == pid do return &s.actors[i]
	}
	return nil
}

find_actor_by_name :: proc(s: ^Sim, name: string) -> ^Sim_Actor {
	pid, ok := s.pid_registry[name]
	if !ok do return nil
	return find_actor_by_pid(s, pid)
}

get_state :: proc(s: ^Sim, name: string, $T: typeid) -> ^T {
	actor := find_actor_by_name(s, name)
	if actor == nil do return nil
	return cast(^T)actor.data
}

find_spawn :: proc(s: ^Sim, $T: typeid) -> (ti.Captured_Spawn, bool) {
	for i in 0 ..< len(s.all_spawns) {
		if s.all_spawns[i].type_id == T {
			result := s.all_spawns[i]
			ordered_remove(&s.all_spawns, i)
			return result, true
		}
	}
	return {}, false
}

expect_spawned :: proc(
	s: ^Sim,
	t: ^testing.T,
	$T: typeid,
	loc := #caller_location,
) -> ti.Captured_Spawn {
	result, ok := find_spawn(s, T)
	testing.expectf(t, ok, "expected spawn of type %v, but none found", typeid_of(T), loc = loc)
	return result
}

expect_idle :: proc(s: ^Sim, t: ^testing.T, loc := #caller_location) {
	testing.expectf(
		t,
		s.queue_count == 0,
		"expected idle, but %d messages pending",
		s.queue_count,
		loc = loc,
	)
}

expect_alive :: proc(s: ^Sim, t: ^testing.T, name: string, loc := #caller_location) {
	actor := find_actor_by_name(s, name)
	testing.expectf(t, actor != nil, "expected actor %v to exist", name, loc = loc)
	if actor != nil {
		testing.expectf(t, actor.alive, "expected actor %v to be alive", name, loc = loc)
	}
}

expect_dead :: proc(s: ^Sim, t: ^testing.T, name: string, loc := #caller_location) {
	actor := find_actor_by_name(s, name)
	testing.expectf(t, actor != nil, "expected actor %v to exist", name, loc = loc)
	if actor != nil {
		testing.expectf(t, !actor.alive, "expected actor %v to be dead", name, loc = loc)
	}
}

pending_messages :: proc(s: ^Sim) -> int {
	return s.queue_count
}

add_fault :: proc(s: ^Sim, rule: Fault_Rule) {
	assert(s.fault_count < MAX_SIM_FAULTS, "sim: too many fault rules")
	s.faults[s.fault_count] = rule
	s.fault_count += 1
}

clear_faults :: proc(s: ^Sim) {
	s.fault_count = 0
	for &d in s.delayed {
		if d.msg.data != nil do free(d.msg.data)
	}
	clear(&s.delayed)
}

match_fault :: proc(s: ^Sim, msg: Sim_Message) -> ^Fault_Rule {
	for i in 0 ..< s.fault_count {
		rule := &s.faults[i]
		if rule.remaining == 0 do continue
		if !fault_matches(s, rule.match, msg) do continue
		if rule.probability > 0 {
			if rng_f64(s) >= rule.probability do continue
		}
		return rule
	}
	return nil
}

fault_matches :: proc(s: ^Sim, m: Fault_Match, msg: Sim_Message) -> bool {
	if to_name, has_to := m.to_name.?; has_to {
		actor := find_actor_by_pid(s, msg.to)
		if actor == nil || actor.name != to_name do return false
	}
	if from_name, has_from := m.from_name.?; has_from {
		actor := find_actor_by_pid(s, msg.from)
		if actor == nil || actor.name != from_name do return false
	}
	if msg_type, has_type := m.msg_type.?; has_type {
		if msg.type_id != msg_type do return false
	}
	return true
}

tick_delayed :: proc(s: ^Sim) {
	i := 0
	for i < len(s.delayed) {
		s.delayed[i].steps_remaining -= 1
		if s.delayed[i].steps_remaining <= 0 {
			d := s.delayed[i]
			enqueue(s, d.msg.to, d.msg.from, d.msg.data, d.msg.type_id)
			ordered_remove(&s.delayed, i)
		} else {
			i += 1
		}
	}
}

delayed_count :: proc(s: ^Sim) -> int {
	return len(s.delayed)
}
