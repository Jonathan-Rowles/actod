package actod

import "base:runtime"
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
	received_from:       map[PID]u64,
	sent_to:             map[PID]u64,
	mailbox_size:        int,
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
	init           = observer_init,
	terminate      = terminate_observer,
}

@(private)
spawn_observer_child :: proc(_name: string, parent_pid: PID) -> (PID, bool) {
	pid, ok := start_observer(NODE.config.observer_interval)
	if !ok {
		panic_at(
			NODE.config.loc,
			"node startup failed: the observer actor could not be spawned, disable it with enable_observer = false in make_node_config if it is not needed",
		)
	}
	return pid, ok
}

@(private)
observer_init :: proc(data: ^Observer_Data) {
	data^ = Observer_Data{}

	data.active_stats = make(map[PID]Actor_Stats)
	data.terminated_stats = make([dynamic]Actor_Stats)
	data.last_collection = now()
}

@(private)
handle_observer_message :: proc(data: ^Observer_Data, from: PID, msg: any) {
	switch m in msg {
	case Stats_Response:
		stats := m.stats
		stats.name = strings.clone(m.stats.name)

		if stats.terminated {
			if old_stats, ok := data.active_stats[stats.pid]; ok {
				free_actor_stats(&old_stats)
				delete_key(&data.active_stats, stats.pid)
			}
			append(&data.terminated_stats, stats)
		} else {
			if old_stats, ok := data.active_stats[stats.pid]; ok {
				free_actor_stats(&old_stats)
			}
			data.active_stats[stats.pid] = stats
		}
		data.total_actors_monitored = len(data.active_stats) + len(data.terminated_stats)

	case Set_Collection_Interval:
		if data.auto_collect do cancel_timer(data.collection_timer_id)
		data.collection_interval = m.interval
		data.auto_collect = m.interval > 0
		if data.auto_collect {
			data.next_collection = time.time_add(now(), m.interval)
			timer_id, timer_err := set_timer(m.interval, true)
			if timer_err != .OK {
				log.errorf(
					"observer: could not start the stats collection timer (%v), automatic stats collection is disabled, use trigger_stats_collection to collect manually",
					timer_err,
				)
			}
			data.collection_timer_id = timer_id
		}

	case Trigger_Collection:
		collect_all_stats(data)
		broadcast_stats_snapshot(data)

	case Get_All_Stats_Request:
		response := All_Stats_Response {
			active_stats     = data.active_stats,
			terminated_stats = data.terminated_stats[:],
		}
		requester := m.requester
		if requester == {} do requester = from
		_ = send_message(requester, response)

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
		requester := m.requester
		if requester == {} do requester = from
		_ = send_message(requester, response)

	case Clear_Terminated_Stats:
		for &stats in data.terminated_stats {
			free_actor_stats(&stats)
		}
		clear_dynamic_array(&data.terminated_stats)

	case Timer_Tick:
		if m.id == data.collection_timer_id && data.auto_collect {
			collect_all_stats(data)
			broadcast_stats_snapshot(data)
			data.last_collection = now()
		}
	}
}

@(private)
fill_snapshot_entry :: proc(entry: ^Actor_Stats_Entry, stats: Actor_Stats) {
	entry.pid = stats.pid
	entry.messages_received = stats.messages_received
	entry.messages_sent = stats.messages_sent
	entry.state = stats.state
	entry.terminated = stats.terminated
	entry.parent_pid = stats.parent_pid
	entry.name_len = u8(copy(entry.name[:], stats.name))
}

