package integration

import "../actod"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

Sibling_Supervisor_Data :: struct {
	direct_spawned: int,
}

@(private = "file")
g_sibling_restarts: i32

Sibling_Supervisor_Behaviour :: actod.Actor_Behaviour(Sibling_Supervisor_Data) {
	handle_message = sibling_supervisor_handle_message,
	on_child_restarted = proc(
		data: ^Sibling_Supervisor_Data,
		old_pid: actod.PID,
		new_pid: actod.PID,
		restart_count: int,
	) {
		sync.atomic_add(&g_sibling_restarts, 1)
	},
}

sibling_supervisor_handle_message :: proc(data: ^Sibling_Supervisor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case string:
		if m == "spawn_direct" {
			data.direct_spawned += 1
			_, _ = actod.spawn_child(
				fmt.tprintf("direct-%d", data.direct_spawned),
				Crash_Test_Data{crash_on_msg = "done", crash_reason = .NORMAL},
				Crash_Test_Behaviour,
				actod.make_actor_config(restart_policy = .TEMPORARY),
			)
		}
	}
}

@(private = "file")
g_helper_restarts: i32

@(private = "file")
g_helper_first_child: actod.PID

Helper_Supervisor_Data :: struct {}

Helper_Supervisor_Behaviour :: actod.Actor_Behaviour(Helper_Supervisor_Data) {
	handle_message = proc(data: ^Helper_Supervisor_Data, from: actod.PID, msg: any) {},
	on_child_restarted = proc(
		data: ^Helper_Supervisor_Data,
		old_pid: actod.PID,
		new_pid: actod.PID,
		restart_count: int,
	) {
		sync.atomic_add(&g_helper_restarts, 1)
	},
}

spawn_child_then_helper :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	id := int(sync.atomic_add(&global_test_state.actors_spawned, 1))
	child, ok := actod.spawn(
		fmt.tprintf("helper-owner-%d", id),
		Crash_Test_Data{id = id, crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .PERMANENT),
		parent,
	)
	if !ok do return 0, false
	_, _ = actod.spawn(
		fmt.tprintf("helper-%d", id),
		Crash_Test_Data{id = id},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
		parent,
	)
	sync.atomic_store(&g_helper_first_child, child)
	return child, true
}

declared_child_restarts_after_spawning_a_helper :: proc(
	t: ^testing.T,
	strategy: actod.Supervision_Strategy,
) {
	reset_test_state()
	sync.atomic_store(&g_helper_restarts, 0)

	children := make([dynamic]actod.SPAWN)
	defer delete(children)
	append(&children, spawn_child_then_helper)
	supervisor_pid, ok := actod.spawn(
		fmt.tprintf("helper-supervisor-%v", strategy),
		Helper_Supervisor_Data{},
		Helper_Supervisor_Behaviour,
		actod.make_actor_config(supervision_strategy = strategy, children = children),
	)
	expectf(t, ok, "%v: spawn supervisor", strategy)
	if !ok do return
	expectf(t, wait_for_child_count(supervisor_pid, 2, 1000), "%v: the child and its helper register", strategy)

	child := sync.atomic_load(&g_helper_first_child)
	before := actod.get_children(supervisor_pid)
	defer delete(before)
	expectf(t, len(before) == 2 && before[0] == child, "%v: the declared child is first", strategy)

	_ = actod.send_message(child, "crash")

	new_child, restarted := wait_for_child_pid_change(supervisor_pid, child, 0, 2000)
	expectf(t, restarted, "%v: the crashed declared child must restart", strategy)
	if restarted {
		expectf(
			t,
			new_child == sync.atomic_load(&g_helper_first_child),
			"%v: the restarted slot must hold the pid the spawn function returned",
			strategy,
		)
		expectf(t, actod.valid(&actod.NODE.actor_registry, new_child), "%v: the restarted child is alive", strategy)
		after := actod.get_children(supervisor_pid)
		defer delete(after)
		if strategy == .REST_FOR_ONE {
			expectf(
				t,
				len(after) == 2 && after[0] == new_child && after[1] != before[1],
				"%v: expected the restarted child in its slot, then the new helper, with the stopped first helper removed, got %v",
				strategy,
				after,
			)
		} else {
			expectf(
				t,
				len(after) == 3 && after[0] == new_child && after[1] == before[1],
				"%v: expected the restarted child in its slot, the first helper, then the new helper, got %v",
				strategy,
				after,
			)
		}
	}
	expectf(t, actod.valid(&actod.NODE.actor_registry, supervisor_pid), "%v: supervisor must survive", strategy)
	expect_value(t, sync.atomic_load(&g_helper_restarts), 1)

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	expectf(t, wait_for_actor_invalid(supervisor_pid, 1000), "%v: supervisor should stop", strategy)
}

