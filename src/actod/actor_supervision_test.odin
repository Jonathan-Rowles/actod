package actod

import "../../test_harness/ti"
import "base:runtime"
import "core:c/libc"
import "core:log"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
Reap_On_Stop :: struct {
	backing:     runtime.Allocator,
	sibling_pid: PID,
	reaped:      bool,
}

@(private = "file")
reap_on_stop_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	reaper := cast(^Reap_On_Stop)allocator_data
	if !reaper.reaped && mode != .Free && mode != .Free_All {
		remove(&NODE.actor_registry, reaper.sibling_pid)
		reaper.reaped = true
	}
	return reaper.backing.procedure(reaper.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private = "file")
g_pruned_sibling_pid: PID

@(private = "file")
g_pruned_sibling_name_len: int

@(private = "file")
g_pruned_sibling_name_buf: [STOP_SIGNAL_NAME_CAP]u8

@(private = "file")
record_pruned_sibling :: proc(
	data: rawptr,
	child_pid: PID,
	child_name: string,
	reason: Termination_Reason,
	will_restart: bool,
) {
	g_pruned_sibling_pid = child_pid
	g_pruned_sibling_name_len = copy(g_pruned_sibling_name_buf[:], child_name)
}

@(private = "file")
g_sibling_spawn_calls: int

@(private = "file")
count_sibling_spawn :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	g_sibling_spawn_calls += 1
	return 0, false
}

@(private = "file")
removed_sibling_reaped_as_it_is_stopped :: proc(
	t: ^testing.T,
	sibling_policy: Restart_Policy,
	sibling_spawn: SPAWN,
) {
	sync.lock(&global_registry_swap_mutex)
	defer sync.unlock(&global_registry_swap_mutex)
	saved_registry := NODE.actor_registry
	test_registry := make_test_registry()
	clear(test_registry)
	NODE.actor_registry = test_registry^
	defer {
		NODE.actor_registry = saved_registry
		free(test_registry)
	}

	sibling := new(Actor)
	defer free(sibling)
	sibling.name = "direct-sibling"
	sibling.opts.restart_policy = sibling_policy
	sibling_pid, added := add(&NODE.actor_registry, rawptr(sibling), sibling.name)
	if !testing.expect(t, added, "the sibling should register") do return

	supervisor := new(Actor)
	defer free(supervisor)
	supervisor.pid = pack_pid(Handle{idx = 40, gen = 1})
	supervisor.state = .RUNNING
	supervisor.behaviour.on_child_terminated = record_pruned_sibling
	supervisor.children = make([dynamic]Supervised_Child)
	defer delete(supervisor.children)
	dying_pid := pack_pid(Handle{idx = 41, gen = 1})
	append(
		&supervisor.children,
		Supervised_Child{pid = dying_pid},
		Supervised_Child{pid = sibling_pid, restart = {spawn_func = sibling_spawn}},
	)
	g_pruned_sibling_pid = 0
	g_pruned_sibling_name_len = 0
	g_sibling_spawn_calls = 0

	reaper := Reap_On_Stop {
		backing     = context.allocator,
		sibling_pid = sibling_pid,
	}
	captured := make([dynamic]ti.Captured_Terminate, runtime.Allocator{procedure = reap_on_stop_allocator_proc, data = &reaper})
	defer delete(captured)
	intercept := ti.Test_Intercept {
		terminate_capture = &captured,
	}
	ti.test_intercept = &intercept
	defer ti.test_intercept = nil

	if sync.atomic_load(&NODE.reclaim.epoch) == 0 do sync.atomic_store(&NODE.reclaim.epoch, 1)
	stop_and_restart_children_from(supervisor, 0, dying_pid)

	testing.expect(t, reaper.reaped, "stopping the sibling must reap it from the registry")
	if testing.expect_value(t, len(captured), 1) do testing.expect_value(t, PID(captured[0].pid), sibling_pid)
	testing.expect_value(t, g_pruned_sibling_pid, sibling_pid)
	testing.expect_value(t, string(g_pruned_sibling_name_buf[:g_pruned_sibling_name_len]), "direct-sibling")
	testing.expect_value(t, g_sibling_spawn_calls, 0)
	if testing.expect_value(t, len(supervisor.children), 1) do testing.expect_value(t, supervisor.children[0].pid, dying_pid)
}

@(test)
unrestartable_sibling_reaped_as_it_is_stopped_keeps_its_name_test :: proc(t: ^testing.T) {
	removed_sibling_reaped_as_it_is_stopped(t, .PERMANENT, nil)
}

