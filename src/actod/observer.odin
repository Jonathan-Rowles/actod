package actod

import "base:intrinsics"
import "core:log"
import "core:strings"
import "core:time"

Set_Collection_Interval :: struct {
	interval: time.Duration,
}

OBSERVER_TYPE: Actor_Type

@(init)
init_observer_messages :: proc "contextless" () {
	register_message_type(Set_Collection_Interval)
	register_message_type(Stats_Response)
	register_message_type(Stats_Snapshot)
}

Trigger_Collection :: struct {}

Get_All_Stats :: struct {}

Get_Actor_Stats :: struct {
	actor_pid: PID,
}

Get_Actor_Stats_Request :: struct {
	actor_pid: PID,
	requester: PID,
}

Get_All_Stats_Request :: struct {
	requester: PID,
}

Clear_Terminated_Stats :: struct {}

Stats_Response :: struct {
	stats: Actor_Stats,
}

All_Stats_Response :: struct {
	active_stats:     map[PID]Actor_Stats,
	terminated_stats: []Actor_Stats,
}

Actor_Stats_Response :: struct {
	stats: Actor_Stats,
	found: bool,
}

Actor_Stats :: struct {
	pid:                 PID,
	name:                string,
	parent_pid:          PID,
	messages_received:   u64,
	messages_sent:       u64,
	received_from:       map[PID]u64, // PID -> count
	sent_to:             map[PID]u64, // PID -> count
	mailbox_sizes:       [3]int,
	system_mailbox_size: int,
	state:               Actor_State,
	start_time:          time.Time,
	uptime:              time.Duration,
	last_update:         time.Time,
	max_mailbox_size:    int,
	terminated:          bool,
	termination_time:    time.Time,
	termination_reason:  Termination_Reason,
}

MAX_SNAPSHOT_ACTORS :: 64
MAX_SNAPSHOT_FLOWS :: 256
MAX_ACTOR_NAME_LEN :: 32

Actor_Stats_Entry :: struct {
	pid:               PID,
	name:              [MAX_ACTOR_NAME_LEN]byte,
	name_len:          u8,
	messages_received: u64,
	messages_sent:     u64,
	state:             Actor_State,
	terminated:        bool,
	parent_pid:        PID,
}

Message_Flow_Entry :: struct {
	from_pid: PID,
	to_pid:   PID,
	count:    u64,
}

Stats_Snapshot :: struct {
	actors:      [MAX_SNAPSHOT_ACTORS]Actor_Stats_Entry,
	actor_count: u16,
	flows:       [MAX_SNAPSHOT_FLOWS]Message_Flow_Entry,
	flow_count:  u16,
}

Observer_Data :: struct {
	active_stats:           map[PID]Actor_Stats,
	terminated_stats:       [dynamic]Actor_Stats,
	collection_interval:    time.Duration,
	auto_collect:           bool,
	next_collection:        time.Time,
	total_actors_monitored: int,
	collection_count:       int,
	last_collection:        time.Time,
	collection_timer_id:    u32,
}


Observer_Behaviour := Actor_Behaviour(Observer_Data) {
	handle_message = handle_observer_message,
	init           = init_observer,
	terminate      = terminate_observer,
}

@(private)
spawn_observer_child :: proc(_name: string, parent_pid: PID) -> (PID, bool) {
	pid, ok := start_observer(SYSTEM_CONFIG.observer_interval)
	if !ok {
		log.panic("observer failed to start")
	}
	NODE.observer = pid
	return pid, ok
}

@(private)
init_observer :: proc(data: ^Observer_Data) {
	data^ = Observer_Data{}

	data.active_stats = make(map[PID]Actor_Stats)
	data.terminated_stats = make([dynamic]Actor_Stats)
	data.last_collection = time.now()
}