test_declared_child_spawning_a_helper_restarts_one_for_one :: proc(t: ^testing.T) {
	declared_child_restarts_after_spawning_a_helper(t, .ONE_FOR_ONE)
}

test_declared_child_spawning_a_helper_restarts_rest_for_one :: proc(t: ^testing.T) {
	declared_child_restarts_after_spawning_a_helper(t, .REST_FOR_ONE)
}

spawn_life_child :: proc(prefix: string) -> (actod.PID, bool) {
	id := int(sync.atomic_add(&global_test_state.actors_spawned, 1))
	return actod.spawn_child(
		fmt.tprintf("%s-%d", prefix, id),
		Crash_Test_Data{id = id, crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .PERMANENT),
	)
}

spawn_life_first :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_life_child("life-first")
}

spawn_life_second :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_life_child("life-second")
}

spawn_life_added :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_life_child("life-added")
}

spawn_life_adopted :: proc(_name: string, _parent_pid: actod.PID) -> (actod.PID, bool) {
	return spawn_life_child("life-adopted")
}

Children_Equal_Probe :: struct {
	parent:   actod.PID,
	expected: []actod.PID,
}

children_equal :: proc(state: rawptr) -> bool {
	probe := cast(^Children_Equal_Probe)state
	children := actod.get_children(probe.parent)
	defer delete(children)
	return slice.equal(children, probe.expected)
}

expect_live_children :: proc(t: ^testing.T, parent: actod.PID, expected: []actod.PID, step: string) {
	probe := Children_Equal_Probe{parent = parent, expected = expected}
	matched := poll_until(children_equal, &probe, time.Second)
	if !matched {
		children := actod.get_children(parent)
		defer delete(children)
		expectf(t, false, "%s: get_children is %v, expected %v", step, children, expected)
		return
	}
	for pid in expected {
		expectf(t, actod.valid(&actod.NODE.actor_registry, pid), "%s: child %v is not alive", step, pid)
	}
}

Adoption_Probe :: struct {
	child:  actod.PID,
	parent: actod.PID,
}

adopted_parent_set :: proc(state: rawptr) -> bool {
	probe := cast(^Adoption_Probe)state
	child := cast(^actod.Actor)actod.get(&actod.NODE.actor_registry, probe.child)
	if child == nil do return false
	return sync.atomic_load(&child.parent) == probe.parent
}

crash_and_expect_restart :: proc(
	t: ^testing.T,
	supervisor_pid: actod.PID,
	live: ^[dynamic]actod.PID,
	index: int,
	prefix: string,
	step: string,
) {
	restarts_before := sync.atomic_load(&g_sibling_restarts)
	_ = actod.send_message(live[index], "crash")
	new_pid, restarted := wait_for_child_restart(supervisor_pid, live[:], index, 2000)
	if !expectf(t, restarted, "%s: child %d must restart in its slot", step, index) do return
	name := actod.get_actor_name(new_pid)
	expectf(t, strings.has_prefix(name, prefix), "%s: restart ran the wrong spawn function, got %q", step, name)
	expectf(
		t,
		sync.atomic_load(&g_sibling_restarts) == restarts_before + 1,
		"%s: exactly one restart expected",
		step,
	)
	live[index] = new_pid
	expect_live_children(t, supervisor_pid, live[:], step)
}