@(test)
temporary_sibling_reaped_as_it_is_stopped_is_not_restarted_test :: proc(t: ^testing.T) {
	removed_sibling_reaped_as_it_is_stopped(t, .TEMPORARY, count_sibling_spawn)
}

@(private = "file")
Supervision_Event_Kind :: enum {
	Reaped,
	Terminated,
	Spawned,
	Restarted,
	Started,
}

@(private = "file")
Supervision_Event :: struct {
	kind:         Supervision_Event_Kind,
	pid:          PID,
	new_pid:      PID,
	count:        int,
	reason:       Termination_Reason,
	will_restart: bool,
}

@(private = "file")
MAX_SUPERVISION_EVENTS :: 32

@(private = "file")
g_events: [MAX_SUPERVISION_EVENTS]Supervision_Event

@(private = "file")
g_event_count: int

@(private = "file")
record_event :: proc "contextless" (event: Supervision_Event) {
	if g_event_count < MAX_SUPERVISION_EVENTS do g_events[g_event_count] = event
	g_event_count += 1
}

@(private = "file")
reap_at_fake_node :: proc "contextless" (data: rawptr) {
	context = runtime.default_context()
	f := cast(^Group_Fixture)data
	for child := take_stop_signals(f.node); child != nil; child = cast(^Actor)child.stop_signal.next {
		record_event({kind = .Reaped, pid = child.stop_signal.pid})
		remove(&NODE.actor_registry, child.stop_signal.pid)
		if f.after_reap != nil do f.after_reap(f, child.stop_signal.pid)
	}
}

@(private = "file")
record_terminated :: proc(data: rawptr, child_pid: PID, child_name: string, reason: Termination_Reason, will_restart: bool) {
	record_event({kind = .Terminated, pid = child_pid, reason = reason, will_restart = will_restart})
}

@(private = "file")
record_restarted :: proc(data: rawptr, old_pid: PID, new_pid: PID, restart_count: int) {
	record_event({kind = .Restarted, pid = old_pid, new_pid = new_pid, count = restart_count})
}

@(private = "file")
record_started :: proc(data: rawptr, child_pid: PID) {
	record_event({kind = .Started, pid = child_pid})
}

@(private = "file")
MAX_GROUP_CHILDREN :: 6

@(private = "file")
g_spawn_calls: [MAX_GROUP_CHILDREN]int

@(private = "file")
spawned_pid :: proc(child: int) -> PID {
	g_spawn_calls[child] += 1
	pid := pack_pid(Handle{idx = u32(100 + 10 * child + g_spawn_calls[child]), gen = 1})
	record_event({kind = .Spawned, pid = pid})
	return pid
}

@(private = "file")
respawn_first :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	return spawned_pid(0), true
}

@(private = "file")
respawn_second :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	return spawned_pid(1), true
}

@(private = "file")
respawn_third :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	return spawned_pid(2), true
}

@(private = "file")
refuse_respawn :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	return 0, false
}

@(private = "file")
respawned :: proc(child: int, nth: int) -> PID {
	return pack_pid(Handle{idx = u32(100 + 10 * child + nth), gen = 1})
}

@(private = "file")
Group_Fixture :: struct {
	saved_registry: PID_Map(rawptr, PID),
	test_registry:  ^PID_Map(rawptr, PID),
	node:           ^Actor,
	supervisor:     ^Actor,
	children:       [MAX_GROUP_CHILDREN]^Actor,
	pids:           [MAX_GROUP_CHILDREN]PID,
	captured:       [dynamic]ti.Captured_Terminate,
	intercept:      ti.Test_Intercept,
	clock:          ti.Det_State,
	after_reap:     proc(f: ^Group_Fixture, reaped: PID),
}

