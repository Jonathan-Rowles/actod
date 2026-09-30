package integration

import "../actod"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

PRUNE_WARNING_TEXT :: "has no spawn function to restart it from"
PRUNE_RECORD_CAP :: 16
PRUNE_EVENT_CAP :: 64

Prune_Termination :: struct {
	pid:          actod.PID,
	reason:       actod.Termination_Reason,
	will_restart: bool,
	name_len:     int,
	name_buf:     [64]u8,
}

Prune_Event_Kind :: enum {
	Terminated,
	Restarted,
	Started,
}

Prune_Event :: struct {
	kind: Prune_Event_Kind,
	pid:  actod.PID,
}

@(private = "file")
g_prune_events: [PRUNE_EVENT_CAP]Prune_Event

@(private = "file")
g_prune_event_count: int

@(private = "file")
g_prune_terminations: [PRUNE_RECORD_CAP]Prune_Termination

@(private = "file")
g_prune_termination_count: int

@(private = "file")
g_prune_restarted_old: [PRUNE_RECORD_CAP]actod.PID

@(private = "file")
g_prune_restart_count: int

@(private = "file")
g_prune_warnings: i32

@(private = "file")
g_prune_other_warnings: i32

@(private = "file")
g_prune_errors: i32

@(private = "file")
record_prune_event :: proc(kind: Prune_Event_Kind, pid: actod.PID) {
	index := sync.atomic_load(&g_prune_event_count)
	if index >= PRUNE_EVENT_CAP do return
	g_prune_events[index] = Prune_Event{kind, pid}
	sync.atomic_store(&g_prune_event_count, index + 1)
}

@(private = "file")
reset_prune_state :: proc() {
	reset_test_state()
	sync.atomic_store(&g_prune_event_count, 0)
	sync.atomic_store(&g_prune_termination_count, 0)
	sync.atomic_store(&g_prune_restart_count, 0)
	sync.atomic_store(&g_prune_warnings, 0)
	sync.atomic_store(&g_prune_other_warnings, 0)
	sync.atomic_store(&g_prune_errors, 0)
}

count_prune_supervisor_log :: proc(level: log.Level, text: string, location: runtime.Source_Code_Location) {
	switch {
	case level >= .Error:
		sync.atomic_add(&g_prune_errors, 1)
	case level == .Warning && strings.contains(text, PRUNE_WARNING_TEXT):
		sync.atomic_add(&g_prune_warnings, 1)
	case level == .Warning:
		sync.atomic_add(&g_prune_other_warnings, 1)
	}
}

Prune_Supervisor_Data :: struct {
	direct_spawned: int,
}

Prune_Supervisor_Behaviour :: actod.Actor_Behaviour(Prune_Supervisor_Data) {
	handle_message = proc(data: ^Prune_Supervisor_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case string:
			if m == "spawn_direct" {
				data.direct_spawned += 1
				_, _ = actod.spawn_child(
					fmt.tprintf("direct-%d", data.direct_spawned),
					Crash_Test_Data{crash_on_msg = "crash", crash_reason = .ABNORMAL},
					Crash_Test_Behaviour,
					actod.make_actor_config(restart_policy = .PERMANENT),
				)
			}
		}
	},
	on_child_terminated = proc(
		data: ^Prune_Supervisor_Data,
		child_pid: actod.PID,
		child_name: string,
		reason: actod.Termination_Reason,
		will_restart: bool,
	) {
		record_prune_event(.Terminated, child_pid)
		index := sync.atomic_load(&g_prune_termination_count)
		if index >= PRUNE_RECORD_CAP do return
		record := &g_prune_terminations[index]
		record.pid = child_pid
		record.reason = reason
		record.will_restart = will_restart
		record.name_len = copy(record.name_buf[:], child_name)
		sync.atomic_store(&g_prune_termination_count, index + 1)
	},
	on_child_restarted = proc(
		data: ^Prune_Supervisor_Data,
		old_pid: actod.PID,
		new_pid: actod.PID,
		restart_count: int,
	) {
		record_prune_event(.Restarted, old_pid)
		index := sync.atomic_load(&g_prune_restart_count)
		if index >= PRUNE_RECORD_CAP do return
		g_prune_restarted_old[index] = old_pid
		sync.atomic_store(&g_prune_restart_count, index + 1)
	},
	on_child_started = proc(data: ^Prune_Supervisor_Data, child_pid: actod.PID) {
		record_prune_event(.Started, child_pid)
	},
}