test_supervisor_child_table_through_a_mixed_life :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&g_sibling_restarts, 0)

	declared := actod.make_children(spawn_life_first, spawn_life_second)
	defer delete(declared)

	supervisor_pid, ok := actod.spawn(
		"mixed-life-supervisor",
		Sibling_Supervisor_Data{},
		Sibling_Supervisor_Behaviour,
		actod.make_actor_config(supervision_strategy = .ONE_FOR_ONE, children = declared),
	)
	expect(t, ok, "Failed to spawn supervisor")
	if !ok do return

	expect(t, wait_for_child_count(supervisor_pid, 2, 1000), "declared children should start")
	initial := actod.get_children(supervisor_pid)
	live := make([dynamic]actod.PID)
	defer delete(live)
	append(&live, ..initial)
	delete(initial)
	if !expectf(t, len(live) == 2, "expected 2 declared children, got %d", len(live)) do return

	_ = actod.send_message(supervisor_pid, "spawn_direct")
	expect(t, wait_for_child_count(supervisor_pid, 3, 1000), "the direct child should register")
	with_direct := actod.get_children(supervisor_pid)
	direct_pid := with_direct[2] if len(with_direct) == 3 else 0
	delete(with_direct)
	append(&live, direct_pid)
	expect_live_children(t, supervisor_pid, live[:], "after the direct child")

	expect(t, actod.add_child(supervisor_pid, spawn_life_added), "add_child should succeed")
	expect(t, wait_for_child_count(supervisor_pid, 4, 1000), "the added child should register")
	with_added := actod.get_children(supervisor_pid)
	added_pid := with_added[3] if len(with_added) == 4 else 0
	delete(with_added)
	append(&live, added_pid)
	expect_live_children(t, supervisor_pid, live[:], "after add_child")

	orphan_pid, orphan_ok := actod.spawn(
		"life-orphan",
		Crash_Test_Data{crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .PERMANENT),
		0,
	)
	expect(t, orphan_ok, "Failed to spawn the orphan")
	expect(t, actod.adopt_child(supervisor_pid, orphan_pid, spawn_life_adopted), "adopt_child should succeed")
	adoption := Adoption_Probe{child = orphan_pid, parent = supervisor_pid}
	expect(t, poll_until(adopted_parent_set, &adoption, time.Second), "the orphan should take its new parent")
	append(&live, orphan_pid)
	expect_live_children(t, supervisor_pid, live[:], "after adoption")

	crash_and_expect_restart(t, supervisor_pid, &live, 3, "life-added-", "added child, direct child ahead of it")
	crash_and_expect_restart(t, supervisor_pid, &live, 4, "life-adopted-", "adopted child, past the declared count")

	_ = actod.send_message(live[2], "done")
	ordered_remove(&live, 2)
	expect_live_children(t, supervisor_pid, live[:], "after the direct child ended")

	crash_and_expect_restart(t, supervisor_pid, &live, 1, "life-second-", "second declared child")
	crash_and_expect_restart(t, supervisor_pid, &live, 2, "life-added-", "added child, after the direct child left")

	expect(t, actod.remove_child(supervisor_pid, live[0]), "remove_child should succeed")
	ordered_remove(&live, 0)
	expect_live_children(t, supervisor_pid, live[:], "after removing the first declared child")

	crash_and_expect_restart(t, supervisor_pid, &live, 1, "life-added-", "added child, now second")
	crash_and_expect_restart(t, supervisor_pid, &live, 2, "life-adopted-", "adopted child, now last")
	crash_and_expect_restart(t, supervisor_pid, &live, 0, "life-second-", "second declared child, now first")

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	expect(t, wait_for_actor_invalid(supervisor_pid, 1000), "supervisor should stop")
}

Stale_Return :: enum {
	Own_Pid,
	Earlier_Sibling_Pid,
}

@(private = "file")
g_stale_return: Stale_Return

@(private = "file")
g_stale_first_sibling: actod.PID

@(private = "file")
g_stale_own_first: actod.PID

@(private = "file")
g_stale_calls: i32

spawn_stale_plain :: proc(prefix: string, parent: actod.PID) -> (actod.PID, bool) {
	id := int(sync.atomic_add(&global_test_state.actors_spawned, 1))
	return actod.spawn(
		fmt.tprintf("%s-%d", prefix, id),
		Crash_Test_Data{id = id, crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .PERMANENT),
		parent,
	)
}