@(private = "file")
make_group_fixture :: proc(f: ^Group_Fixture, strategy: Supervision_Strategy, child_count: int) {
	sync.lock(&global_registry_swap_mutex)
	f.saved_registry = NODE.actor_registry
	f.test_registry = make_test_registry()
	clear(f.test_registry)
	NODE.actor_registry = f.test_registry^
	if sync.atomic_load(&NODE.reclaim.epoch) == 0 do sync.atomic_store(&NODE.reclaim.epoch, 1)

	f.node = new(Actor)
	f.node.data = f
	f.node.behaviour.on_wake = reap_at_fake_node
	node_pid, _ := add(&NODE.actor_registry, rawptr(f.node), "fake-node")
	f.node.pid = node_pid
	NODE.pid = node_pid

	f.supervisor = new(Actor)
	f.supervisor.pid = pack_pid(Handle{idx = 90, gen = 1})
	f.supervisor.state = .RUNNING
	f.supervisor.opts.supervision_strategy = strategy
	f.supervisor.opts.max_restarts = 3
	f.supervisor.opts.restart_window = time.Hour
	f.supervisor.behaviour.on_child_terminated = record_terminated
	f.supervisor.behaviour.on_child_restarted = record_restarted
	f.supervisor.behaviour.on_child_started = record_started
	f.supervisor.children = make([dynamic]Supervised_Child)

	respawns := [MAX_GROUP_CHILDREN]SPAWN{respawn_first, respawn_second, respawn_third, refuse_respawn, refuse_respawn, refuse_respawn}
	names := [MAX_GROUP_CHILDREN]string{"first-child", "second-child", "third-child", "fourth-child", "fifth-child", "sixth-child"}
	for i in 0 ..< child_count {
		child := new(Actor)
		child.name = names[i]
		child.state = .RUNNING
		child.opts.restart_policy = .PERMANENT
		child.parent = f.supervisor.pid
		pid, _ := add(&NODE.actor_registry, rawptr(child), child.name)
		child.pid = pid
		child.stop_signal.pid = pid
		child.stop_signal.reason = .ABNORMAL
		f.children[i] = child
		f.pids[i] = pid
		append(&f.supervisor.children, Supervised_Child{pid = pid, restart = {spawn_func = respawns[i]}})
	}

	g_event_count = 0
	g_spawn_calls = {}
	f.intercept.terminate_capture = &f.captured
	ti.test_intercept = &f.intercept
	f.clock = {
		virtual_now     = time.unix(1_700_000_000, 0),
		virtual_tick_ns = 1,
	}
	ti.det = &f.clock
}

@(private = "file")
destroy_group_fixture :: proc(f: ^Group_Fixture) {
	ti.det = nil
	ti.test_intercept = nil
	delete(f.captured)
	for child in f.children do if child != nil do free(child)
	delete(f.supervisor.children)
	free(f.supervisor)
	free(f.node)
	NODE.pid = 0
	NODE.actor_registry = f.saved_registry
	free(f.test_registry)
	sync.unlock(&global_registry_swap_mutex)
}

@(private = "file")
die :: proc(f: ^Group_Fixture, child: int) {
	sync.atomic_store(&f.children[child].state, .THREAD_STOPPED)
	push_stop_signal(f.supervisor, f.children[child])
}

@(private = "file")
expect_events :: proc(t: ^testing.T, expected: []Supervision_Event) {
	got := g_events[:min(g_event_count, MAX_SUPERVISION_EVENTS)]
	same := g_event_count == len(expected)
	if same do for event, i in expected do if got[i] != event do same = false
	testing.expectf(t, same, "supervision events\n got %v\nwant %v", got, expected)
}

@(private = "file")
expect_table :: proc(t: ^testing.T, f: ^Group_Fixture, expected: []PID) {
	got := make([]PID, len(f.supervisor.children))
	defer delete(got)
	for child, i in f.supervisor.children do got[i] = child.pid
	testing.expectf(t, slice.equal(got, expected), "children table %v, want %v", got, expected)
}

@(private = "file")
expect_killed :: proc(t: ^testing.T, f: ^Group_Fixture, expected: []PID) {
	got := make([]PID, len(f.captured))
	defer delete(got)
	for capture, i in f.captured {
		got[i] = PID(capture.pid)
		testing.expect_value(t, Termination_Reason(capture.reason), Termination_Reason.KILLED)
	}
	testing.expectf(t, slice.equal(got, expected), "killed %v, want %v", got, expected)
}

@(test)
one_for_all_hands_a_dead_sibling_in_the_same_batch_to_the_node_before_waiting_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .ONE_FOR_ALL, 2)
	defer destroy_group_fixture(&f)
	a, b := f.pids[0], f.pids[1]

	die(&f, 0)
	die(&f, 1)
	process_stop_signals(f.supervisor)

	expect_events(
		t,
		{
			{kind = .Reaped, pid = a},
			{kind = .Terminated, pid = a, reason = .ABNORMAL, will_restart = true},
			{kind = .Reaped, pid = b},
			{kind = .Spawned, pid = respawned(0, 1)},
			{kind = .Restarted, pid = a, new_pid = respawned(0, 1), count = 1},
			{kind = .Started, pid = respawned(0, 1)},
			{kind = .Spawned, pid = respawned(1, 1)},
			{kind = .Restarted, pid = b, new_pid = respawned(1, 1), count = 0},
			{kind = .Started, pid = respawned(1, 1)},
		},
	)
	expect_table(t, &f, {respawned(0, 1), respawned(1, 1)})
	expect_killed(t, &f, {b})
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}

