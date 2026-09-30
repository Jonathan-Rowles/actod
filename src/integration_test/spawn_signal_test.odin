package integration

import "../actod"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
g_held_in_handler: bool

@(private = "file")
g_held_release: bool

@(private = "file")
g_held_in_terminate: bool

@(private = "file")
g_block_terminate: bool

@(private = "file")
g_terminate_saw_children: int

@(private = "file")
g_terminated_child: actod.PID

@(private = "file")
g_terminated_will_restart: bool

@(private = "file")
g_terminated_count: i32

@(private = "file")
g_restarted_count: i32

@(private = "file")
reset_held_supervisor_state :: proc() {
	sync.atomic_store(&g_held_in_handler, false)
	sync.atomic_store(&g_held_release, false)
	sync.atomic_store(&g_held_in_terminate, false)
	sync.atomic_store(&g_block_terminate, false)
	sync.atomic_store(&g_terminate_saw_children, -1)
	sync.atomic_store(&g_terminated_child, 0)
	sync.atomic_store(&g_terminated_will_restart, false)
	sync.atomic_store(&g_terminated_count, 0)
	sync.atomic_store(&g_restarted_count, 0)
}

Held_Supervisor_Data :: struct {
	allocations: [dynamic]string,
}

Held_Supervisor_Behaviour :: actod.Actor_Behaviour(Held_Supervisor_Data) {
	handle_message = held_supervisor_handle_message,
	terminate = held_supervisor_terminate,
	on_child_terminated = proc(
		data: ^Held_Supervisor_Data,
		child_pid: actod.PID,
		child_name: string,
		reason: actod.Termination_Reason,
		will_restart: bool,
	) {
		sync.atomic_store(&g_terminated_child, child_pid)
		sync.atomic_store(&g_terminated_will_restart, will_restart)
		sync.atomic_add(&g_terminated_count, 1)
	},
	on_child_restarted = proc(
		data: ^Held_Supervisor_Data,
		old_pid: actod.PID,
		new_pid: actod.PID,
		restart_count: int,
	) {
		sync.atomic_add(&g_restarted_count, 1)
	},
}

@(private = "file")
hold_while_allocating :: proc(data: ^Held_Supervisor_Data) {
	sync.atomic_store(&g_held_in_handler, true)
	for !sync.atomic_load(&g_held_release) {
		append(&data.allocations, strings.clone("held"))
		time.sleep(200 * time.Microsecond)
	}
}

held_supervisor_handle_message :: proc(data: ^Held_Supervisor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case string:
		switch m {
		case "hold":
			hold_while_allocating(data)
		case "hold_then_panic":
			hold_while_allocating(data)
			panic("held supervisor crashes with a spawn signal pending")
		case "stop":
			actod.self_terminate(.NORMAL)
		}
	}
}

held_supervisor_terminate :: proc(data: ^Held_Supervisor_Data) {
	children := actod.get_children(actod.get_self_pid())
	sync.atomic_store(&g_terminate_saw_children, len(children))
	delete(children)
	if !sync.atomic_load(&g_block_terminate) do return
	sync.atomic_store(&g_held_in_terminate, true)
	for !sync.atomic_load(&g_held_release) do time.sleep(200 * time.Microsecond)
}

@(private = "file")
spawn_held_supervisor :: proc(name: string) -> (actod.PID, bool) {
	return actod.spawn(
		name,
		Held_Supervisor_Data{},
		Held_Supervisor_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .ONE_FOR_ONE,
			use_dedicated_os_thread = true,
		),
	)
}

@(private = "file")
held_in_handler :: proc() -> bool {
	return sync.atomic_load(&g_held_in_handler)
}

@(private = "file")
held_in_terminate :: proc() -> bool {
	return sync.atomic_load(&g_held_in_terminate)
}

@(private = "file")
Chain_Probe :: struct {
	spawn_pending: bool,
	stop_pending:  bool,
}

