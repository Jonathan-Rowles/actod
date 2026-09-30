package actod

import "../../test_harness/ti"
import "base:runtime"
import "core:sync"
import "core:testing"

@(private = "file")
Spawn_Signal_Fixture :: struct {
	actor:          ^Actor,
	handle:         ^Pooled_Actor_Handle,
	mailbox:        []Entry(Message),
	system_mailbox: []Entry(Message),
}

@(private = "file")
g_idle_hook_calls: int

@(private = "file")
count_idle_hook_call :: proc(data: rawptr) {
	g_idle_hook_calls += 1
}

@(private = "file")
make_spawn_signal_fixture :: proc() -> Spawn_Signal_Fixture {
	f: Spawn_Signal_Fixture
	f.actor = new(Actor)
	f.actor.state = .RUNNING
	f.actor.children = make([dynamic]Supervised_Child)
	f.actor.behaviour.on_idle = count_idle_hook_call
	f.mailbox = make([]Entry(Message), 2)
	f.system_mailbox = make([]Entry(Message), 2)
	mpsc_init_external(&f.actor.mailbox, f.mailbox, entries_zeroed = true)
	mpsc_init_external(&f.actor.system_mailbox, f.system_mailbox, entries_zeroed = true)
	f.handle = new(Pooled_Actor_Handle)
	f.handle.actor_ptr = f.actor
	f.handle.mailbox = &f.actor.mailbox
	f.handle.system_mailbox = &f.actor.system_mailbox
	return f
}

@(private = "file")
destroy_spawn_signal_fixture :: proc(f: ^Spawn_Signal_Fixture) {
	delete(f.actor.children)
	delete(f.mailbox)
	delete(f.system_mailbox)
	free(f.handle)
	free(f.actor)
}

@(private = "file")
unregistered_local_pid :: proc(gen: u16) -> PID {
	return pack_pid(Handle{idx = 0, gen = gen})
}

@(private = "file")
idle_hook_runs :: proc(f: ^Spawn_Signal_Fixture) -> bool {
	g_idle_hook_calls = 0
	ctx: Message_Processing_Context
	wait_for_messages_if_idle(f.actor, &ctx)
	return g_idle_hook_calls == 1
}

@(test)
spawn_signal_keeps_every_idle_predicate_awake_test :: proc(t: ^testing.T) {
	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)

	testing.expect(t, !mailbox_has_messages(f.actor), "an empty actor must look idle to its own loop")
	testing.expect(t, !has_pending_messages(f.handle), "an empty actor must look idle to its worker")
	testing.expect(t, idle_hook_runs(&f), "an empty dedicated-thread actor must go idle")

	signal := new(Spawn_Signal, actor_system_allocator)
	signal.pid = 77
	push_spawn_signal(f.actor, signal)

	testing.expect(
		t,
		mailbox_has_messages(f.actor),
		"a spawn signal pushed before the park decision must keep the pooled loop from parking",
	)
	testing.expect(
		t,
		has_pending_messages(f.handle),
		"a spawn signal pushed before the worker's re-check must reschedule the actor",
	)
	testing.expect(
		t,
		!idle_hook_runs(&f),
		"a spawn signal pushed before the dedicated thread's idle check must keep it from waiting",
	)

	process_spawn_signals(f.actor)

	testing.expect_value(t, len(f.actor.children), 1)
	if len(f.actor.children) == 1 do testing.expect_value(t, f.actor.children[0].pid, PID(77))
	testing.expect(t, sync.atomic_load(&f.actor.spawned_head) == nil, "the drain must empty the chain")
	testing.expect(t, !mailbox_has_messages(f.actor), "a drained actor must look idle again")
	testing.expect(t, !has_pending_messages(f.handle), "a drained actor must look idle to its worker again")
}

@(test)
spawn_signals_register_once_each_in_push_order_test :: proc(t: ^testing.T) {
	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)
	f.actor.behaviour.on_idle = nil

	signal_spawn_to_parent(f.actor, 11)
	signal_spawn_to_parent(f.actor, 12)
	signal_spawn_to_parent(f.actor, 13)
	testing.expect_value(t, len(f.actor.children), 0)

	process_spawn_signals(f.actor)
	process_spawn_signals(f.actor)

	if !testing.expect_value(t, len(f.actor.children), 3) do return
	testing.expect_value(t, f.actor.children[0].pid, PID(11))
	testing.expect_value(t, f.actor.children[1].pid, PID(12))
	testing.expect_value(t, f.actor.children[2].pid, PID(13))
	testing.expect(t, sync.atomic_load(&f.actor.spawned_head) == nil, "the drain must empty the chain")
}