spawn_prune_declared :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	id := int(sync.atomic_add(&global_test_state.actors_spawned, 1))
	return actod.spawn(
		fmt.tprintf("prune-declared-%d", id),
		Crash_Test_Data{id = id, crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .PERMANENT),
		parent,
	)
}

@(private = "file")
spawn_prune_supervisor :: proc(
	name: string,
	strategy: actod.Supervision_Strategy,
	declared_count: int,
) -> (
	actod.PID,
	bool,
) {
	declared := make([dynamic]actod.SPAWN)
	defer delete(declared)
	for _ in 0 ..< declared_count do append(&declared, spawn_prune_declared)
	return actod.spawn(
		name,
		Prune_Supervisor_Data{},
		Prune_Supervisor_Behaviour,
		actod.make_actor_config(
			supervision_strategy = strategy,
			children = declared,
			logging = actod.make_log_config(level = .Warning, custom_logger = count_prune_supervisor_log),
		),
	)
}

@(private = "file")
Prune_Wait :: struct {
	parent:       actod.PID,
	table_len:    int,
	terminations: int,
	restarts:     int,
}

@(private = "file")
prune_settled :: proc(state: rawptr) -> bool {
	wait := cast(^Prune_Wait)state
	children := actod.get_children(wait.parent)
	defer delete(children)
	if len(children) != wait.table_len do return false
	if sync.atomic_load(&g_prune_termination_count) < wait.terminations do return false
	return sync.atomic_load(&g_prune_restart_count) >= wait.restarts
}

@(private = "file")
Expected_Termination :: struct {
	pid:          actod.PID,
	name:         string,
	reason:       actod.Termination_Reason,
	will_restart: bool,
}

@(private = "file")
expect_terminations :: proc(t: ^testing.T, step: string, expected: []Expected_Termination) {
	count := sync.atomic_load(&g_prune_termination_count)
	if !expectf(t, count == len(expected), "%s: on_child_terminated fired %d times, expected %d", step, count, len(expected)) {
		for i in 0 ..< min(count, PRUNE_RECORD_CAP) {
			record := g_prune_terminations[i]
			fmt.eprintfln("%s: callback %d: pid %v name %q reason %v will_restart %v", step, i, record.pid, string(record.name_buf[:record.name_len]), record.reason, record.will_restart)
		}
		return
	}
	for want, i in expected {
		record := g_prune_terminations[i]
		name := string(record.name_buf[:record.name_len])
		expectf(
			t,
			record.pid == want.pid && name == want.name && record.reason == want.reason && record.will_restart == want.will_restart,
			"%s: callback %d was (%v, %q, %v, %v), expected (%v, %q, %v, %v)",
			step,
			i,
			record.pid,
			name,
			record.reason,
			record.will_restart,
			want.pid,
			want.name,
			want.reason,
			want.will_restart,
		)
	}
}

@(private = "file")
expect_restarted_in_order :: proc(t: ^testing.T, step: string, expected_old: []actod.PID) {
	count := sync.atomic_load(&g_prune_restart_count)
	restarted := g_prune_restarted_old[:min(count, PRUNE_RECORD_CAP)]
	expectf(t, slice.equal(restarted, expected_old), "%s: restarted %v in that order, expected %v", step, restarted, expected_old)
}

@(private = "file")
find_termination_event :: proc(events: []Prune_Event, pid: actod.PID) -> int {
	for event, i in events {
		if event.kind == .Terminated && event.pid == pid do return i
	}
	return -1
}

@(private = "file")
expect_pruned_before_any_restart :: proc(t: ^testing.T, step: string, dying: actod.PID, pruned: []actod.PID) {
	events := g_prune_events[:min(sync.atomic_load(&g_prune_event_count), PRUNE_EVENT_CAP)]
	crash_index := find_termination_event(events, dying)
	if !expectf(t, crash_index != -1, "%s: no on_child_terminated for the dying child %v in %v", step, dying, events) do return
	first_restart := len(events)
	for event, i in events[crash_index:] {
		if event.kind != .Terminated {
			first_restart = crash_index + i
			break
		}
	}
	for pid in pruned {
		pruned_index := find_termination_event(events, pid)
		expectf(
			t,
			pruned_index != -1 && pruned_index < first_restart,
			"%s: on_child_terminated for pruned %v must come before the first restart, events %v",
			step,
			pid,
			events,
		)
	}
}