@(private = "file")
read_chains :: proc(pid: actod.PID) -> Chain_Probe {
	actod.reclaim_pin()
	defer actod.reclaim_unpin()
	ptr, ok := actod.get(&actod.NODE.actor_registry, pid)
	if !ok || ptr == nil do return {}
	actor := cast(^actod.Actor)ptr
	return Chain_Probe {
		spawn_pending = sync.atomic_load(&actor.spawned_head) != nil,
		stop_pending = sync.atomic_load(&actor.stopped_head) != nil,
	}
}

@(private = "file")
spawn_temporary_crasher :: proc(name: string, parent: actod.PID, crash_in_init := false) -> (actod.PID, bool) {
	return actod.spawn(
		name,
		Crash_Test_Data{crash_on_msg = "crash", crash_reason = .ABNORMAL, should_panic = crash_in_init},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
		parent_pid = parent,
	)
}

@(private = "file")
g_terminated_watch: actod.PID

@(private = "file")
watched_child_terminated :: proc() -> bool {
	return sync.atomic_load(&g_terminated_child) == sync.atomic_load(&g_terminated_watch)
}

Spawn_Under :: struct {
	parent: actod.PID,
}

@(init)
register_spawn_signal_test_messages :: proc "contextless" () {
	actod.register_message_type(Spawn_Under)
}

@(private = "file")
g_actor_spawned_child: actod.PID

Actor_Spawner_Data :: struct {}

Actor_Spawner_Behaviour :: actod.Actor_Behaviour(Actor_Spawner_Data) {
	handle_message = proc(data: ^Actor_Spawner_Data, from: actod.PID, msg: any) {
		request, is_request := msg.(Spawn_Under)
		if !is_request do return
		child_pid, _ := spawn_temporary_crasher("actor-spawned-child", request.parent)
		sync.atomic_store(&g_actor_spawned_child, child_pid)
	},
}

@(private = "file")
actor_spawned_child_ready :: proc() -> bool {
	return sync.atomic_load(&g_actor_spawned_child) != 0
}

test_spawn_from_another_actor_registers_through_the_owner :: proc(t: ^testing.T) {
	reset_held_supervisor_state()
	sync.atomic_store(&g_actor_spawned_child, 0)

	supervisor_pid, ok := spawn_held_supervisor("actor-spawn-held-supervisor")
	if !expect(t, ok, "supervisor spawn failed") do return
	spawner_pid, spawner_ok := actod.spawn("actor-spawner", Actor_Spawner_Data{}, Actor_Spawner_Behaviour)
	if !expect(t, spawner_ok, "spawner spawn failed") do return

	_ = actod.send_message(supervisor_pid, "hold")
	if !expect(t, wait_for_condition(held_in_handler, 2000), "supervisor never entered its handler") do return

	_ = actod.send_message(spawner_pid, Spawn_Under{parent = supervisor_pid})
	if !expect(t, wait_for_condition(actor_spawned_child_ready, 2000), "the spawner actor never spawned") do return
	child_pid := sync.atomic_load(&g_actor_spawned_child)

	expect(
		t,
		read_chains(supervisor_pid).spawn_pending,
		"a spawn made inside another actor must leave a signal for the supervisor, not write its table",
	)
	during_hold := actod.get_children(supervisor_pid)
	expectf(t, len(during_hold) == 0, "the table must not change while its owner is busy, has %d records", len(during_hold))
	delete(during_hold)

	sync.atomic_store(&g_held_release, true)
	expect(t, wait_for_child_count(supervisor_pid, 1, 2000), "the owner must register the child once it drains")
	children := actod.get_children(supervisor_pid)
	if len(children) == 1 do expect(t, children[0] == child_pid, "the registered pid must be the spawned child")
	delete(children)

	expect(t, actod.terminate_actor(spawner_pid), "terminate spawner")
	expect(t, wait_for_actor_invalid(spawner_pid, 2000), "spawner should stop")
	_ = actod.send_message(supervisor_pid, "stop")
	expect(t, wait_for_actor_invalid(supervisor_pid, 2000), "supervisor should stop")
	expect(t, wait_for_actor_invalid(child_pid, 2000), "the child should stop with its supervisor")
}

