package integration

import "../actod"
import "../pkgs/threads_act"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "network/shared"

INTEGRATION_TEST_BIN ::
	"bin/integration_test" when ODIN_OS != .Windows else "bin\\integration_test.exe"


Test_Entry :: struct {
	name:                  string,
	test_proc:             proc(t: ^testing.T),
	port:                  int,
	node_name:             string,
	is_networked:          bool,
	worker_count:          int,
	hot_reload_dev:        bool,
	hot_reload_watch_path: string,
}

ALL_TESTS :: []Test_Entry {
	// Core actor tests
	{name = "test_actor_lifecycle", test_proc = test_actor_lifecycle},
	{name = "test_request_reply_pattern", test_proc = test_request_reply_pattern},
	{name = "test_pipeline_pattern", test_proc = test_pipeline_pattern},
	{name = "test_broadcast_pattern", test_proc = test_broadcast_pattern},
	{name = "test_concurrent_actor_operations", test_proc = test_concurrent_actor_operations},
	{name = "test_stress_message_throughput", test_proc = test_stress_message_throughput},
	{name = "test_pool_integration", test_proc = test_pool_integration},
	{
		name = "test_pool_cleanup_on_actor_termination",
		test_proc = test_pool_cleanup_on_actor_termination,
	},
	{name = "test_registry_consistency", test_proc = test_registry_consistency},
	{name = "test_worker_contention", test_proc = test_worker_contention, worker_count = 2},

	// Supervisor hierarchy tests
	{name = "test_supervisor_child_lifecycle", test_proc = test_supervisor_child_lifecycle},
	{name = "test_one_for_one_strategy", test_proc = test_one_for_one_strategy},
	{name = "test_permanent_restart_policy", test_proc = test_permanent_restart_policy},
	{name = "test_add_child_dynamically", test_proc = test_add_child_dynamically},
	{name = "test_remove_child_dynamically", test_proc = test_remove_child_dynamically},
	{name = "test_adopt_existing_actor", test_proc = test_adopt_existing_actor},
	{name = "test_self_termination_reasons", test_proc = test_self_termination_reasons},
	{name = "test_transient_restart_policy", test_proc = test_transient_restart_policy},
	{name = "test_rest_for_one_strategy", test_proc = test_rest_for_one_strategy},
	{name = "test_string_handling", test_proc = test_string_handling},
	{name = "test_byte_slice_handling", test_proc = test_byte_slice_handling},
	{name = "test_union_message_handling", test_proc = test_union_message_handling},

	// Behaviour registry tests
	{name = "test_spawn_by_name", test_proc = test_spawn_by_name},

	// Pub/Sub tests
	{name = "test_pubsub_broadcast", test_proc = test_pubsub_broadcast},
	{name = "test_pubsub_auto_cleanup", test_proc = test_pubsub_auto_cleanup},

	// Topic pub/sub tests
	{name = "test_topic_publish", test_proc = test_topic_publish},
	{name = "test_topic_auto_cleanup", test_proc = test_topic_auto_cleanup},
	{name = "test_topic_unsubscribe", test_proc = test_topic_unsubscribe},

	// Timer tests
	{name = "test_timer_repeating", test_proc = test_timer_repeating},
	{name = "test_timer_one_shot", test_proc = test_timer_one_shot},
	{name = "test_timer_cancel", test_proc = test_timer_cancel},
	{name = "test_timer_multiple", test_proc = test_timer_multiple},
	{name = "test_timer_cleanup_on_termination", test_proc = test_timer_cleanup_on_termination},

	// Panic recovery tests
	{name = "test_actor_panic_recovery", test_proc = test_actor_panic_recovery},
	{
		name = "test_actor_panic_supervisor_restart",
		test_proc = test_actor_panic_supervisor_restart,
	},
	{name = "test_actor_panic_in_init", test_proc = test_actor_panic_in_init},

	// Slower tests
	{name = "test_restart_limit_within_window", test_proc = test_restart_limit_within_window},
	{name = "test_restart_limit_window_reset", test_proc = test_restart_limit_window_reset},
	{name = "test_one_for_all_strategy", test_proc = test_one_for_all_strategy},

	// Distributed tests - each gets a unique base port range for parallel execution
	{
		name = "test_distributed_communication",
		test_proc = test_distributed_communication,
		port = 17000,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_distributed_network_message_routing",
		test_proc = test_distributed_network_message_routing,
		port = 17010,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_distributed_concurrent_network_messages",
		test_proc = test_distributed_concurrent_network_messages,
		port = 17020,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_connection_lifecycle",
		test_proc = test_connection_lifecycle,
		port = 17030,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_connection_reconnection",
		test_proc = test_connection_reconnection,
		port = 17040,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_lifecycle_broadcast",
		test_proc = test_lifecycle_broadcast,
		port = 17050,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_registry_exchange",
		test_proc = test_registry_exchange,
		port = 17060,
		node_name = "TestNode1",
		is_networked = true,
	},
	// Cross-node supervision tests
	{
		name = "test_remote_spawn_basic",
		test_proc = test_remote_spawn_basic,
		port = 17070,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_child_crash_notification",
		test_proc = test_remote_child_crash_notification,
		port = 17080,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_one_for_one_restart",
		test_proc = test_remote_one_for_one_restart,
		port = 17090,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_one_for_all_restart",
		test_proc = test_remote_one_for_all_restart,
		port = 17100,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_rest_for_one_restart",
		test_proc = test_remote_rest_for_one_restart,
		port = 17110,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_restart_via_registry_lookup",
		test_proc = test_remote_restart_via_registry_lookup,
		port = 17120,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_spawn_invalid_func_name",
		test_proc = test_remote_spawn_invalid_func_name,
		port = 17130,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_spawn_timeout",
		test_proc = test_remote_spawn_timeout,
		port = 17140,
		node_name = "TestNode1",
		is_networked = true,
	},
	// Mesh discovery test (3-node topology A↔B↔C)
	{
		name = "test_mesh_discovery",
		test_proc = test_mesh_discovery,
		port = 17150,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_distributed_pubsub_broadcast",
		test_proc = test_distributed_pubsub_broadcast,
		port = 17160,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_distributed_union_messages",
		test_proc = test_distributed_union_messages,
		port = 17170,
		node_name = "TestNode1",
		is_networked = true,
	},
	{name = "test_node_shutdown_under_load", test_proc = test_node_shutdown_under_load},

	// Hot reload tests (Phase 1a)
	{name = "test_hot_reload_basic", test_proc = test_hot_reload_basic},
	{name = "test_hot_reload_state_preserved", test_proc = test_hot_reload_state_preserved},
	{name = "test_reload_behaviour_system_msg", test_proc = test_reload_behaviour_system_msg},
	{name = "test_rollback", test_proc = test_rollback},

	// Hot reload tests (Phase 1b — file watcher + dev workflow)
	{name = "test_file_watcher_detection", test_proc = test_file_watcher_detection},
	{name = "test_file_watcher_excludes_tmp", test_proc = test_file_watcher_excludes_tmp},
	{name = "test_hot_reload_under_load", test_proc = test_hot_reload_under_load},
}