@(private = "file")
Die_On_Kill :: struct {
	backing: runtime.Allocator,
	fixture: ^Group_Fixture,
	deaths:  []int,
	fired:   bool,
}

@(private = "file")
die_on_kill_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	hook := cast(^Die_On_Kill)allocator_data
	if !hook.fired && mode != .Free && mode != .Free_All {
		hook.fired = true
		for child in hook.deaths do die(hook.fixture, child)
	}
	return hook.backing.procedure(hook.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
sibling_dying_during_the_group_wait_is_handed_to_the_node_and_the_rest_handled_in_order_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .REST_FOR_ONE, 3)
	defer destroy_group_fixture(&f)
	x, a, b := f.pids[0], f.pids[1], f.pids[2]

	hook := Die_On_Kill {
		backing = context.allocator,
		fixture = &f,
		deaths  = {0, 2},
	}
	f.captured = make([dynamic]ti.Captured_Terminate, runtime.Allocator{procedure = die_on_kill_allocator_proc, data = &hook})

	die(&f, 1)
	process_stop_signals(f.supervisor)
	process_stop_signals(f.supervisor)

	testing.expect(t, hook.fired, "the sibling must be stopped by the group restart")
	expect_events(
		t,
		{
			{kind = .Reaped, pid = a},
			{kind = .Terminated, pid = a, reason = .ABNORMAL, will_restart = true},
			{kind = .Reaped, pid = b},
			{kind = .Spawned, pid = respawned(1, 1)},
			{kind = .Restarted, pid = a, new_pid = respawned(1, 1), count = 1},
			{kind = .Started, pid = respawned(1, 1)},
			{kind = .Spawned, pid = respawned(2, 1)},
			{kind = .Restarted, pid = b, new_pid = respawned(2, 1), count = 0},
			{kind = .Started, pid = respawned(2, 1)},
			{kind = .Reaped, pid = x},
			{kind = .Terminated, pid = x, reason = .ABNORMAL, will_restart = true},
			{kind = .Spawned, pid = respawned(0, 1)},
			{kind = .Restarted, pid = x, new_pid = respawned(0, 1), count = 1},
			{kind = .Started, pid = respawned(0, 1)},
			{kind = .Spawned, pid = respawned(1, 2)},
			{kind = .Restarted, pid = respawned(1, 1), new_pid = respawned(1, 2), count = 1},
			{kind = .Started, pid = respawned(1, 2)},
			{kind = .Spawned, pid = respawned(2, 2)},
			{kind = .Restarted, pid = respawned(2, 1), new_pid = respawned(2, 2), count = 0},
			{kind = .Started, pid = respawned(2, 2)},
		},
	)
	expect_table(t, &f, {respawned(0, 1), respawned(1, 2), respawned(2, 2)})
	expect_killed(t, &f, {b, respawned(1, 1), respawned(2, 1)})
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}

@(test)
rest_for_one_hands_over_only_the_dead_siblings_in_its_range_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .REST_FOR_ONE, 3)
	defer destroy_group_fixture(&f)
	x, a, b := f.pids[0], f.pids[1], f.pids[2]

	die(&f, 1)
	die(&f, 0)
	die(&f, 2)
	process_stop_signals(f.supervisor)

	expect_events(
		t,
		{
			{kind = .Reaped, pid = a},
			{kind = .Terminated, pid = a, reason = .ABNORMAL, will_restart = true},
			{kind = .Reaped, pid = b},
			{kind = .Spawned, pid = respawned(1, 1)},
			{kind = .Restarted, pid = a, new_pid = respawned(1, 1), count = 1},
			{kind = .Started, pid = respawned(1, 1)},
			{kind = .Spawned, pid = respawned(2, 1)},
			{kind = .Restarted, pid = b, new_pid = respawned(2, 1), count = 0},
			{kind = .Started, pid = respawned(2, 1)},
			{kind = .Reaped, pid = x},
			{kind = .Terminated, pid = x, reason = .ABNORMAL, will_restart = true},
			{kind = .Spawned, pid = respawned(0, 1)},
			{kind = .Restarted, pid = x, new_pid = respawned(0, 1), count = 1},
			{kind = .Started, pid = respawned(0, 1)},
			{kind = .Spawned, pid = respawned(1, 2)},
			{kind = .Restarted, pid = respawned(1, 1), new_pid = respawned(1, 2), count = 1},
			{kind = .Started, pid = respawned(1, 2)},
			{kind = .Spawned, pid = respawned(2, 2)},
			{kind = .Restarted, pid = respawned(2, 1), new_pid = respawned(2, 2), count = 0},
			{kind = .Started, pid = respawned(2, 2)},
		},
	)
	expect_table(t, &f, {respawned(0, 1), respawned(1, 2), respawned(2, 2)})
	expect_killed(t, &f, {b, respawned(1, 1), respawned(2, 1)})
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}

