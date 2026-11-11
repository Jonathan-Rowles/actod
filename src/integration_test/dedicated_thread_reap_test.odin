package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

DEDICATED_REAP_ACTOR_NAME :: "dedicated-reap-init-stop"
DEDICATED_REAP_BUDGET :: 2 * time.Second
DEDICATED_REAP_RECORD_CAPACITY :: 64

Dedicated_Reap_Record :: struct {
	pid:          actod.PID,
	joins_thread: bool,
	recorded:     bool,
}

Dedicated_Thread_Start :: struct {
	pid:        actod.PID,
	had_handle: bool,
	recorded:   bool,
}

Held_Dedicated_Spawner :: struct {
	pid:          actod.PID,
	reached:      bool,
	reaped:       bool,
	joins_thread: bool,
}

dedicated_reap_records: [DEDICATED_REAP_RECORD_CAPACITY]Dedicated_Reap_Record
dedicated_reap_record_count: int
held_dedicated_spawner: Held_Dedicated_Spawner
dedicated_thread_starts: [DEDICATED_REAP_RECORD_CAPACITY]Dedicated_Thread_Start
dedicated_thread_start_count: int

Dedicated_Init_Stop_Actor :: struct {}

dedicated_init_stop_actor_init :: proc(data: ^Dedicated_Init_Stop_Actor) {
	_ = actod.self_terminate()
}

dedicated_init_stop_actor_handle :: proc(
	data: ^Dedicated_Init_Stop_Actor,
	from: actod.PID,
	msg: any,
) {}

Dedicated_Init_Stop_Actor_Behaviour :: actod.Actor_Behaviour(
	Dedicated_Init_Stop_Actor,
) {
	init           = dedicated_init_stop_actor_init,
	handle_message = dedicated_init_stop_actor_handle,
}

record_dedicated_thread_reap :: proc(pid: actod.PID, joins_thread: bool) {
	slot := sync.atomic_add(&dedicated_reap_record_count, 1)
	if slot >= DEDICATED_REAP_RECORD_CAPACITY do return
	record := &dedicated_reap_records[slot]
	record.pid = pid
	record.joins_thread = joins_thread
	sync.atomic_store(&record.recorded, true)
}

find_dedicated_thread_reap :: proc(
	pid: actod.PID,
) -> (
	record: Dedicated_Reap_Record,
	found: bool,
) {
	for &candidate in dedicated_reap_records {
		if !sync.atomic_load(&candidate.recorded) do continue
		if candidate.pid == pid do return candidate, true
	}
	return {}, false
}

record_dedicated_thread_start :: proc(
	pid: actod.PID,
	stored_thread: ^thread.Thread,
) {
	slot := sync.atomic_add(&dedicated_thread_start_count, 1)
	if slot >= DEDICATED_REAP_RECORD_CAPACITY do return
	record := &dedicated_thread_starts[slot]
	record.pid = pid
	record.had_handle = stored_thread != nil
	sync.atomic_store(&record.recorded, true)
}

find_dedicated_thread_start :: proc(
	pid: actod.PID,
) -> (
	record: Dedicated_Thread_Start,
	found: bool,
) {
	for &candidate in dedicated_thread_starts {
		if !sync.atomic_load(&candidate.recorded) do continue
		if candidate.pid == pid do return candidate, true
	}
	return {}, false
}

held_dedicated_actor_reaped :: proc(state: rawptr) -> bool {
	_, found := find_dedicated_thread_reap(
		(cast(^Held_Dedicated_Spawner)state).pid,
	)
	return found
}

hold_spawner_until_dedicated_actor_reaped :: proc(
	pid: actod.PID,
	name: string,
) {
	if name != DEDICATED_REAP_ACTOR_NAME do return
	held := &held_dedicated_spawner
	held.pid = pid
	held.reached = true
	held.reaped = poll_until(
		held_dedicated_actor_reaped,
		held,
		DEDICATED_REAP_BUDGET,
		time.Millisecond,
	)
	record, _ := find_dedicated_thread_reap(pid)
	held.joins_thread = record.joins_thread
}

test_dedicated_thread_stopped_in_init_is_joined :: proc(t: ^testing.T) {
	dedicated_reap_records = {}
	dedicated_reap_record_count = 0
	held_dedicated_spawner = {}
	dedicated_thread_starts = {}
	dedicated_thread_start_count = 0
	actod.dedicated_thread_starting_hook = record_dedicated_thread_start
	actod.dedicated_thread_reap_hook = record_dedicated_thread_reap
	actod.dedicated_thread_started_hook =
		hold_spawner_until_dedicated_actor_reaped
	defer {
		actod.dedicated_thread_started_hook = nil
		actod.dedicated_thread_reap_hook = nil
		actod.dedicated_thread_starting_hook = nil
	}

	pid, spawned := actod.spawn(
		DEDICATED_REAP_ACTOR_NAME,
		Dedicated_Init_Stop_Actor{},
		Dedicated_Init_Stop_Actor_Behaviour,
		actod.make_actor_config(
			logging = actod.make_log_config(level = test_log_level()),
			restart_policy = .TEMPORARY,
			use_dedicated_os_thread = true,
		),
	)

	expect(
		t,
		spawned,
		"spawn reports success once init has run, even when init stopped the actor",
	)
	expect(
		t,
		held_dedicated_spawner.reached,
		"the spawner must pass the hook after starting the dedicated thread",
	)
	expectf(
		t,
		pid == held_dedicated_spawner.pid,
		"spawn returned %v, the held spawner saw %v",
		pid,
		held_dedicated_spawner.pid,
	)
	start, start_recorded := find_dedicated_thread_start(pid)
	expect(
		t,
		start_recorded,
		"the spawner must pass the hook before starting the dedicated thread",
	)
	expectf(
		t,
		start.had_handle,
		"the dedicated thread of %v was started before its handle was stored, so an actor stopping in init could be reaped unjoined",
		pid,
	)
	expect(
		t,
		held_dedicated_spawner.reaped,
		"the node must reap the actor that stopped in init while the spawner is held",
	)
	expectf(
		t,
		held_dedicated_spawner.joins_thread,
		"the node reaped %v with no thread handle, so its dedicated thread was never joined before the header was retired",
		held_dedicated_spawner.pid,
	)
}
