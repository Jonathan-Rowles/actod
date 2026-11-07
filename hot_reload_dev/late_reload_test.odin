package hot_reload_dev

import actod "../src/actod"
import hot_reload "../src/pkgs/hot_reload"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:time"

COUNTER_V2_FIXTURE_DIR :: #directory + "../src/pkgs/hot_reload/mocks/counter_v2"
BACKLOGGED_ACTOR_NAME :: "backlogged_counter"
RELOADS_PAST_UNLOAD :: 5
LATE_RELOAD_LIMIT :: 10 * time.Second

node_test_mutex: sync.Mutex

Backlogged_Counter :: struct {
	count: i32,
}

Hold_Handler :: struct {}
Late_Reload_Tick :: struct {}

Backlog_Gate :: struct {
	handler_entered: sync.Sema,
	release:         sync.Sema,
}

backlog_gate: Backlog_Gate

@(init)
register_late_reload_messages :: proc "contextless" () {
	actod.register_message_type(Hold_Handler)
	actod.register_message_type(Late_Reload_Tick)
}

backlogged_counter_handle_message :: proc(
	data: ^Backlogged_Counter,
	from: actod.PID,
	content: any,
) {
	switch _ in content {
	case Hold_Handler:
		sync.sema_post(&backlog_gate.handler_entered)
		sync.sema_wait(&backlog_gate.release)
	}
}

backlogged_counter_behaviour := actod.Actor_Behaviour(Backlogged_Counter) {
	handle_message = backlogged_counter_handle_message,
}

module_loaded :: proc(generation: u32) -> bool {
	sync.rw_mutex_shared_lock(&hot_module_table_mu)
	defer sync.rw_mutex_shared_unlock(&hot_module_table_mu)
	return generation in hot_module_table
}

wait_for_handle_message :: proc(pid: actod.PID, expected: rawptr) -> bool {
	started := time.tick_now()
	for time.tick_since(started) < LATE_RELOAD_LIMIT {
		entry, alive := actod.get(&actod.NODE.actor_registry, pid)
		actor := cast(^actod.Actor)entry
		if alive && rawptr(actor.handle_message) == expected do return true
		time.sleep(time.Millisecond)
	}
	return false
}

wait_for_count :: proc(pid: actod.PID, expected: i32) -> bool {
	started := time.tick_now()
	for time.tick_since(started) < LATE_RELOAD_LIMIT {
		entry, alive := actod.get(&actod.NODE.actor_registry, pid)
		actor := cast(^actod.Actor)entry
		if alive && (cast(^Backlogged_Counter)actor.data).count == expected do return true
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
test_late_reload_of_unloaded_generation_keeps_current_behaviour :: proc(t: ^testing.T) {
	sync.mutex_lock(&node_test_mutex)
	defer sync.mutex_unlock(&node_test_mutex)

	sys_tmp, _ := os.temp_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join(
		{sys_tmp, fmt.tprintf("actod_late_reload_%d", os.get_pid())},
		context.temp_allocator,
	)
	os.make_directory(tmp_dir)
	defer _ = os.remove_all(tmp_dir)

	compiled_path := fmt.tprintf("%s/counter_v2%s", tmp_dir, hot_reload.SHARED_LIB_EXT)
	built := hot_reload.compile_module(COUNTER_V2_FIXTURE_DIR, compiled_path)
	if !testing.expect(t, built.ok, built.error_msg) do return
	compiled_bytes, read_err := os.read_entire_file_from_path(
		compiled_path,
		context.temp_allocator,
	)
	if !testing.expect(t, read_err == nil, "could not read the compiled fixture") do return

	so_paths: [RELOADS_PAST_UNLOAD]string
	for &so_path, index in so_paths {
		so_path = fmt.tprintf(
			"%s/counter_v2_gen%d%s",
			tmp_dir,
			index + 1,
			hot_reload.SHARED_LIB_EXT,
		)
		write_err := os.write_entire_file(so_path, compiled_bytes)
		if !testing.expect(t, write_err == nil, "could not copy the compiled fixture") do return
	}

	actod.node_init("late-reload", actod.make_node_config(worker_count = 1))
	defer actod.shutdown_node()

	pid, spawned := actod.spawn(
		BACKLOGGED_ACTOR_NAME,
		Backlogged_Counter{},
		backlogged_counter_behaviour,
		actod.make_actor_config(use_dedicated_os_thread = true),
	)
	if !testing.expect(t, spawned, "spawn failed") do return

	data: Hot_Reload_Actor_Data
	defer {
		_ = actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
		hot_reload_terminate(&data)
		delete(hot_module_table)
		hot_module_table = nil
	}

	testing.expect_value(t, actod.send_message(pid, Hold_Handler{}), actod.Send_Error.OK)
	if !testing.expect(
		t,
		sync.sema_wait_with_timeout(&backlog_gate.handler_entered, LATE_RELOAD_LIMIT),
		"the actor never entered its handler",
	) {
		sync.sema_post(&backlog_gate.release)
		return
	}

	meta := Actor_Type_Meta {
		state_type_name = "Counter_State",
		state_size      = size_of(Backlogged_Counter),
	}
	append(&meta.behaviour_field_names, "handle_message")
	append(&meta.actor_pids, pid)
	data.actor_meta[BACKLOGGED_ACTOR_NAME] = meta

	for so_path in so_paths do load_and_swap(&data, {BACKLOGGED_ACTOR_NAME}, so_path)

	testing.expect(
		t,
		!module_loaded(1),
		"generation 1 was unloaded but is still in the module table",
	)
	for generation in u32(2) ..= RELOADS_PAST_UNLOAD {
		testing.expect(
			t,
			module_loaded(generation),
			fmt.tprintf("generation %d should still be loaded", generation),
		)
	}

	newest_handle_message := data.modules[BACKLOGGED_ACTOR_NAME].symbols[0].ptr
	sync.sema_post(&backlog_gate.release)

	if !testing.expect(
		t,
		wait_for_handle_message(pid, newest_handle_message),
		"the drained actor did not end on the newest generation",
	) {
		return
	}

	testing.expect_value(t, actod.send_message(pid, Late_Reload_Tick{}), actod.Send_Error.OK)
	testing.expect(t, wait_for_count(pid, 10), "the newest generation did not handle the tick")
}
