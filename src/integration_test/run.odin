package integration

import "../actod"
import "../pkgs/threads_act"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
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
	enable_encryption:     bool,
	udp_port:              int,
	expects_error_logs:    bool,
	sim_mode:              bool,
	quiet_logs:            bool,
}

ALL_TESTS :: []Test_Entry {
	// Core actor tests
	{name = "test_actor_lifecycle", test_proc = test_actor_lifecycle},
	{name = "test_request_reply_pattern", test_proc = test_request_reply_pattern},
	{name = "test_ask_reply_roundtrip", test_proc = test_ask_reply_roundtrip},
	{name = "test_ask_timeout_and_late_reply", test_proc = test_ask_timeout_and_late_reply},
	{name = "test_pipeline_pattern", test_proc = test_pipeline_pattern},
	{name = "test_broadcast_pattern", test_proc = test_broadcast_pattern},
	{
		name = "test_concurrent_actor_operations",
		test_proc = test_concurrent_actor_operations,
		worker_count = ALL_CORES_WORKERS,
	},
	{
		name = "test_stress_message_throughput",
		test_proc = test_stress_message_throughput,
		worker_count = ALL_CORES_WORKERS,
	},
	{name = "test_pool_integration", test_proc = test_pool_integration},
	{
		name = "test_pool_cleanup_on_actor_termination",
		test_proc = test_pool_cleanup_on_actor_termination,
	},
	{name = "test_registry_consistency", test_proc = test_registry_consistency},
	{name = "test_worker_contention", test_proc = test_worker_contention, worker_count = 2},
	{name = "test_sim_pump_basic", test_proc = test_sim_pump_basic, sim_mode = true, worker_count = 2},
	{name = "test_sim_virtual_timer", test_proc = test_sim_virtual_timer, sim_mode = true, worker_count = 2},
	{name = "test_sim_seeded_determinism", test_proc = test_sim_seeded_determinism, sim_mode = true, worker_count = 2},
	{name = "test_sim_two_nodes", test_proc = test_sim_two_nodes, sim_mode = true, worker_count = 2},
	{name = "test_sim_virtual_transport", test_proc = test_sim_virtual_transport, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_basic", test_proc = test_sim_mesh_basic, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_determinism", test_proc = test_sim_mesh_determinism, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_partition_heal", test_proc = test_sim_mesh_partition_heal, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_crash_restart", test_proc = test_sim_mesh_crash_restart, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_remote_spawn_supervision", test_proc = test_sim_mesh_remote_spawn_supervision, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_discovery", test_proc = test_sim_mesh_discovery, sim_mode = true, worker_count = 2},
	{name = "test_sim_mesh_pool_scale_up", test_proc = test_sim_mesh_pool_scale_up, sim_mode = true, worker_count = 2},
	{name = "test_sim_regression_stale_gossip_after_restart", test_proc = test_sim_regression_stale_gossip_after_restart, sim_mode = true, worker_count = 2},
	{name = "test_sim_regression_relay_heals_lost_broadcast", test_proc = test_sim_regression_relay_heals_lost_broadcast, sim_mode = true, worker_count = 2},
	{name = "test_sim_regression_relay_cannot_resurrect", test_proc = test_sim_regression_relay_cannot_resurrect, sim_mode = true, worker_count = 2},
	{name = "test_sim_regression_pool_peer_crash", test_proc = test_sim_regression_pool_peer_crash, sim_mode = true, worker_count = 2, quiet_logs = true},
	{name = "test_sim_regression_idle_pool_ring_parks", test_proc = test_sim_regression_idle_pool_ring_parks, sim_mode = true, worker_count = 2},
	{name = "test_sim_regression_publish_during_scale_down", test_proc = test_sim_regression_publish_during_scale_down, sim_mode = true, worker_count = 2},
	{name = "test_sim_vopr", test_proc = test_sim_vopr, sim_mode = true, worker_count = 2, quiet_logs = true},
	{
		name = "test_reclaim_churn_under_termination",
		test_proc = test_reclaim_churn_under_termination,
		worker_count = 4,
	},
	{
		name = "test_system_mailbox_full_returns_error",
		test_proc = test_system_mailbox_full_returns_error,
		worker_count = 2,
		expects_error_logs = true,
	},
	{
		name = "test_slab_slots_return_after_termination",
		test_proc = test_slab_slots_return_after_termination,
		worker_count = 4,
	},
	{
		name = "test_slab_falls_back_for_oversized_actor",
		test_proc = test_slab_falls_back_for_oversized_actor,
		worker_count = 2,
	},
	{
		name = "test_slab_neighbours_survive_arena_exhaustion",
		test_proc = test_slab_neighbours_survive_arena_exhaustion,
		worker_count = 2,
	},
	{
		name = "test_mailbox_overflow_preserves_send_order",
		test_proc = test_mailbox_overflow_preserves_send_order,
		worker_count = 2,
		expects_error_logs = true,
	},
	{
		name = "test_spawn_sized_mailbox",
		test_proc = test_spawn_sized_mailbox,
		worker_count = 2,
	},
	{
		name = "test_supervisor_survives_many_child_terminations",
		test_proc = test_supervisor_survives_many_child_terminations,
		worker_count = 2,
	},
	{name = "test_wait_helpers_honor_timeout", test_proc = test_wait_helpers_honor_timeout},
	{
		name = "test_mass_simultaneous_child_deaths",
		test_proc = test_mass_simultaneous_child_deaths,
		worker_count = 4,
		expects_error_logs = true,
	},
	{
		name = "test_blocked_supervisor_past_old_retry_window",
		test_proc = test_blocked_supervisor_past_old_retry_window,
		worker_count = 4,
		expects_error_logs = true,
	},

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
	{
		name = "test_remove_child_then_restart_all",
		test_proc = test_remove_child_then_restart_all,
	},
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
	{name = "test_actor_panic_recovery", test_proc = test_actor_panic_recovery, expects_error_logs = true},
	{
		name = "test_actor_panic_supervisor_restart",
		test_proc = test_actor_panic_supervisor_restart,
		expects_error_logs = true,
	},
	{name = "test_actor_panic_in_init", test_proc = test_actor_panic_in_init, expects_error_logs = true},
	{
		name = "test_crash_runs_terminate_and_reaps_children",
		test_proc = test_crash_runs_terminate_and_reaps_children,
		expects_error_logs = true,
	},
	{
		name = "test_panic_in_terminate_runs_teardown_once",
		test_proc = test_panic_in_terminate_runs_teardown_once,
		expects_error_logs = true,
	},

	// Slower tests
	{name = "test_restart_limit_within_window", test_proc = test_restart_limit_within_window, expects_error_logs = true},
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
		name = "test_distributed_wrong_password_rejected",
		test_proc = test_distributed_wrong_password_rejected,
		port = 17240,
		node_name = "TestNode1",
		is_networked = true,
		expects_error_logs = true,
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
	{
		name = "test_encrypted_distributed_burst",
		test_proc = test_encrypted_distributed_burst,
		port = 17190,
		node_name = "TestNode1",
		is_networked = true,
		enable_encryption = true,
	},
	{
		name = "test_encryption_mismatch_rejected",
		test_proc = test_encryption_mismatch_rejected,
		port = 17210,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_udp_send_unreliable",
		test_proc = test_udp_send_unreliable,
		port = 17220,
		node_name = "TestNode1",
		is_networked = true,
		enable_encryption = true,
		udp_port = 17223,
	},
	{
		name = "test_udp_fallback_to_tcp",
		test_proc = test_udp_fallback_to_tcp,
		port = 17230,
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
		expects_error_logs = true,
	},
	{
		name = "test_remote_spawn_timeout",
		test_proc = test_remote_spawn_timeout,
		port = 17140,
		node_name = "TestNode1",
		is_networked = true,
		expects_error_logs = true,
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
	{
		name = "test_distributed_byte_slice_messages",
		test_proc = test_distributed_byte_slice_messages,
		port = 17180,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_remote_spawn_parent_link",
		test_proc = test_remote_spawn_parent_link,
		port = 17190,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_pubsub_subscribe_before_connect",
		test_proc = test_pubsub_subscribe_before_connect,
		port = 17200,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_frame_tap_duplicate_actor_stopped",
		test_proc = test_frame_tap_duplicate_actor_stopped,
		port = 17210,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_frame_tap_drops_outbound_user_message",
		test_proc = test_frame_tap_drops_outbound_user_message,
		port = 17230,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_frame_tap_partition_heals",
		test_proc = test_frame_tap_partition_heals,
		port = 17220,
		node_name = "TestNode1",
		is_networked = true,
	},
	{
		name = "test_node_shutdown_under_load",
		test_proc = test_node_shutdown_under_load,
		worker_count = ALL_CORES_WORKERS,
		expects_error_logs = true,
	},

	// Hot reload tests (Phase 1a)
	{name = "test_hot_reload_basic", test_proc = test_hot_reload_basic},
	{name = "test_hot_reload_state_preserved", test_proc = test_hot_reload_state_preserved},
	{name = "test_reload_behaviour_system_msg", test_proc = test_reload_behaviour_system_msg},
	{name = "test_rollback", test_proc = test_rollback},

	// Hot reload tests (Phase 1b, file watcher + dev workflow)
	{name = "test_file_watcher_detection", test_proc = test_file_watcher_detection},
	{name = "test_file_watcher_excludes_tmp", test_proc = test_file_watcher_excludes_tmp},
	{
		name = "test_hot_reload_under_load",
		test_proc = test_hot_reload_under_load,
		worker_count = ALL_CORES_WORKERS,
	},
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

DEFAULT_TEST_WORKERS :: 4
ALL_CORES_WORKERS :: -1

resolve_worker_count :: proc(entry: Test_Entry) -> int {
	switch {
	case entry.worker_count == ALL_CORES_WORKERS:
		return 0
	case entry.worker_count > 0:
		return entry.worker_count
	case:
		return DEFAULT_TEST_WORKERS
	}
}

test_worker_weight :: proc(entry: Test_Entry) -> int {
	resolved := resolve_worker_count(entry)
	return threads_act.get_cpu_count() if resolved == 0 else resolved
}

run_test_entry :: proc(entry: Test_Entry) -> bool {
	port := entry.port if entry.port != 0 else (8080 if entry.is_networked else 0)
	node_name := entry.node_name if entry.node_name != "" else entry.name

	if entry.is_networked {
		test_base_port = port
		shared.check_port_available(port)
	}

	network_config := actod.make_network_config(
		auth_password = "test_dist_password",
		port = port,
		udp_port = entry.udp_port,
		enable_encryption = entry.enable_encryption,
		heartbeat_interval = 100 * time.Millisecond,
		heartbeat_timeout = scaled_timeout(300 * time.Millisecond),
		reconnect_initial_delay = 200 * time.Millisecond,
		reconnect_retry_delay = 300 * time.Millisecond,
	)

	node_opts := actod.make_node_config(
		network = network_config,
		actor_config = actod.make_actor_config(
			logging = actod.make_log_config(level = .Error if entry.quiet_logs else .Warning),
		),
		hot_reload_dev = entry.hot_reload_dev,
		hot_reload_watch_path = entry.hot_reload_watch_path,
	)
	node_opts.worker_count = resolve_worker_count(entry)
	node_opts.sim_mode = entry.sim_mode

	actod.node_init(name = node_name, opts = node_opts)

	wait_for_node()

	context.logger = actod.get_node_log_ctx()

	t := testing.T{}
	entry.test_proc(&t)
	failed := testing.failed(&t)
	if failed {
		fmt.eprintf("Test %s: %d failed expectation(s)\n", entry.name, t.error_count)
	}

	if actod.NODE.started {
		actod.shutdown_node()
	}

	final_count := actod.num_used(&actod.NODE.actor_registry)
	if final_count > 0 {
		fmt.eprintf("Test %s: zombie actors detected (%d remaining)\n", entry.name, final_count)
		return false
	}

	return !failed
}

@(private)
subprocess_counter: u64

Test_Result :: struct {
	name:       string,
	success:    bool,
	exit_code:  int,
	logged_err: string,
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
	for _ in 0 ..< scaled_attempts(TEST_TIMEOUT_SECONDS * 4) {
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

run_test_in_subprocess :: proc(test_name: string, expects_error_logs: bool) -> Test_Result {
	result := Test_Result {
		name    = test_name,
		success = false,
	}

	uid := sync.atomic_add(&subprocess_counter, 1)
	sys_tmp, _ := os.temp_directory(context.temp_allocator)
	stderr_path, _ := filepath.join(
		{sys_tmp, fmt.tprintf("actod_test_%d_%d_err", os.get_pid(), uid)},
		context.temp_allocator,
	)
	defer os.remove(stderr_path)

	stderr_f, stderr_open_err := os.open(
		stderr_path,
		os.O_WRONLY | os.O_CREATE | os.O_TRUNC | os.File_Flags{.Inheritable},
	)
	if stderr_open_err != nil {
		fmt.eprintf("Failed to capture stderr for %s: %v\n", test_name, stderr_open_err)
		return result
	}

	proc_desc := os.Process_Desc {
		command = []string{INTEGRATION_TEST_BIN},
		env     = make_test_env([]string{fmt.tprintf("ACTOD_TEST_RUN=%s", test_name)}),
		stdout  = os.stdout,
		stderr  = stderr_f,
	}

	process, err := os.process_start(proc_desc)
	os.close(stderr_f)
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

	captured, read_err := os.read_entire_file(stderr_path, context.temp_allocator)
	if read_err == nil && len(captured) > 0 {
		os.write(os.stderr, captured)
		result.logged_err = first_logged_error(string(captured))
	}

	if watchdog_data.fired {
		result.exit_code = -1
		return result
	}

	if wait_err != nil {
		fmt.eprintf("Failed to wait for test %s: %v\n", test_name, wait_err)
		return result
	}

	result.exit_code = state.exit_code
	result.success = state.exit_code == 0 && (expects_error_logs || result.logged_err == "")

	return result
}

first_logged_error :: proc(output: string) -> string {
	remaining := output
	for line in strings.split_lines_iterator(&remaining) {
		if strings.contains(line, "[ERROR]") || strings.contains(line, "[FATAL]") {
			return strings.trim_space(line)
		}
	}
	return ""
}

test_thread_proc :: proc(data: rawptr) {
	ctx := cast(^Test_Thread_Context)data
	ctx.result^ = run_test_in_subprocess(ctx.entry.name, ctx.entry.expects_error_logs)
	if ctx.result.success {
		fmt.printf("  PASS: %s\n", ctx.result.name)
	} else if ctx.result.exit_code == 0 && ctx.result.logged_err != "" {
		fmt.printf("  FAIL: %s (logged error: %s)\n", ctx.result.name, ctx.result.logged_err)
	} else if ctx.result.exit_code == -1 {
		fmt.printf(
			"  TIMEOUT: %s (killed after %ds)\n",
			ctx.result.name,
			TEST_TIMEOUT_SECONDS * timeout_scale(),
		)
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

	worker_budget := max(threads_act.get_cpu_count(), 2)
	when #config(ODIN_TEST_THREADS, 0) == 1 {
		worker_budget = 1
	}
	fmt.printf(
		"Running %d tests in parallel (worker budget %d)...\n",
		len(tests),
		worker_budget,
	)

	for batch_start := 0; batch_start < len(tests); {
		batch_end := batch_start
		batch_weight := 0
		for batch_end < len(tests) {
			weight := test_worker_weight(tests[batch_end])
			if batch_end > batch_start && batch_weight + weight > worker_budget {
				break
			}
			batch_weight += weight
			batch_end += 1
		}

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

		batch_start = batch_end
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
	actod.register_message_type(u64)
	actod.register_message_type(string)
	actod.register_message_type(int)
	actod.register_message_type(Reclaim_Tick)
	actod.register_message_type(Leak_Supervisor_Cmd)
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