test_base_port: int

run_single_test :: proc(test_name: string) -> bool {
	for entry in ALL_TESTS {
		if entry.name == test_name {
			return run_test_entry(entry)
		}
	}

	fmt.eprintf("Unknown test: %s\n", test_name)
	return false
}

run_test_entry :: proc(entry: Test_Entry) -> bool {
	port := entry.port if entry.port != 0 else 8080
	node_name := entry.node_name if entry.node_name != "" else entry.name

	if entry.is_networked {
		test_base_port = port
		shared.check_port_available(port)
	}

	network_config := actod.make_network_config(
		auth_password = "test_dist_password",
		port = port,
		heartbeat_interval = 100 * time.Millisecond,
		heartbeat_timeout = 300 * time.Millisecond,
		reconnect_initial_delay = 200 * time.Millisecond,
		reconnect_retry_delay = 300 * time.Millisecond,
	)

	node_opts := actod.make_node_config(
		network = network_config,
		actor_config = actod.make_actor_config(logging = actod.make_log_config(level = .Fatal)),
		hot_reload_dev = entry.hot_reload_dev,
		hot_reload_watch_path = entry.hot_reload_watch_path,
	)
	if entry.worker_count > 0 {
		node_opts.worker_count = entry.worker_count
	}

	actod.NODE_INIT(name = node_name, opts = node_opts)

	wait_for_node()

	t := testing.T{}
	entry.test_proc(&t)
	failed := testing.failed(&t)

	if actod.NODE.started {
		actod.SHUTDOWN_NODE()
	}

	final_count := actod.num_used(&actod.global_registry)
	if final_count > 0 {
		fmt.eprintf("Test %s: zombie actors detected (%d remaining)\n", entry.name, final_count)
		return false
	}

	return !failed
}

Test_Result :: struct {
	name:      string,
	success:   bool,
	exit_code: int,
}

Test_Thread_Context :: struct {
	entry:  Test_Entry,
	result: ^Test_Result,
}

TEST_TIMEOUT_SECONDS :: 30

Watchdog_Data :: struct {
	process:   os.Process,
	cancelled: bool,
	fired:     bool,
}

test_watchdog_proc :: proc(data: rawptr) {
	wd := cast(^Watchdog_Data)data
	for _ in 0 ..< TEST_TIMEOUT_SECONDS * 4 {
		if sync.atomic_load_explicit(&wd.cancelled, .Acquire) {
			return
		}
		time.sleep(250 * time.Millisecond)
	}
	if !sync.atomic_load_explicit(&wd.cancelled, .Acquire) {
		sync.atomic_store_explicit(&wd.fired, true, .Release)
		_ = os.process_kill(wd.process)
	}
}

