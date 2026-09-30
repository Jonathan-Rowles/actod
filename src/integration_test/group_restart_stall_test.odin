package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

GROUP_RESTART_BOUND :: 2 * time.Second

@(private = "file")
g_hold: bool

@(private = "file")
g_held: bool

@(private = "file")
g_reported: bool

@(private = "file")
g_crashed_children: [2]actod.PID

@(private = "file")
g_restarts: [2]int

Stall_Supervisor_Data :: struct {}

Stall_Supervisor_Cmd :: enum {
	Hold,
	Report,
}

Stall_Supervisor_Behaviour :: actod.Actor_Behaviour(Stall_Supervisor_Data) {
	handle_message     = stall_supervisor_handle_message,
	on_child_restarted = stall_supervisor_on_child_restarted,
}

stall_supervisor_handle_message :: proc(data: ^Stall_Supervisor_Data, from: actod.PID, msg: any) {
	cmd, ok := msg.(Stall_Supervisor_Cmd)
	if !ok do return
	switch cmd {
	case .Hold:
		sync.atomic_store(&g_held, true)
		for sync.atomic_load(&g_hold) do time.sleep(time.Millisecond)
	case .Report:
		sync.atomic_store(&g_reported, true)
	}
}

stall_supervisor_on_child_restarted :: proc(
	data: ^Stall_Supervisor_Data,
	old_pid: actod.PID,
	new_pid: actod.PID,
	restart_count: int,
) {
	for child, i in g_crashed_children do if child == old_pid do sync.atomic_add(&g_restarts[i], 1)
}

@(private = "file")
spawn_first_crashing_child :: proc(name: string, parent: actod.PID) -> (actod.PID, bool) {
	return actod.spawn_child(
		"stall-first",
		Crash_Test_Data{crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
	)
}

@(private = "file")
spawn_second_crashing_child :: proc(name: string, parent: actod.PID) -> (actod.PID, bool) {
	return actod.spawn_child(
		"stall-second",
		Crash_Test_Data{crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
	)
}

@(private = "file")
children_crashed :: proc(state: rawptr) -> bool {
	for child in g_crashed_children {
		actor_ptr, active := actod.get(&actod.NODE.actor_registry, child)
		if !active || actor_ptr == nil do return false
		if sync.atomic_load(&(cast(^actod.Actor)actor_ptr).state) != .THREAD_STOPPED do return false
	}
	return true
}

@(private = "file")
children_restarted :: proc(state: rawptr) -> bool {
	for &count in g_restarts do if sync.atomic_load(&count) == 0 do return false
	return true
}

test_one_for_all_restart_of_two_crashed_children_does_not_wait_out_the_limit :: proc(t: ^testing.T) {
	sync.atomic_store(&g_hold, true)
	sync.atomic_store(&g_held, false)
	sync.atomic_store(&g_reported, false)
	g_restarts = {}

	supervisor_pid, ok := actod.spawn(
		"stall-supervisor",
		Stall_Supervisor_Data{},
		Stall_Supervisor_Behaviour,
		actod.make_actor_config(
			children = actod.make_children(spawn_first_crashing_child, spawn_second_crashing_child),
			supervision_strategy = .ONE_FOR_ALL,
			use_dedicated_os_thread = true,
		),
	)
	if !expect(t, ok, "spawn the supervisor") do return
	defer _ = actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
	if !expect(t, wait_for_child_count(supervisor_pid, 2, 2000), "both children must register") do return

	children := actod.get_children(supervisor_pid)
	copy(g_crashed_children[:], children)
	delete(children)

	_ = actod.send_message(supervisor_pid, Stall_Supervisor_Cmd.Hold)
	if !expect(t, poll_until(atomic_flag_raised, &g_held, 2 * time.Second), "the supervisor must be held") do return
	for child in g_crashed_children do _ = actod.send_message(child, "crash")
	crashed := poll_until(children_crashed, nil, 2 * time.Second)
	released := time.tick_now()
	sync.atomic_store(&g_hold, false)
	if !expect(t, crashed, "both children must crash while the supervisor is held") do return

	restarted := poll_until(children_restarted, nil, GROUP_RESTART_BOUND)
	elapsed := time.tick_since(released)
	expectf(
		t,
		restarted && elapsed < GROUP_RESTART_BOUND,
		"the group restart must finish within %v of the release, took %v (restarted: %v)",
		GROUP_RESTART_BOUND,
		elapsed,
		restarted,
	)

	_ = actod.send_message(supervisor_pid, Stall_Supervisor_Cmd.Report)
	expect(t, poll_until(atomic_flag_raised, &g_reported, 2 * time.Second), "the supervisor must finish its round")
	for &count, i in g_restarts {
		expectf(t, sync.atomic_load(&count) == 1, "child %d restarted %d times, want exactly once", i, count)
	}
}