@(private = "file")
expect_prune_logs :: proc(t: ^testing.T, step: string, prune_warnings: i32) {
	expectf(t, sync.atomic_load(&g_prune_warnings) == prune_warnings, "%s: %d removal warnings, expected %d", step, sync.atomic_load(&g_prune_warnings), prune_warnings)
	expectf(t, sync.atomic_load(&g_prune_other_warnings) == 0, "%s: %d other warnings from the supervisor", step, sync.atomic_load(&g_prune_other_warnings))
	expectf(t, sync.atomic_load(&g_prune_errors) == 0, "%s: %d errors from the supervisor", step, sync.atomic_load(&g_prune_errors))
}

@(private = "file")
expect_all_alive :: proc(t: ^testing.T, step: string, pids: []actod.PID) {
	for pid in pids {
		expectf(t, actod.valid(&actod.NODE.actor_registry, pid), "%s: %v must be alive", step, pid)
	}
}

@(private = "file")
stop_prune_supervisor :: proc(t: ^testing.T, supervisor_pid: actod.PID) {
	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	expect(t, wait_for_actor_invalid(supervisor_pid, 2000), "supervisor should stop")
}

@(private = "file")
spawn_direct_under :: proc(t: ^testing.T, supervisor_pid: actod.PID, expected_len: int) -> actod.PID {
	_ = actod.send_message(supervisor_pid, "spawn_direct")
	if !expect(t, wait_for_child_count(supervisor_pid, expected_len, 2000), "the direct child should register") do return 0
	children := actod.get_children(supervisor_pid)
	defer delete(children)
	return children[expected_len - 1]
}

@(private = "file")
add_child_under :: proc(
	t: ^testing.T,
	supervisor_pid: actod.PID,
	expected_len: int,
	child_spawn: actod.SPAWN = spawn_prune_declared,
) -> actod.PID {
	expect(t, actod.add_child(supervisor_pid, child_spawn), "add_child should succeed")
	if !expect(t, wait_for_child_count(supervisor_pid, expected_len, 2000), "the added child should register") do return 0
	children := actod.get_children(supervisor_pid)
	defer delete(children)
	return children[expected_len - 1]
}

@(private = "file")
permanent_direct_child_dies_and_is_pruned :: proc(t: ^testing.T, strategy: actod.Supervision_Strategy) {
	reset_prune_state()
	step := fmt.tprintf("%v", strategy)

	supervisor_pid, ok := spawn_prune_supervisor(fmt.tprintf("prune-direct-%v", strategy), strategy, 2)
	if !expectf(t, ok, "%s: spawn supervisor", step) do return
	if !expectf(t, wait_for_child_count(supervisor_pid, 2, 2000), "%s: declared children should start", step) do return
	declared := actod.get_children(supervisor_pid)
	defer delete(declared)

	direct := spawn_direct_under(t, supervisor_pid, 3)
	added_after := add_child_under(t, supervisor_pid, 4)
	if direct == 0 || added_after == 0 {
		stop_prune_supervisor(t, supervisor_pid)
		return
	}
	siblings := []actod.PID{declared[0], declared[1], added_after}

	_ = actod.send_message(direct, "crash")

	wait := Prune_Wait{parent = supervisor_pid, table_len = 3, terminations = 1}
	settled := poll_until(prune_settled, &wait, 3 * time.Second)
	after := actod.get_children(supervisor_pid)
	defer delete(after)
	if !expectf(t, settled, "%s: the dead direct child must leave the table, got %v", step, after) {
		stop_prune_supervisor(t, supervisor_pid)
		return
	}

	expectf(t, slice.equal(after, siblings), "%s: no sibling may be stopped or restarted, table %v, expected %v", step, after, siblings)
	expect_restarted_in_order(t, step, nil)
	expect_all_alive(t, step, siblings)
	expect(t, wait_for_actor_invalid(direct, 2000), "the direct child must be gone")
	expect_terminations(t, step, []Expected_Termination{{direct, "direct-1", .ABNORMAL, false}})
	expect_prune_logs(t, step, 1)

	stop_prune_supervisor(t, supervisor_pid)
}

test_permanent_direct_child_is_pruned_under_every_strategy :: proc(t: ^testing.T) {
	strategies := []actod.Supervision_Strategy{.ONE_FOR_ONE, .ONE_FOR_ALL, .REST_FOR_ONE}
	for strategy in strategies do permanent_direct_child_dies_and_is_pruned(t, strategy)
}