@(test)
stopping_parent_hands_a_dead_child_on_its_chain_to_the_node_before_waiting_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .ONE_FOR_ONE, 1)
	defer destroy_group_fixture(&f)
	child := f.pids[0]

	die(&f, 0)
	f.supervisor.state = .STOPPING
	terminate_children(f.supervisor)

	expect_events(t, {{kind = .Reaped, pid = child}})
	if testing.expect_value(t, len(f.captured), 1) {
		testing.expect_value(t, PID(f.captured[0].pid), child)
		testing.expect_value(t, Termination_Reason(f.captured[0].reason), Termination_Reason.SHUTDOWN)
	}
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}

@(private = "file")
panic_on_restart :: proc(data: rawptr, old_pid: PID, new_pid: PID, restart_count: int) {
	panic("the restart callback panics after the group wait")
}

@(test)
supervisor_panicking_after_a_group_wait_hands_every_put_aside_signal_to_the_node_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .REST_FOR_ONE, 4)
	defer destroy_group_fixture(&f)
	x, a, b, outside_table := f.pids[0], f.pids[1], f.pids[2], f.pids[3]
	pop(&f.supervisor.children)
	f.supervisor.behaviour.on_child_restarted = panic_on_restart

	hook := Die_On_Kill {
		backing = context.allocator,
		fixture = &f,
		deaths  = {0, 3, 2},
	}
	f.captured = make([dynamic]ti.Captured_Terminate, runtime.Allocator{procedure = die_on_kill_allocator_proc, data = &hook})
	clock_before := f.clock.virtual_tick_ns

	saved_actor_context := current_actor_context
	actor_ctx: Actor_Context
	current_actor_context = &actor_ctx
	die(&f, 1)
	{
		context.assertion_failure_proc = actor_panic_handler
		context.logger = log.nil_logger()
		context.allocator = context.temp_allocator
		if libc.setjmp(cast(^libc.jmp_buf)&actor_ctx.panic_jmp_buf) != 0 {
			actor_panic_teardown(f.supervisor, &actor_ctx)
		} else {
			process_stop_signals(f.supervisor)
		}
	}
	free_all(context.temp_allocator)
	current_actor_context = saved_actor_context

	testing.expect(t, actor_ctx.panic_recovery_done, "the restart callback must panic")
	expect_events(
		t,
		{
			{kind = .Reaped, pid = a},
			{kind = .Terminated, pid = a, reason = .ABNORMAL, will_restart = true},
			{kind = .Reaped, pid = b},
			{kind = .Spawned, pid = respawned(1, 1)},
			{kind = .Reaped, pid = x},
			{kind = .Reaped, pid = outside_table},
			{kind = .Reaped, pid = f.supervisor.pid},
		},
	)
	testing.expect_value(t, f.clock.virtual_tick_ns, clock_before)
	testing.expect(t, f.supervisor.pending_stop_signals == nil, "no stop signal may stay put aside")
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}

@(private = "file")
kill_the_rest_after_the_first_round :: proc(f: ^Group_Fixture, reaped: PID) {
	if reaped != f.pids[3] do return
	die(f, 1)
	signal := new(Spawn_Signal, actor_system_allocator)
	signal.pid = f.pids[5]
	push_spawn_signal(f.supervisor, signal)
	die(f, 5)
	die(f, 4)
}