spawn_stale_first :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	pid, ok := spawn_stale_plain("stale-first", parent)
	sync.atomic_store(&g_stale_first_sibling, pid)
	return pid, ok
}

spawn_stale_returning :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	if sync.atomic_add(&g_stale_calls, 1) == 0 {
		pid, ok := spawn_stale_plain("stale-returning", parent)
		sync.atomic_store(&g_stale_own_first, pid)
		return pid, ok
	}
	switch g_stale_return {
	case .Own_Pid:
		return sync.atomic_load(&g_stale_own_first), true
	case .Earlier_Sibling_Pid:
		return sync.atomic_load(&g_stale_first_sibling), true
	}
	return 0, false
}

spawn_stale_last :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	return spawn_stale_plain("stale-last", parent)
}

stale_function_ran_twice :: proc(_: rawptr) -> bool {
	return sync.atomic_load(&g_stale_calls) >= 2
}

restart_returning_a_stale_pid :: proc(t: ^testing.T, returns: Stale_Return, with_last_sibling: bool) {
	reset_test_state()
	g_stale_return = returns
	sync.atomic_store(&g_stale_calls, 0)
	sync.atomic_store(&g_sibling_restarts, 0)

	declared := make([dynamic]actod.SPAWN)
	defer delete(declared)
	append(&declared, spawn_stale_first, spawn_stale_returning)
	if with_last_sibling do append(&declared, spawn_stale_last)
	declared_count := len(declared)

	supervisor_pid, ok := actod.spawn(
		fmt.tprintf("stale-supervisor-%v-%v", returns, with_last_sibling),
		Sibling_Supervisor_Data{},
		Sibling_Supervisor_Behaviour,
		actod.make_actor_config(supervision_strategy = .ONE_FOR_ONE, children = declared),
	)
	expect(t, ok, "Failed to spawn supervisor")
	if !ok do return
	expect(t, wait_for_child_count(supervisor_pid, declared_count, 1000), "declared children should start")

	initial := actod.get_children(supervisor_pid)
	defer delete(initial)
	if !expectf(t, len(initial) == declared_count, "expected %d children, got %v", declared_count, initial) do return

	_ = actod.send_message(initial[1], "crash")
	expect(t, poll_until(stale_function_ran_twice, nil, time.Second), "the restart must run the spawn function again")
	expect(t, wait_for_actor_invalid(initial[1], 1000), "the crashed child should be gone")

	probe := Children_Equal_Probe{parent = supervisor_pid, expected = initial[:]}
	if !poll_until(children_equal, &probe, time.Second) {
		children := actod.get_children(supervisor_pid)
		defer delete(children)
		expectf(t, false, "a stale restart must leave the table as it was, expected %v, got %v", initial, children)
	}
	expect(t, actod.valid(&actod.NODE.actor_registry, initial[0]), "the first child must stay alive")
	expect_value(t, sync.atomic_load(&g_sibling_restarts), 0)

	live_sibling := initial[0]
	live_index := 0
	if with_last_sibling {
		live_sibling = initial[2]
		live_index = 2
	}
	_ = actod.send_message(live_sibling, "crash")
	restarted_sibling, restarted := wait_for_child_restart(supervisor_pid, initial[:], live_index, 2000)
	expect(t, restarted, "a live sibling must still be supervised and restart when it crashes")
	expect_value(t, sync.atomic_load(&g_sibling_restarts), 1)

	_ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	expect(t, wait_for_actor_invalid(supervisor_pid, 1000), "supervisor should stop")
	if restarted do expect(t, wait_for_actor_invalid(restarted_sibling, 1000), "stopping the supervisor must stop the restarted sibling")
}

test_restart_returning_own_pid_keeps_later_sibling :: proc(t: ^testing.T) {
	restart_returning_a_stale_pid(t, .Own_Pid, true)
}

test_restart_returning_own_pid_as_last_child :: proc(t: ^testing.T) {
	restart_returning_a_stale_pid(t, .Own_Pid, false)
}

test_restart_returning_earlier_sibling_pid :: proc(t: ^testing.T) {
	restart_returning_a_stale_pid(t, .Earlier_Sibling_Pid, true)
}