@(private = "file")
strategy_prunes_direct_siblings :: proc(t: ^testing.T, strategy: actod.Supervision_Strategy) {
	reset_prune_state()
	step := fmt.tprintf("%v", strategy)

	supervisor_pid, ok := spawn_prune_supervisor(fmt.tprintf("prune-mixed-%v", strategy), strategy, 1)
	if !expectf(t, ok, "%s: spawn supervisor", step) do return
	if !expectf(t, wait_for_child_count(supervisor_pid, 1, 2000), "%s: the declared child should start", step) do return
	first := actod.get_children(supervisor_pid)
	declared := first[0]
	delete(first)

	direct_before := spawn_direct_under(t, supervisor_pid, 2)
	added_dying := add_child_under(t, supervisor_pid, 3)
	direct_after := spawn_direct_under(t, supervisor_pid, 4)
	added_last := add_child_under(t, supervisor_pid, 5)
	temporary := add_child_under(t, supervisor_pid, 6, spawn_temporary_policy_child)
	transient := add_child_under(t, supervisor_pid, 7, spawn_transient_policy_child)
	if direct_before == 0 || added_dying == 0 || direct_after == 0 || added_last == 0 || temporary == 0 || transient == 0 {
		stop_prune_supervisor(t, supervisor_pid)
		return
	}
	initial := []actod.PID{declared, direct_before, added_dying, direct_after, added_last, temporary, transient}
	expect_live_children(t, supervisor_pid, initial, fmt.tprintf("%s: before the crash", step))
	dying_name := strings.clone(actod.get_actor_name(added_dying))
	defer delete(dying_name)
	temporary_name := strings.clone(actod.get_actor_name(temporary))
	defer delete(temporary_name)

	_ = actod.send_message(added_dying, "crash")

	wait := Prune_Wait{parent = supervisor_pid}
	expected_terminations: []Expected_Termination
	expected_restarts: []actod.PID
	pruned: []actod.PID
	prune_warnings: i32
	#partial switch strategy {
	case .ONE_FOR_ALL:
		wait = Prune_Wait{parent = supervisor_pid, table_len = 4, terminations = 4, restarts = 4}
		expected_terminations = []Expected_Termination {
			{added_dying, dying_name, .ABNORMAL, true},
			{direct_before, "direct-1", .KILLED, false},
			{direct_after, "direct-2", .KILLED, false},
			{temporary, temporary_name, .KILLED, false},
		}
		expected_restarts = []actod.PID{declared, added_dying, added_last, transient}
		pruned = []actod.PID{direct_before, direct_after, temporary}
		prune_warnings = 2
	case .REST_FOR_ONE:
		wait = Prune_Wait{parent = supervisor_pid, table_len = 5, terminations = 3, restarts = 3}
		expected_terminations = []Expected_Termination {
			{added_dying, dying_name, .ABNORMAL, true},
			{direct_after, "direct-2", .KILLED, false},
			{temporary, temporary_name, .KILLED, false},
		}
		expected_restarts = []actod.PID{added_dying, added_last, transient}
		pruned = []actod.PID{direct_after, temporary}
		prune_warnings = 1
	case:
		expect(t, false, "strategy_prunes_direct_siblings covers ONE_FOR_ALL and REST_FOR_ONE only")
		return
	}

	settled := poll_until(prune_settled, &wait, 3 * time.Second)
	after := actod.get_children(supervisor_pid)
	defer delete(after)
	if !expectf(t, settled, "%s: the strategy must settle, got table %v", step, after) {
		expect_terminations(t, step, expected_terminations)
		stop_prune_supervisor(t, supervisor_pid)
		return
	}

	expect_terminations(t, step, expected_terminations)
	expect_restarted_in_order(t, step, expected_restarts)
	expect_pruned_before_any_restart(t, step, added_dying, pruned)
	expect_prune_logs(t, step, prune_warnings)
	expect(t, wait_for_actor_invalid(direct_after, 2000), "the direct child after the dying one must be gone")
	expect(t, wait_for_actor_invalid(temporary, 2000), "the TEMPORARY sibling must be stopped and stay down")
	expect_all_alive(t, step, after[:])

	if strategy == .ONE_FOR_ALL {
		expect(t, wait_for_actor_invalid(direct_before, 2000), "ONE_FOR_ALL must stop the direct child before the dying one")
		expectf(
			t,
			after[0] != declared && after[1] != added_dying && after[2] != added_last && after[3] != transient,
			"%s: every slot must hold a restarted child in declared, added, added, TRANSIENT order, got %v",
			step,
			after,
		)
	} else {
		expectf(t, after[0] == declared && after[1] == direct_before, "%s: children before the dying one are untouched, got %v", step, after)
		expectf(
			t,
			after[2] != added_dying && after[3] != added_last && after[4] != transient,
			"%s: the dying child and the PERMANENT and TRANSIENT siblings after it restart in their slots, got %v",
			step,
			after,
		)
	}

	stop_prune_supervisor(t, supervisor_pid)
}