@(private = "file")
Foreign_Spawn_Job :: struct {
	parent: actod.PID,
	child:  actod.PID,
	ok:     bool,
}

@(private = "file")
spawn_permanent_child_job :: proc(job: ^Foreign_Spawn_Job) {
	job.child, job.ok = actod.spawn(
		"foreign-thread-permanent-child",
		Crash_Test_Data{crash_on_msg = "crash", crash_reason = .ABNORMAL},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .PERMANENT),
		parent_pid = job.parent,
	)
}

spawn_on_a_foreign_thread :: proc(_name: string, parent: actod.PID) -> (actod.PID, bool) {
	job := Foreign_Spawn_Job {
		parent = parent,
	}
	worker := thread.create_and_start_with_poly_data(&job, spawn_permanent_child_job)
	thread.join(worker)
	thread.destroy(worker)
	return job.child, job.ok
}

test_child_spawned_on_a_foreign_thread_restarts_by_its_own_policy :: proc(t: ^testing.T) {
	reset_held_supervisor_state()

	supervisor_pid, ok := spawn_held_supervisor("foreign-thread-spawn-supervisor")
	if !expect(t, ok, "supervisor spawn failed") do return

	expect(t, actod.add_child(supervisor_pid, spawn_on_a_foreign_thread), "add_child should succeed")
	expect(t, wait_for_child_count(supervisor_pid, 1, 2000), "the child spawned off-thread must be recorded")
	first := actod.get_children(supervisor_pid)
	defer delete(first)
	if !expectf(t, len(first) == 1, "expected 1 child, got %d", len(first)) do return

	_ = actod.send_message(first[0], "crash")
	restarted_pid, restarted := wait_for_child_restart(supervisor_pid, first, 0, 3000)
	expect(t, restarted, "a PERMANENT child spawned on a foreign thread must restart through its spawn function")
	if restarted do expect(t, restarted_pid != first[0], "the restart must record a new pid")
	expect_value(t, sync.atomic_load(&g_restarted_count), 1)
	expect(t, wait_for_child_count(supervisor_pid, 1, 2000), "the restart must replace the record, not add one")

	_ = actod.send_message(supervisor_pid, "stop")
	expect(t, wait_for_actor_invalid(supervisor_pid, 2000), "supervisor should stop")
}

@(private = "file")
g_chain_probe_pid: actod.PID

@(private = "file")
both_chains_pending :: proc() -> bool {
	chains := read_chains(sync.atomic_load(&g_chain_probe_pid))
	return chains.spawn_pending && chains.stop_pending
}

test_foreign_child_dying_before_the_drain_is_registered_first :: proc(t: ^testing.T) {
	reset_held_supervisor_state()

	supervisor_pid, ok := spawn_held_supervisor("die-before-drain-supervisor")
	if !expect(t, ok, "supervisor spawn failed") do return

	_ = actod.send_message(supervisor_pid, "hold")
	if !expect(t, wait_for_condition(held_in_handler, 2000), "supervisor never entered its handler") do return

	child_pid, child_ok := spawn_temporary_crasher("die-before-drain-child", supervisor_pid, crash_in_init = true)
	if !expect(t, child_ok, "foreign spawn failed") do return

	sync.atomic_store(&g_chain_probe_pid, supervisor_pid)
	expect(
		t,
		wait_for_condition(both_chains_pending, 2000),
		"the child's spawn signal and stop signal must both wait on the busy supervisor",
	)

	sync.atomic_store(&g_terminated_watch, child_pid)
	sync.atomic_store(&g_held_release, true)
	expect(
		t,
		wait_for_condition(watched_child_terminated, 2000),
		"the supervisor must know the child when its death is handled, not log it as unknown",
	)
	expect_value(t, sync.atomic_load(&g_terminated_count), 1)
	expect(t, !sync.atomic_load(&g_terminated_will_restart), "a TEMPORARY child must not be restarted")
	expect(t, wait_for_child_count(supervisor_pid, 0, 2000), "the dead TEMPORARY child must leave the table")

	_ = actod.send_message(supervisor_pid, "stop")
	expect(t, wait_for_actor_invalid(supervisor_pid, 2000), "supervisor should stop")
}