run_test_in_subprocess :: proc(test_name: string) -> Test_Result {
	result := Test_Result {
		name    = test_name,
		success = false,
	}

	proc_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env([]string{fmt.tprintf("ACTOD_TEST_RUN=%s", test_name)}),
	}

	process, err := os.process_start(proc_desc)
	if err != nil {
		fmt.eprintf("Failed to start test process for %s: %v\n", test_name, err)
		return result
	}

	watchdog_data := Watchdog_Data {
		process = process,
	}
	watchdog := thread.create_and_start_with_data(&watchdog_data, test_watchdog_proc)

	state, wait_err := os.process_wait(process)

	sync.atomic_store_explicit(&watchdog_data.cancelled, true, .Release)
	thread.join(watchdog)
	thread.destroy(watchdog)

	if watchdog_data.fired {
		result.exit_code = -1
		return result
	}

	if wait_err != nil {
		fmt.eprintf("Failed to wait for test %s: %v\n", test_name, wait_err)
		return result
	}

	result.exit_code = state.exit_code
	result.success = state.exit_code == 0

	return result
}

test_thread_proc :: proc(data: rawptr) {
	ctx := cast(^Test_Thread_Context)data
	ctx.result^ = run_test_in_subprocess(ctx.entry.name)
	if ctx.result.success {
		fmt.printf("  PASS: %s\n", ctx.result.name)
	} else if ctx.result.exit_code == -1 {
		fmt.printf("  TIMEOUT: %s (killed after %ds)\n", ctx.result.name, TEST_TIMEOUT_SECONDS)
	} else {
		fmt.printf("  FAIL: %s (exit code: %d)\n", ctx.result.name, ctx.result.exit_code)
	}
}

run_tests_parallel :: proc(t: ^testing.T) {
	tests := ALL_TESTS

	results := make([]Test_Result, len(tests))
	defer delete(results)

	contexts := make([]Test_Thread_Context, len(tests))
	defer delete(contexts)

	threads := make([]^thread.Thread, len(tests))
	defer {
		for th in threads {
			if th != nil {
				thread.destroy(th)
			}
		}
		delete(threads)
	}

	max_concurrent := max(2, threads_act.get_cpu_count() * 2)
	fmt.printf("Running %d tests in parallel (max %d at a time)...\n", len(tests), max_concurrent)

	for batch_start := 0; batch_start < len(tests); batch_start += max_concurrent {
		batch_end := min(batch_start + max_concurrent, len(tests))

		for i in batch_start ..< batch_end {
			contexts[i] = Test_Thread_Context {
				entry  = tests[i],
				result = &results[i],
			}
			threads[i] = thread.create_and_start_with_data(&contexts[i], test_thread_proc)
		}

		for i in batch_start ..< batch_end {
			if threads[i] != nil {
				thread.join(threads[i])
			}
		}
	}

	passed := 0
	failed := 0

	for result in results {
		if result.success {
			passed += 1
		} else {
			failed += 1
		}
	}

	fmt.printf("\nResults: %d passed, %d failed\n", passed, failed)

	if failed > 0 {
		testing.expect(t, false, fmt.tprintf("%d tests failed", failed))
	}
}

@(test)
run_integration_tests :: proc(t: ^testing.T) {
	if test_name, ok := os.lookup_env("ACTOD_TEST_RUN", context.temp_allocator); ok {
		success := run_single_test(test_name)
		if success {
			os.exit(0)
		} else {
			os.exit(1)
		}
	}

	if node_cmd, ok := os.lookup_env("ACTOD_TEST_NODE", context.temp_allocator); ok {
		start_parent_monitor()
		run_node_role(node_cmd)
		os.exit(0)
	}

	run_tests_parallel(t)
}

@(init)
register_shared_messages :: proc "contextless" () {
	actod.register_message_type(Integration_Test_Message)
	actod.register_message_type(string)
	actod.register_message_type(Pipeline_Message)
	actod.register_message_type(Broadcast_Message)
	actod.register_message_type(Large_Message)
	actod.register_message_type(Target_Actors_Message)
	actod.register_message_type(String_Test_Message)
	actod.register_message_type(Complex_String_Message)
	actod.register_message_type(Mixed_Message)
	actod.register_message_type(Byte_Slice_Test_Message)
	actod.register_message_type(Complex_Byte_Slice_Message)
	actod.register_message_type(Mixed_Byte_Slice_Message)
	actod.register_message_type(Union_Test_Message)
	actod.register_message_type(Union_Ack)
	actod.register_message_type(shared.Network_Test_Request)
	actod.register_message_type(shared.Network_Test_Response)
	actod.register_message_type(Pubsub_Price_Update)
	actod.register_message_type(Topic_Price_Update)
	actod.register_message_type(struct {
			msg_id:  u64,
			content: shared.Network_Test_Request,
		})
}