@(test)
spawn_signal_to_a_closed_parent_is_released_by_its_pusher_test :: proc(t: ^testing.T) {
	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)
	f.actor.state = .TERMINATED
	sync.atomic_store(&f.actor.spawned_closed, true)

	for gen in u16(1) ..= 64 do signal_spawn_to_parent(f.actor, unregistered_local_pid(gen))

	testing.expect(
		t,
		sync.atomic_load(&f.actor.spawned_head) == nil,
		"a pusher that finds the chain closed must take its signal back off it",
	)
	testing.expect_value(t, len(f.actor.children), 0)
}

@(test)
spawn_signals_left_on_a_dead_parent_are_released_test :: proc(t: ^testing.T) {
	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)
	f.actor.state = .STOPPING

	for gen in u16(1) ..= 64 do signal_spawn_to_parent(f.actor, unregistered_local_pid(gen))
	testing.expect(t, sync.atomic_load(&f.actor.spawned_head) != nil, "a stopping parent keeps signals for its reaper")

	f.actor.state = .TERMINATED
	sync.atomic_store(&f.actor.spawned_closed, true)
	release_spawn_signals(f.actor)

	testing.expect(t, sync.atomic_load(&f.actor.spawned_head) == nil, "the reaper must empty the chain")
	testing.expect_value(t, len(f.actor.children), 0)
}

@(private = "file")
Swapped_Registry :: struct {
	saved: PID_Map(rawptr, PID),
	test:  ^PID_Map(rawptr, PID),
}

@(private = "file")
swap_in_test_registry :: proc() -> Swapped_Registry {
	sync.lock(&global_registry_swap_mutex)
	swapped := Swapped_Registry {
		saved = NODE.actor_registry,
		test  = make_test_registry(),
	}
	clear(swapped.test)
	NODE.actor_registry = swapped.test^
	return swapped
}

@(private = "file")
restore_registry :: proc(swapped: ^Swapped_Registry) {
	NODE.actor_registry = swapped.saved
	free(swapped.test)
	sync.unlock(&global_registry_swap_mutex)
}

@(private = "file")
Terminate_Capture :: struct {
	captured:  [dynamic]ti.Captured_Terminate,
	intercept: ti.Test_Intercept,
}

@(private = "file")
install_terminate_capture :: proc(capture: ^Terminate_Capture) {
	capture.intercept.terminate_capture = &capture.captured
	ti.test_intercept = &capture.intercept
}

@(private = "file")
uninstall_terminate_capture :: proc(capture: ^Terminate_Capture) {
	ti.test_intercept = nil
	delete(capture.captured)
}

@(private = "file")
expect_only_shutdown_of :: proc(t: ^testing.T, capture: ^Terminate_Capture, child_pid: PID, message: string) {
	if !testing.expect_value(t, len(capture.captured), 1) do return
	testing.expect(t, PID(capture.captured[0].pid) == child_pid, message)
	testing.expect_value(t, capture.captured[0].reason, ti.Termination_Reason.SHUTDOWN)
}

@(private = "file")
g_terminated_child_pid: PID

@(private = "file")
record_terminated_child :: proc(
	data: rawptr,
	child_pid: PID,
	child_name: string,
	reason: Termination_Reason,
	will_restart: bool,
) {
	g_terminated_child_pid = child_pid
}

@(test)
spawn_signal_taken_with_its_child_stop_signal_registers_the_child_first_test :: proc(t: ^testing.T) {
	sync.lock(&global_registry_swap_mutex)
	defer sync.unlock(&global_registry_swap_mutex)

	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)
	f.actor.pid = pack_pid(Handle{idx = 1, gen = 1})
	f.actor.behaviour.on_child_terminated = record_terminated_child
	g_terminated_child_pid = 0

	child_pid := pack_pid(Handle{idx = 2, gen = 1})
	child := new(Actor)
	defer free(child)
	child.stop_signal.pid = child_pid
	child.stop_signal.reason = .ABNORMAL
	child.opts.restart_policy = .TEMPORARY

	signal_spawn_to_parent(f.actor, child_pid)
	push_stop_signal(f.actor, child)
	process_stop_signals(f.actor)

	testing.expect(
		t,
		g_terminated_child_pid == child_pid,
		"a child whose spawn signal was pending when its stop signal was taken must be known when its death is handled",
	)
	testing.expect_value(t, len(f.actor.children), 0)
	testing.expect(t, sync.atomic_load(&f.actor.spawned_head) == nil, "the stop drain must take the spawn signal")
}