Spawning_Parent_Data :: struct {
	job:    Foreign_Spawn_Job,
	worker: ^thread.Thread,
	done:   bool,
}

@(private = "file")
spawn_quiet_child_job :: proc(data: ^Spawning_Parent_Data) {
	data.job.child, data.job.ok = actod.spawn(
		"deciding-to-park-child",
		Crash_Test_Data{},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
		parent_pid = data.job.parent,
	)
	sync.atomic_store(&data.done, true)
}

Spawning_Parent_Behaviour :: actod.Actor_Behaviour(Spawning_Parent_Data) {
	handle_message = proc(data: ^Spawning_Parent_Data, from: actod.PID, msg: any) {
		m, is_string := msg.(string)
		if !is_string || m != "spawn_from_a_thread_and_return" do return
		data.job.parent = actod.get_self_pid()
		data.worker = thread.create_and_start_with_poly_data(data, spawn_quiet_child_job)
		for !sync.atomic_load(&data.done) do actod.yield()
		thread.join(data.worker)
		thread.destroy(data.worker)
	},
}

@(private = "file")
Parked_Probe :: struct {
	pid: actod.PID,
}

@(private = "file")
pooled_actor_parked :: proc(state: rawptr) -> bool {
	probe := cast(^Parked_Probe)state
	actod.reclaim_pin()
	defer actod.reclaim_unpin()
	ptr, ok := actod.get(&actod.NODE.actor_registry, probe.pid)
	if !ok || ptr == nil do return false
	handle := (cast(^actod.Actor)ptr).pool_handle
	return handle != nil && !sync.atomic_load(&handle.in_ready_queue)
}

test_spawn_signal_wakes_a_parked_parent :: proc(t: ^testing.T) {
	parent_pid, ok := actod.spawn("parked-parent", Spawning_Parent_Data{}, Spawning_Parent_Behaviour)
	if !expect(t, ok, "parent spawn failed") do return

	probe := Parked_Probe {
		pid = parent_pid,
	}
	expect(t, poll_until(pooled_actor_parked, &probe, 2 * time.Second), "the idle parent never parked")

	child_pid, child_ok := actod.spawn(
		"parked-parent-child",
		Crash_Test_Data{},
		Crash_Test_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
		parent_pid = parent_pid,
	)
	expect(t, child_ok, "foreign spawn failed")
	expect(t, wait_for_child_count(parent_pid, 1, 2000), "a spawn signal must wake a parked parent")
	children := actod.get_children(parent_pid)
	if len(children) == 1 do expect(t, children[0] == child_pid, "the registered pid must be the spawned child")
	delete(children)

	expect(t, actod.terminate_actor(parent_pid), "terminate parent")
	expect(t, wait_for_actor_invalid(parent_pid, 2000), "parent should stop")
}

test_spawn_signal_pushed_while_the_parent_runs_is_not_stranded :: proc(t: ^testing.T) {
	parent_pid, ok := actod.spawn("deciding-to-park-parent", Spawning_Parent_Data{}, Spawning_Parent_Behaviour)
	if !expect(t, ok, "parent spawn failed") do return

	_ = actod.send_message(parent_pid, "spawn_from_a_thread_and_return")
	expect(
		t,
		wait_for_child_count(parent_pid, 1, 2000),
		"a signal pushed while the parent was running, so its wake was a no-op, must still be drained before the parent parks",
	)

	expect(t, actod.terminate_actor(parent_pid), "terminate parent")
	expect(t, wait_for_actor_invalid(parent_pid, 2000), "parent should stop")
}

