package hot_reload_dev

import actod "../src/actod"
import hot_reload "../src/pkgs/hot_reload"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

HOOKED_FIXTURE_DIR :: #directory + "../src/pkgs/hot_reload/mocks/hooked"
HOOK_SIGNAL_LIMIT :: 10 * time.Second

@(test)
test_hot_shim_spawn_carries_foreign_wait_hooks :: proc(t: ^testing.T) {
	defer _ = os.remove_all(HOOKED_FIXTURE_DIR + "/tmp")

	build_pkg, prepared := prepare_build_dir(HOOKED_FIXTURE_DIR, "hooked")
	if !testing.expect(t, prepared, "prepare_build_dir failed for the hooked fixture") do return
	so_path := fmt.tprintf("%s/tmp/hooked%s", HOOKED_FIXTURE_DIR, hot_reload.SHARED_LIB_EXT)
	built := hot_reload.compile_module(build_pkg, so_path)
	if !testing.expect(t, built.ok, built.error_msg) do return

	lib, loaded := dynlib.load_library(so_path)
	if !testing.expect(t, loaded, "could not load the hooked fixture") do return
	defer dynlib.unload_library(lib)
	populate_hot_api(lib)
	spawn_sym, found := dynlib.symbol_address(lib, "spawn_hooked")
	if !testing.expect(t, found, "fixture does not export spawn_hooked") do return
	spawn_hooked := cast(proc "c" (idle_entered: ^sync.Sema, wake: ^sync.Sema, handled: ^sync.Sema) -> u64)spawn_sym

	actod.node_init("hot-shim-hooks", actod.make_node_config(worker_count = 1))
	defer actod.shutdown_node()

	idle_entered, wake, handled: sync.Sema
	pid := actod.PID(spawn_hooked(&idle_entered, &wake, &handled))
	if !testing.expect(t, pid != 0, "spawn through the shim failed") do return

	if !testing.expect(
		t,
		sync.sema_wait_with_timeout(&idle_entered, HOOK_SIGNAL_LIMIT),
		"on_idle never ran: the shim dropped it",
	) {
		_ = actod.terminate_actor(pid)
		return
	}

	testing.expect_value(t, actod.send_message(pid, 1), actod.Send_Error.OK)
	testing.expect(
		t,
		sync.sema_wait_with_timeout(&handled, HOOK_SIGNAL_LIMIT),
		"the send did not interrupt on_idle: the shim dropped on_wake",
	)
	testing.expect(t, actod.terminate_actor(pid), "terminate")
	actod.wait_for_pids([]actod.PID{pid})
}