test_one_for_all_prunes_direct_siblings :: proc(t: ^testing.T) {
	strategy_prunes_direct_siblings(t, .ONE_FOR_ALL)
}

test_rest_for_one_prunes_direct_siblings_in_range :: proc(t: ^testing.T) {
	strategy_prunes_direct_siblings(t, .REST_FOR_ONE)
}

test_shut_down_children_leave_the_table_and_stay_down :: proc(t: ^testing.T) {
	reset_prune_state()
	step := "shut down ONE_FOR_ALL"

	supervisor_pid, ok := spawn_prune_supervisor("prune-shutdown-one-for-all", .ONE_FOR_ALL, 1)
	if !expect(t, ok, "spawn supervisor") do return
	if !expect(t, wait_for_child_count(supervisor_pid, 1, 2000), "the declared child should start") do return
	first := actod.get_children(supervisor_pid)
	declared := first[0]
	delete(first)
	declared_name := strings.clone(actod.get_actor_name(declared))
	defer delete(declared_name)

	temporary := add_child_under(t, supervisor_pid, 2, spawn_temporary_policy_child)
	permanent := add_child_under(t, supervisor_pid, 3, spawn_permanent_policy_child)
	if temporary == 0 || permanent == 0 {
		stop_prune_supervisor(t, supervisor_pid)
		return
	}
	temporary_name := strings.clone(actod.get_actor_name(temporary))
	defer delete(temporary_name)
	permanent_name := strings.clone(actod.get_actor_name(permanent))
	defer delete(permanent_name)

	expect(t, actod.terminate_actor(temporary), "terminate the TEMPORARY child")
	wait := Prune_Wait{parent = supervisor_pid, table_len = 2, terminations = 1}
	expectf(t, poll_until(prune_settled, &wait, 3 * time.Second), "%s: the shut-down TEMPORARY child must leave the table", step)

	expect(t, actod.terminate_actor(permanent), "terminate the PERMANENT child")
	wait = Prune_Wait{parent = supervisor_pid, table_len = 1, terminations = 2}
	expectf(t, poll_until(prune_settled, &wait, 3 * time.Second), "%s: the shut-down PERMANENT child must leave the table", step)

	shut_down := actod.get_children(supervisor_pid)
	expectf(t, slice.equal(shut_down, []actod.PID{declared}), "%s: only the declared child may remain, table %v", step, shut_down)
	delete(shut_down)
	expect(t, wait_for_actor_invalid(temporary, 2000), "the TEMPORARY child must be gone")
	expect(t, wait_for_actor_invalid(permanent, 2000), "the PERMANENT child must be gone")
	expect_restarted_in_order(t, fmt.tprintf("%s: after the shutdowns", step), nil)

	_ = actod.send_message(declared, "crash")
	wait = Prune_Wait{parent = supervisor_pid, table_len = 1, terminations = 3, restarts = 1}
	settled := poll_until(prune_settled, &wait, 3 * time.Second)
	after := actod.get_children(supervisor_pid)
	defer delete(after)
	expectf(t, settled, "%s: the group restart must settle, got table %v", step, after)

	expect_terminations(
		t,
		step,
		[]Expected_Termination {
			{temporary, temporary_name, .SHUTDOWN, false},
			{permanent, permanent_name, .SHUTDOWN, false},
			{declared, declared_name, .ABNORMAL, true},
		},
	)
	expect_restarted_in_order(t, step, []actod.PID{declared})
	if expectf(t, len(after) == 1, "%s: the shut-down children must stay down, table %v", step, after) {
		expectf(t, after[0] != declared, "%s: the declared child must restart, got %v", step, after)
		expect_all_alive(t, step, after[:])
	}
	expect_prune_logs(t, step, 0)

	stop_prune_supervisor(t, supervisor_pid)
}