test_foreign_spawn_into_a_crashing_parent_is_registered_then_terminated :: proc(t: ^testing.T) {
	reset_held_supervisor_state()

	supervisor_pid, ok := spawn_held_supervisor("crashing-parent-supervisor")
	if !expect(t, ok, "supervisor spawn failed") do return

	_ = actod.send_message(supervisor_pid, "hold_then_panic")
	if !expect(t, wait_for_condition(held_in_handler, 2000), "supervisor never entered its handler") do return

	child_pid, child_ok := spawn_temporary_crasher("crashing-parent-child", supervisor_pid)
	if !expect(t, child_ok, "foreign spawn failed") do return
	expect(t, read_chains(supervisor_pid).spawn_pending, "the spawn signal must wait on the busy supervisor")

	sync.atomic_store(&g_held_release, true)
	expect(t, wait_for_actor_invalid(supervisor_pid, 3000), "supervisor should stop")
	expect_value(t, sync.atomic_load(&g_terminate_saw_children), 1)
	expect(t, wait_for_actor_invalid(child_pid, 3000), "a child registered while its parent stops must be terminated with it")
}

test_remove_child_right_after_a_foreign_spawn_finds_the_child :: proc(t: ^testing.T) {
	reset_held_supervisor_state()

	supervisor_pid, ok := spawn_held_supervisor("remove-after-spawn-supervisor")
	if !expect(t, ok, "supervisor spawn failed") do return

	_ = actod.send_message(supervisor_pid, "hold")
	if !expect(t, wait_for_condition(held_in_handler, 2000), "supervisor never entered its handler") do return

	child_pid, child_ok := spawn_temporary_crasher("remove-after-spawn-child", supervisor_pid)
	if !expect(t, child_ok, "foreign spawn failed") do return
	expect(t, actod.remove_child(supervisor_pid, child_pid), "remove_child should be accepted")

	sync.atomic_store(&g_held_release, true)
	expect(
		t,
		wait_for_actor_invalid(child_pid, 3000),
		"Remove_Child sent after the spawn returned must find the child and shut it down",
	)
	expect(t, wait_for_child_count(supervisor_pid, 0, 2000), "the removed child must leave the table")

	_ = actod.send_message(supervisor_pid, "stop")
	expect(t, wait_for_actor_invalid(supervisor_pid, 2000), "supervisor should stop")
}

test_foreign_spawn_after_the_parent_terminated_its_children_is_reaped :: proc(t: ^testing.T) {
	reset_held_supervisor_state()
	sync.atomic_store(&g_block_terminate, true)

	supervisor_pid, ok := spawn_held_supervisor("terminating-parent-supervisor")
	if !expect(t, ok, "supervisor spawn failed") do return

	_ = actod.send_message(supervisor_pid, "stop")
	if !expect(t, wait_for_condition(held_in_terminate, 2000), "supervisor never entered terminate") do return

	child_pid, child_ok := spawn_temporary_crasher("terminating-parent-child", supervisor_pid)
	if !expect(t, child_ok, "foreign spawn failed") do return
	expect(t, read_chains(supervisor_pid).spawn_pending, "the spawn signal must stay on the stopping parent's chain")

	sync.atomic_store(&g_held_release, true)
	expect(t, wait_for_actor_invalid(supervisor_pid, 3000), "supervisor should stop")
	expect(t, wait_for_actor_invalid(child_pid, 3000), "the reaper must shut down a child its parent never drained")
}

CONCURRENT_SPAWN_THREADS :: 8
CONCURRENT_SPAWNS_PER_THREAD :: 32

Concurrent_Spawn_Job :: struct {
	parent: actod.PID,
	start:  ^bool,
	index:  int,
	pids:   [CONCURRENT_SPAWNS_PER_THREAD]actod.PID,
	failed: int,
}

Quiet_Child_Data :: struct {}

Quiet_Child_Behaviour :: actod.Actor_Behaviour(Quiet_Child_Data) {
	handle_message = proc(data: ^Quiet_Child_Data, from: actod.PID, msg: any) {},
}