@(private)
handle_observer_message :: proc(data: ^Observer_Data, from: PID, msg: any) {
	switch m in msg {
	case Stats_Response:
		stats := m.stats
		stats.name = strings.clone(m.stats.name)

		if stats.terminated {
			if old_stats, ok := data.active_stats[stats.pid]; ok {
				if len(old_stats.name) > 0 do delete(old_stats.name)
				if old_stats.received_from != nil do delete(old_stats.received_from)
				if old_stats.sent_to != nil do delete(old_stats.sent_to)
				delete_key(&data.active_stats, stats.pid)
			}
			append(&data.terminated_stats, stats)
		} else {
			if old_stats, ok := data.active_stats[stats.pid]; ok {
				if len(old_stats.name) > 0 do delete(old_stats.name)
				if old_stats.received_from != nil do delete(old_stats.received_from)
				if old_stats.sent_to != nil do delete(old_stats.sent_to)
			}
			data.active_stats[stats.pid] = stats
		}
		data.total_actors_monitored = len(data.active_stats) + len(data.terminated_stats)

	case Set_Collection_Interval:
		if data.auto_collect {
			cancel_timer(data.collection_timer_id)
		}
		data.collection_interval = m.interval
		data.auto_collect = m.interval > 0
		if data.auto_collect {
			data.next_collection = time.time_add(time.now(), m.interval)
			data.collection_timer_id, _ = set_timer(m.interval, true)
		}

	case Trigger_Collection:
		collect_all_stats(data)
		broadcast_stats_snapshot(data)

	case Get_All_Stats:
		response := All_Stats_Response {
			active_stats     = data.active_stats,
			terminated_stats = data.terminated_stats[:],
		}
		send_message(from, response)

	case Get_All_Stats_Request:
		response := All_Stats_Response {
			active_stats     = data.active_stats,
			terminated_stats = data.terminated_stats[:],
		}
		send_message(m.requester, response)

	case Get_Actor_Stats:
		response: Actor_Stats_Response
		if stats, ok := data.active_stats[m.actor_pid]; ok {
			response.stats = stats
			response.found = true
		} else {
			for &s in data.terminated_stats {
				if s.pid == m.actor_pid {
					response.stats = s
					response.found = true
					break
				}
			}
		}
		send_message(from, response)

	case Get_Actor_Stats_Request:
		response: Actor_Stats_Response
		if stats, ok := data.active_stats[m.actor_pid]; ok {
			response.stats = stats
			response.found = true
		} else {
			for &s in data.terminated_stats {
				if s.pid == m.actor_pid {
					response.stats = s
					response.found = true
					break
				}
			}
		}
		send_message(m.requester, response)

	case Clear_Terminated_Stats:
		for &stats in data.terminated_stats {
			if stats.received_from != nil do delete(stats.received_from)
			if stats.sent_to != nil do delete(stats.sent_to)
		}
		clear_dynamic_array(&data.terminated_stats)

	case Timer_Tick:
		if m.id == data.collection_timer_id && data.auto_collect {
			collect_all_stats(data)
			broadcast_stats_snapshot(data)
			data.last_collection = time.now()
		}
	}
}

@(private)
broadcast_stats_snapshot :: proc(data: ^Observer_Data) {
	if get_subscriber_count(OBSERVER_TYPE) == 0 {
		return
	}

	snapshot: Stats_Snapshot

	for pid, stats in data.active_stats {
		if snapshot.actor_count >= MAX_SNAPSHOT_ACTORS {
			break
		}

		entry := &snapshot.actors[snapshot.actor_count]
		entry.pid = pid
		entry.messages_received = stats.messages_received
		entry.messages_sent = stats.messages_sent
		entry.state = stats.state
		entry.terminated = stats.terminated
		entry.parent_pid = stats.parent_pid

		name_len := min(len(stats.name), MAX_ACTOR_NAME_LEN)
		for i in 0 ..< name_len {
			entry.name[i] = stats.name[i]
		}
		entry.name_len = u8(name_len)

		if stats.sent_to != nil {
			for to_pid, count in stats.sent_to {
				if snapshot.flow_count >= MAX_SNAPSHOT_FLOWS {
					break
				}
				flow := &snapshot.flows[snapshot.flow_count]
				flow.from_pid = pid
				flow.to_pid = to_pid
				flow.count = count
				snapshot.flow_count += 1
			}
		}

		snapshot.actor_count += 1
	}

	for &stats in data.terminated_stats {
		if snapshot.actor_count >= MAX_SNAPSHOT_ACTORS {
			break
		}

		entry := &snapshot.actors[snapshot.actor_count]
		entry.pid = stats.pid
		entry.messages_received = stats.messages_received
		entry.messages_sent = stats.messages_sent
		entry.state = stats.state
		entry.terminated = true
		entry.parent_pid = stats.parent_pid

		name_len := min(len(stats.name), MAX_ACTOR_NAME_LEN)
		for i in 0 ..< name_len {
			entry.name[i] = stats.name[i]
		}
		entry.name_len = u8(name_len)

		snapshot.actor_count += 1
	}

	broadcast(snapshot)
}