@(private)
broadcast_stats_snapshot :: proc(data: ^Observer_Data) {
	if get_subscriber_count(OBSERVER_TYPE) == 0 do return

	snapshot: Stats_Snapshot

	for pid, stats in data.active_stats {
		if snapshot.actor_count >= MAX_SNAPSHOT_ACTORS {
			log.warnf(
				"observer snapshot truncated: %d active actors exceed MAX_SNAPSHOT_ACTORS (%d), subscribers receive a partial snapshot",
				len(data.active_stats),
				MAX_SNAPSHOT_ACTORS,
			)
			break
		}

		fill_snapshot_entry(&snapshot.actors[snapshot.actor_count], stats)

		if stats.sent_to != nil {
			for to_pid, count in stats.sent_to {
				if snapshot.flow_count >= MAX_SNAPSHOT_FLOWS {
					log.warnf(
						"observer snapshot truncated: message flows exceed MAX_SNAPSHOT_FLOWS (%d), subscribers receive a partial flow list",
						MAX_SNAPSHOT_FLOWS,
					)
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
			log.warnf(
				"observer snapshot truncated: active plus terminated actors exceed MAX_SNAPSHOT_ACTORS (%d), %d terminated actors were omitted, subscribers receive a partial snapshot",
				MAX_SNAPSHOT_ACTORS,
				len(data.terminated_stats),
			)
			break
		}

		fill_snapshot_entry(&snapshot.actors[snapshot.actor_count], stats)

		snapshot.actor_count += 1
	}

	broadcast(snapshot)
}

@(private)
collect_all_stats :: proc(data: ^Observer_Data) {
	data.collection_count += 1
	data.last_collection = now()

	it := make_iter(&NODE.actor_registry)
	actor_count := 0
	for {
		_, pid, ok := iter(&it)
		if !ok do break

		actor := get(&NODE.actor_registry, pid)
		if actor == nil || pid == NODE.pid || pid == NODE.observer_pid do continue

		actor_count += 1


		msg := Get_Stats {
			requester = NODE.observer_pid,
		}

		_ = send_message(pid, msg)
	}


}

@(private)
free_actor_stats :: proc(stats: ^Actor_Stats) {
	if len(stats.name) > 0 do delete(stats.name)
	if stats.received_from != nil do delete(stats.received_from)
	if stats.sent_to != nil do delete(stats.sent_to)
}

@(private)
terminate_observer :: proc(data: ^Observer_Data) {
	for _, &stats in data.active_stats {
		free_actor_stats(&stats)
	}
	for &stats in data.terminated_stats {
		free_actor_stats(&stats)
	}
}


start_observer :: proc(
	collection_interval: time.Duration = 0,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	context.logger = diagnostic_logger(context.logger)
	if NODE.observer_pid != {} {
		log.warnf(
			"Observer already started with PID %v, this start_observer call had no effect and the existing observer was returned",
			NODE.observer_pid,
			location = loc,
		)
		return NODE.observer_pid, true
	}

	if OBSERVER_TYPE == ACTOR_TYPE_UNTYPED {
		observer_type, type_ok := register_actor_type("observer")
		if !type_ok {
			log.error(
				"start_observer: could not register the 'observer' actor type, the observer will run as ACTOR_TYPE_UNTYPED and every stats snapshot broadcast will be silently discarded",
				location = loc,
			)
		}
		OBSERVER_TYPE = observer_type
	}

	behaviour := Observer_Behaviour
	behaviour.actor_type = OBSERVER_TYPE

	observer_data := Observer_Data{}
	pid, ok := spawn(
		"observer",
		observer_data,
		behaviour,
		NODE.config.actor_config,
		parent_pid = NODE.pid,
	)
	if !ok {
		log.error(
			"start_observer failed: could not spawn the observer actor, no actor statistics will be collected",
			location = loc,
		)
		return PID{}, false
	}

	NODE.observer_pid = pid

	if collection_interval > 0 {
		_ = send_message(NODE.observer_pid, Set_Collection_Interval{interval = collection_interval})
	}

	return pid, ok
}

stop_observer :: proc() {
	if NODE.observer_pid != {} {
		a_ptr, ok := get(&NODE.actor_registry, NODE.observer_pid)
		if !ok do return

		a, actor_ok := get_actor_from_pointer(a_ptr, true)
		if actor_ok && a != nil {
			for i := 0; i < 100; i += 1 {
				if mpsc_size(&a.mailbox) == 0 do break
				runtime_sleep(10 * time.Millisecond)
			}
		} else {
			log.warnf(
				"stop_observer: observer PID %v is registered but its actor could not be resolved, terminating without draining its mailbox",
				NODE.observer_pid,
			)
		}

		_ = terminate_actor(NODE.observer_pid, .SHUTDOWN)
		for i := 0; i < 100; i += 1 {
			if _, active := get(&NODE.actor_registry, NODE.observer_pid); !active do break
			runtime_sleep(10 * time.Millisecond)
		}
		NODE.observer_pid = {}
	}
}

@(private)
log_observer_not_started :: proc(proc_name: string, loc: runtime.Source_Code_Location) {
	context.logger = diagnostic_logger(context.logger)
	log.errorf(
		"%s failed: the observer is not running, start it with start_observer",
		proc_name,
		location = loc,
	)
}

@(private)
log_observer_send_failed :: proc(
	proc_name: string,
	err: Send_Error,
	loc: runtime.Source_Code_Location,
) {
	context.logger = diagnostic_logger(context.logger)
	log.errorf(
		"%s failed: could not reach the observer actor (PID %v): %v",
		proc_name,
		NODE.observer_pid,
		err,
		location = loc,
	)
}

@(private)
observer_request :: proc(msg: $T, proc_name: string, loc: runtime.Source_Code_Location) -> bool {
	if NODE.observer_pid == {} {
		log_observer_not_started(proc_name, loc)
		return false
	}
	err := send_message(NODE.observer_pid, msg)
	if err != .OK do log_observer_send_failed(proc_name, err, loc)
	return err == .OK
}

trigger_stats_collection :: proc(loc := #caller_location) -> bool {
	return observer_request(Trigger_Collection{}, "trigger_stats_collection", loc)
}

@(require_results)
subscribe_to_stats :: proc(loc := #caller_location) -> (Subscription, bool) {
	if OBSERVER_TYPE == ACTOR_TYPE_UNTYPED {
		log_observer_not_started("subscribe_to_stats", loc)
		return {}, false
	}
	return subscribe_type(OBSERVER_TYPE, loc)
}