@(test)
spawn_signal_pushed_after_the_reaper_closed_the_chain_is_released_by_its_pusher_test :: proc(t: ^testing.T) {
	swapped := swap_in_test_registry()
	defer restore_registry(&swapped)

	capture: Terminate_Capture
	install_terminate_capture(&capture)
	defer uninstall_terminate_capture(&capture)

	handle := new(Pooled_Actor_Handle)
	defer free(handle)
	sync.atomic_store(&handle.terminated, true)
	parent := new(Actor, actor_system_allocator)
	parent.state = .THREAD_STOPPED
	parent.pool_handle = handle
	parent_pid, added := add(&NODE.actor_registry, rawptr(parent), "reaped_parent")
	if !testing.expect(t, added, "the parent should register") {
		free(parent, actor_system_allocator)
		return
	}

	if sync.atomic_load(&NODE.reclaim.epoch) == 0 do sync.atomic_store(&NODE.reclaim.epoch, 1)
	reclaim_pin()
	pinned_parent := cast(^Actor)get(&NODE.actor_registry, parent_pid)

	cleanup_terminated_actor(parent_pid, rawptr(parent))
	_, still_registered := get(&NODE.actor_registry, parent_pid)
	testing.expect(t, !still_registered, "cleanup must remove the parent from the registry")
	testing.expect_value(t, sync.atomic_load(&pinned_parent.state), Actor_State.TERMINATED)

	child_pid := unregistered_local_pid(1)
	signal_spawn_to_parent(pinned_parent, child_pid)

	testing.expect(
		t,
		sync.atomic_load(&pinned_parent.spawned_head) == nil,
		"a pusher that pushes after cleanup released the chain must find it closed and take its signal back",
	)
	expect_only_shutdown_of(t, &capture, child_pid, "the pusher must shut down the child its dead parent will never drain")

	pinned_parent.pool_handle = nil
	reclaim_unpin()
	reclaim_scan()
}

@(private = "file")
Copy_Probe :: struct {
	backing:     runtime.Allocator,
	lock:        ^sync.Mutex,
	allocations: int,
	lock_held:   bool,
	pinned:      bool,
}

@(private = "file")
copy_probe_allocator_proc :: proc(
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
	probe := cast(^Copy_Probe)allocator_data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		probe.allocations += 1
		probe.pinned = tls_reclaim_depth > 0
		probe.lock_held = !sync.mutex_try_lock(probe.lock)
		if !probe.lock_held do sync.mutex_unlock(probe.lock)
	}
	return probe.backing.procedure(probe.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private = "file")
probe_foreign_get_children :: proc(t: ^testing.T) -> Copy_Probe {
	swapped := swap_in_test_registry()
	defer restore_registry(&swapped)

	parent := new(Actor)
	defer free(parent)
	parent.state = .RUNNING
	parent.children = make([dynamic]Supervised_Child)
	defer delete(parent.children)
	append(&parent.children, Supervised_Child{pid = 21}, Supervised_Child{pid = 22})
	parent_pid, added := add(&NODE.actor_registry, rawptr(parent), "copied_parent")
	testing.expect(t, added, "the parent should register")

	probe := Copy_Probe {
		backing = context.allocator,
		lock    = &parent.children_lock,
	}
	copied: []PID
	{
		context.allocator = runtime.Allocator {
			procedure = copy_probe_allocator_proc,
			data      = &probe,
		}
		copied = get_children(parent_pid)
	}
	defer delete(copied)

	testing.expect_value(t, probe.allocations, 1)
	if testing.expect_value(t, len(copied), 2) {
		testing.expect_value(t, copied[0], PID(21))
		testing.expect_value(t, copied[1], PID(22))
	}
	remove(&NODE.actor_registry, parent_pid)
	return probe
}