@(private = "file")
concurrent_spawn_job :: proc(job: ^Concurrent_Spawn_Job) {
	for !sync.atomic_load(job.start) do thread.yield()
	for i in 0 ..< CONCURRENT_SPAWNS_PER_THREAD {
		pid, ok := actod.spawn(
			fmt.tprintf("concurrent-%d-%d", job.index, i),
			Quiet_Child_Data{},
			Quiet_Child_Behaviour,
			actod.make_actor_config(restart_policy = .TEMPORARY),
			parent_pid = job.parent,
		)
		if ok {
			job.pids[i] = pid
		} else {
			job.failed += 1
		}
	}
}

test_concurrent_foreign_spawns_register_each_child_once :: proc(t: ^testing.T) {
	supervisor_pid, ok := actod.spawn(
		"concurrent-spawn-supervisor",
		Quiet_Child_Data{},
		Quiet_Child_Behaviour,
		actod.make_actor_config(supervision_strategy = .ONE_FOR_ONE),
	)
	if !expect(t, ok, "supervisor spawn failed") do return

	start := false
	jobs: [CONCURRENT_SPAWN_THREADS]Concurrent_Spawn_Job
	workers: [CONCURRENT_SPAWN_THREADS]^thread.Thread
	for i in 0 ..< CONCURRENT_SPAWN_THREADS {
		jobs[i] = Concurrent_Spawn_Job {
			parent = supervisor_pid,
			start  = &start,
			index  = i,
		}
		workers[i] = thread.create_and_start_with_poly_data(&jobs[i], concurrent_spawn_job)
	}
	sync.atomic_store(&start, true)
	for worker in workers {
		thread.join(worker)
		thread.destroy(worker)
	}

	expected := make([dynamic]actod.PID, 0, CONCURRENT_SPAWN_THREADS * CONCURRENT_SPAWNS_PER_THREAD)
	defer delete(expected)
	for &job in jobs {
		expectf(t, job.failed == 0, "thread %d failed %d spawns", job.index, job.failed)
		for pid in job.pids do if pid != 0 do append(&expected, pid)
	}

	expect(
		t,
		wait_for_child_count(supervisor_pid, len(expected), 5000),
		"every concurrently spawned child must be registered",
	)
	children := actod.get_children(supervisor_pid)
	defer delete(children)
	slice.sort(expected[:])
	slice.sort(children)
	expect(t, slice.equal(expected[:], children), "each spawned child must be recorded exactly once")

	expect(t, actod.terminate_actor(supervisor_pid), "terminate supervisor")
	expect(t, wait_for_actor_invalid(supervisor_pid, 5000), "supervisor should stop")
	for pid in expected {
		if !expect(t, wait_for_actor_invalid(pid, 2000), "every registered child must stop with its supervisor") do break
	}
}

test_sim_foreign_spawn_registers_on_the_parents_drain :: proc(t: ^testing.T) {
	supervisor_pid, ok := actod.spawn("sim-foreign-spawn-supervisor", Quiet_Child_Data{}, Quiet_Child_Behaviour)
	if !expect(t, ok, "supervisor spawn failed") do return
	_ = actod.sim_run_until_idle()

	child_pid, child_ok := actod.spawn(
		"sim-foreign-spawn-child",
		Quiet_Child_Data{},
		Quiet_Child_Behaviour,
		actod.make_actor_config(restart_policy = .TEMPORARY),
		parent_pid = supervisor_pid,
	)
	if !expect(t, child_ok, "foreign spawn failed") do return

	before := actod.get_children(supervisor_pid)
	expectf(t, len(before) == 0, "a foreign spawn registers when the parent drains, not on return, got %d", len(before))
	delete(before)

	_ = actod.sim_run_until_idle()
	after := actod.get_children(supervisor_pid)
	defer delete(after)
	if expectf(t, len(after) == 1, "the parent must register the child on its next run, got %d", len(after)) do expect(t, after[0] == child_pid, "the registered pid must be the spawned child")
}
