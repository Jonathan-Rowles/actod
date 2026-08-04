package actod

import hot_reload "../pkgs/hot_reload"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

HOT_CHECK_DIR :: #directory + "../pkgs/hot_reload/hot_check"
HOT_EXAMPLE_DIR :: #directory + "../../docs/hot_reload_example/hot_reload_actors"

@(test)
test_hot_shim_exercises_every_exported_proc :: proc(t: ^testing.T) {
	fixture_path := fmt.tprintf("%s/hot_check.odin", HOT_CHECK_DIR)
	fixture_bytes, read_err := os.read_entire_file_from_path(fixture_path, context.allocator)
	if !testing.expect(t, read_err == nil, "could not read hot_check fixture") do return
	defer delete(fixture_bytes)
	fixture := string(fixture_bytes)

	shim := hot_reload.ACTOD_SHIM
	for line in strings.split_lines_iterator(&shim) {
		if len(line) == 0 || !(line[0] >= 'a' && line[0] <= 'z') do continue
		marker := strings.index(line, " :: proc")
		if marker < 0 do continue
		name := line[:marker]
		needle := fmt.tprintf("act.%s(", name)
		testing.expect(
			t,
			strings.contains(fixture, needle),
			fmt.tprintf(
				"shim exports '%s' but hot_check.odin never calls '%s': add a call so the hot-reload surface stays covered",
				name,
				needle,
			),
		)
	}
}

@(test)
test_hot_shim_modules_compile :: proc(t: ^testing.T) {
	modules := [][2]string {
		{HOT_CHECK_DIR, "hot_check"},
		{HOT_EXAMPLE_DIR + "/responder", "responder"},
		{HOT_EXAMPLE_DIR + "/sender", "sender"},
	}

	for m in modules {
		pkg_path, pkg_name := m[0], m[1]
		defer _ = os.remove_all(fmt.tprintf("%s/tmp", pkg_path))

		build_pkg, prepared := prepare_build_dir(pkg_path, pkg_name)
		if !testing.expect(
			t,
			prepared,
			fmt.tprintf("prepare_build_dir failed for '%s'", pkg_name),
		) {
			continue
		}

		proc_desc := os.Process_Desc {
			command = []string{"odin", "check", build_pkg, "-no-entry-point"},
			stdout  = os.stdout,
			stderr  = os.stderr,
		}
		process, start_err := os.process_start(proc_desc)
		if !testing.expect(
			t,
			start_err == nil,
			fmt.tprintf("could not start odin check for '%s': %v", pkg_name, start_err),
		) {
			continue
		}
		state, wait_err := os.process_wait(process)
		testing.expect(
			t,
			wait_err == nil && state.exit_code == 0,
			fmt.tprintf(
				"hot-reload module '%s' does not compile against the generated shim (exit %d)",
				pkg_name,
				state.exit_code,
			),
		)
	}
}