@(private)
collect_all_stats :: proc(data: ^Observer_Data) {
	data.collection_count += 1
	data.last_collection = time.now()

	it := make_iter(&global_registry)
	actor_count := 0
	for {
		_, pid, ok := iter(&it)
		if !ok {
			break
		}

		actor := get(&global_registry, pid)
		if actor == nil || pid == NODE.pid || pid == OBSERVER_PID {
			continue
		}

		actor_count += 1


		msg := Get_Stats {
			requester = OBSERVER_PID,
		}

		send_message(pid, msg)
	}


}

@(private)
terminate_observer :: proc(data: ^Observer_Data) {
	for _, stats in data.active_stats {
		if len(stats.name) > 0 do delete(stats.name)
		if stats.received_from != nil do delete(stats.received_from)
		if stats.sent_to != nil do delete(stats.sent_to)
	}
	for &stats in data.terminated_stats {
		if len(stats.name) > 0 do delete(stats.name)
		if stats.received_from != nil do delete(stats.received_from)
		if stats.sent_to != nil do delete(stats.sent_to)
	}
}

OBSERVER_PID: PID

start_observer :: proc(collection_interval: time.Duration = 0) -> (PID, bool) {
	if OBSERVER_PID != {} {
		log.warnf("Observer already started with PID %v", OBSERVER_PID)
		return OBSERVER_PID, true
	}

	if OBSERVER_TYPE == ACTOR_TYPE_UNTYPED {
		OBSERVER_TYPE, _ = register_actor_type("observer")
	}

	behaviour := Observer_Behaviour
	behaviour.actor_type = OBSERVER_TYPE

	observer_data := Observer_Data{}
	pid, ok := spawn(
		"observer",
		observer_data,
		behaviour,
		SYSTEM_CONFIG.actor_config,
		parent_pid = NODE.pid,
	)
	if !ok do return PID{}, false

	OBSERVER_PID = pid

	if collection_interval > 0 {
		send_message(OBSERVER_PID, Set_Collection_Interval{interval = collection_interval})
	}

	SYSTEM_CONFIG.enable_observer = true

	return pid, ok
}

stop_observer :: proc() {
	if OBSERVER_PID != {} {
		a_ptr, ok := get(&global_registry, OBSERVER_PID)
		if !ok {
			return
		}

		a, _ := get_actor_from_pointer(a_ptr, true)

		for priority in 0 ..< MAILBOX_PRIORITY_COUNT {
			for mpsc_size(&a.mailbox[priority]) > 0 {
				intrinsics.cpu_relax()
			}
		}

		terminate_actor(OBSERVER_PID, .SHUTDOWN)
		for i := 0; i < 100; i += 1 {
			if _, active := get(&global_registry, OBSERVER_PID); !active {
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		OBSERVER_PID = {}
	}

	SYSTEM_CONFIG.enable_observer = false
}

trigger_stats_collection :: proc() -> bool {
	if OBSERVER_PID == {} {
		return false
	}
	msg := Trigger_Collection{}
	return send_message(OBSERVER_PID, msg) == .OK
}


request_actor_stats :: proc(actor_pid: PID, requester: PID) -> bool {
	if OBSERVER_PID == {} {
		return false
	}

	request := Get_Actor_Stats_Request {
		actor_pid = actor_pid,
		requester = requester,
	}

	return send_message(OBSERVER_PID, request) == .OK
}


request_all_stats :: proc(requester: PID) -> bool {
	if OBSERVER_PID == {} {
		return false
	}

	request := Get_All_Stats_Request {
		requester = requester,
	}

	return send_message(OBSERVER_PID, request) == .OK
}

set_stats_collection_interval :: proc(interval: time.Duration) -> bool {
	if OBSERVER_PID == {} {
		return false
	}
	msg := Set_Collection_Interval {
		interval = interval,
	}
	return send_message(OBSERVER_PID, msg) == .OK
}

clear_terminated_stats :: proc() -> bool {
	if OBSERVER_PID == {} {
		return false
	}
	msg := Clear_Terminated_Stats{}
	return send_message(OBSERVER_PID, msg) == .OK
}

subscribe_to_stats :: proc() -> (Subscription, bool) {
	if OBSERVER_TYPE == ACTOR_TYPE_UNTYPED {
		return {}, false
	}
	return subscribe_type(OBSERVER_TYPE)
}

unsubscribe_from_stats :: proc(sub: Subscription) -> bool {
	return pubsub_unsubscribe(sub)
}