@(test)
signals_put_aside_across_poll_rounds_are_handled_in_arrival_order_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .REST_FOR_ONE, 6)
	defer destroy_group_fixture(&f)
	early, late, a, first_waited, second_waited, spawned_in_wait := f.pids[0], f.pids[1], f.pids[2], f.pids[3], f.pids[4], f.pids[5]
	pop(&f.supervisor.children)
	for i in 2 ..< 5 do f.supervisor.children[i].restart.spawn_func = refuse_respawn
	for i in ([]int{0, 1, 5}) do f.children[i].opts.restart_policy = .TEMPORARY
	f.after_reap = kill_the_rest_after_the_first_round

	hook := Die_On_Kill {
		backing = context.allocator,
		fixture = &f,
		deaths  = {3},
	}
	f.captured = make([dynamic]ti.Captured_Terminate, runtime.Allocator{procedure = die_on_kill_allocator_proc, data = &hook})

	die(&f, 2)
	die(&f, 0)
	{
		context.logger = log.nil_logger()
		process_stop_signals(f.supervisor)
	}

	expect_events(
		t,
		{
			{kind = .Reaped, pid = a},
			{kind = .Terminated, pid = a, reason = .ABNORMAL, will_restart = true},
			{kind = .Reaped, pid = first_waited},
			{kind = .Reaped, pid = second_waited},
			{kind = .Reaped, pid = early},
			{kind = .Terminated, pid = early, reason = .ABNORMAL, will_restart = false},
			{kind = .Reaped, pid = late},
			{kind = .Terminated, pid = late, reason = .ABNORMAL, will_restart = false},
			{kind = .Reaped, pid = spawned_in_wait},
			{kind = .Terminated, pid = spawned_in_wait, reason = .ABNORMAL, will_restart = false},
		},
	)
	expect_table(t, &f, {a, first_waited, second_waited})
	testing.expect(t, f.supervisor.pending_stop_signals == nil, "no stop signal may stay put aside")
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}

@(test)
remote_child_group_restart_handles_the_local_signals_it_put_aside_test :: proc(t: ^testing.T) {
	f: Group_Fixture
	make_group_fixture(&f, .REST_FOR_ONE, 3)
	defer destroy_group_fixture(&f)
	x, b := f.pids[0], f.pids[2]
	remote := pack_pid(Handle{idx = 95, gen = 1}, NODE.node_id + 1)
	f.supervisor.children[1].pid = remote
	f.children[0].opts.restart_policy = .TEMPORARY
	f.intercept.self_pid = u64(remote)

	hook := Die_On_Kill {
		backing = context.allocator,
		fixture = &f,
		deaths  = {0, 2},
	}
	f.captured = make([dynamic]ti.Captured_Terminate, runtime.Allocator{procedure = die_on_kill_allocator_proc, data = &hook})

	system_entries := make([]Entry(Message), 2)
	defer delete(system_entries)
	mpsc_init_external(&f.supervisor.system_mailbox, system_entries, entries_zeroed = true)
	f.supervisor.allocator = context.allocator
	pool_init(&f.supervisor.pool, context.allocator)
	defer cleanup_pool(&f.supervisor.pool)
	ctx := message_processing_context_init(f.supervisor, context.allocator)

	stopped := Actor_Stopped {
		reason         = .ABNORMAL,
		restart_policy = .PERMANENT,
		child_name     = "remote-child",
		child_index    = -1,
	}
	testing.expect_value(t, send(f.supervisor.pid, stopped, f.supervisor), Send_Error.OK)
	testing.expect(t, process_system_mailbox(f.supervisor, &ctx), "the supervisor must keep running")
	free(raw_data(ctx.message_batch))
	free(raw_data(ctx.free_buffer.entries))

	expect_events(
		t,
		{
			{kind = .Terminated, pid = remote, reason = .ABNORMAL, will_restart = true},
			{kind = .Reaped, pid = b},
			{kind = .Spawned, pid = respawned(1, 1)},
			{kind = .Restarted, pid = remote, new_pid = respawned(1, 1), count = 1},
			{kind = .Started, pid = respawned(1, 1)},
			{kind = .Spawned, pid = respawned(2, 1)},
			{kind = .Restarted, pid = b, new_pid = respawned(2, 1), count = 0},
			{kind = .Started, pid = respawned(2, 1)},
			{kind = .Reaped, pid = x},
			{kind = .Terminated, pid = x, reason = .ABNORMAL, will_restart = false},
		},
	)
	expect_table(t, &f, {respawned(1, 1), respawned(2, 1)})
	expect_killed(t, &f, {b})
	testing.expect(t, f.supervisor.pending_stop_signals == nil, "no stop signal may stay put aside")
	testing.expect(t, sync.atomic_load(&f.supervisor.stopped_head) == nil, "every stop signal must be taken")
}