@(test)
get_children_copies_under_the_children_lock_test :: proc(t: ^testing.T) {
	probe := probe_foreign_get_children(t)
	testing.expect(
		t,
		probe.lock_held,
		"a foreign get_children must hold children_lock while it copies, so the owner cannot reallocate the table under it",
	)
}

@(test)
get_children_copies_under_the_reclaim_pin_test :: proc(t: ^testing.T) {
	probe := probe_foreign_get_children(t)
	testing.expect(
		t,
		probe.pinned,
		"a foreign get_children must hold the reclaim pin while it copies, so the reaper cannot free the parent under it",
	)
}

@(test)
spawn_whose_parent_was_reaped_before_the_lookup_shuts_the_child_down_test :: proc(t: ^testing.T) {
	swapped := swap_in_test_registry()
	defer restore_registry(&swapped)

	capture: Terminate_Capture
	install_terminate_capture(&capture)
	defer uninstall_terminate_capture(&capture)

	reaped_parent_pid := pack_pid(Handle{idx = 1, gen = 1})
	child_pid := unregistered_local_pid(1)
	attach_to_parent(reaped_parent_pid, child_pid)

	expect_only_shutdown_of(t, &capture, child_pid, "a child whose parent left the registry mid-spawn must be shut down")
}

@(test)
node_forgets_each_child_it_reaps_test :: proc(t: ^testing.T) {
	swapped := swap_in_test_registry()
	defer restore_registry(&swapped)

	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)
	f.actor.pid = pack_pid(Handle{idx = 1, gen = 1})

	recorded := new(Actor)
	defer free(recorded)
	recorded.parent = f.actor.pid
	recorded.stop_signal.pid = pack_pid(Handle{idx = 2, gen = 1})
	record_direct_child(f.actor, recorded.stop_signal.pid)

	live_pid := pack_pid(Handle{idx = 3, gen = 1})
	record_direct_child(f.actor, live_pid)

	pending := new(Actor)
	defer free(pending)
	pending.parent = f.actor.pid
	pending.stop_signal.pid = pack_pid(Handle{idx = 4, gen = 1})
	signal_spawn_to_parent(f.actor, pending.stop_signal.pid)

	push_stop_signal(f.actor, recorded)
	push_stop_signal(f.actor, pending)
	reap_stop_signals_at_node(f.actor, take_stop_signals(f.actor), true)

	if testing.expect_value(t, len(f.actor.children), 1) {
		testing.expect(t, f.actor.children[0].pid == live_pid, "only the live child keeps its record")
	}
	testing.expect(
		t,
		sync.atomic_load(&f.actor.spawned_head) == nil,
		"a child whose spawn signal was pending when its corpse was taken must be registered, then forgotten",
	)
}

@(test)
node_reaping_off_its_own_thread_leaves_its_table_alone_test :: proc(t: ^testing.T) {
	swapped := swap_in_test_registry()
	defer restore_registry(&swapped)

	f := make_spawn_signal_fixture()
	defer destroy_spawn_signal_fixture(&f)
	f.actor.pid = pack_pid(Handle{idx = 1, gen = 1})

	recorded := new(Actor)
	defer free(recorded)
	recorded.parent = f.actor.pid
	recorded.stop_signal.pid = pack_pid(Handle{idx = 2, gen = 1})
	record_direct_child(f.actor, recorded.stop_signal.pid)

	pending_pid := pack_pid(Handle{idx = 3, gen = 1})
	signal_spawn_to_parent(f.actor, pending_pid)

	push_stop_signal(f.actor, recorded)
	reap_stop_signals_at_node(f.actor, take_stop_signals(f.actor), false)

	testing.expect(t, sync.atomic_load(&f.actor.stopped_head) == nil, "the corpse must still be reaped")
	if testing.expect_value(t, len(f.actor.children), 1) {
		testing.expect(
			t,
			f.actor.children[0].pid == recorded.stop_signal.pid,
			"a thread that is not the node's must not write the node's table",
		)
	}
	testing.expect(
		t,
		sync.atomic_load(&f.actor.spawned_head) != nil,
		"a thread that is not the node's must not drain the node's spawn signals",
	)

	process_spawn_signals(f.actor)
}
