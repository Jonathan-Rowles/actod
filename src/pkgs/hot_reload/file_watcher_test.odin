#+build linux, darwin, windows
package hot_reload

import "core:testing"

@(test)
test_add_watch_rejects_tmp_path :: proc(t: ^testing.T) {
	cb :: proc(event: Watch_Event, user_data: rawptr) {}

	w, ok := create_watcher(cb, nil)
	testing.expect(t, ok, "should create watcher")
	if !ok do return
	defer destroy_watcher(w)

	result := add_watch(w, "/some/path/tmp", "test")
	testing.expect(t, result, "tmp path should return true (silently skipped)")
	testing.expect_value(t, w.watch_count, 0)
}

@(test)
test_is_tmp_watch_path :: proc(t: ^testing.T) {
	testing.expect(t, is_tmp_watch_path("/some/path/tmp"))
	testing.expect(t, is_tmp_watch_path("/some/path/tmp/"))
	testing.expect(t, !is_tmp_watch_path("/some/path/tmp_extra"))
	testing.expect(t, !is_tmp_watch_path("/some/path/actors"))

	when ODIN_OS == .Windows {
		testing.expect(t, is_tmp_watch_path("C:\\actors\\tmp"))
		testing.expect(t, is_tmp_watch_path("C:\\actors\\tmp\\"))
	}
}

@(test)
test_should_ignore_file :: proc(t: ^testing.T) {
	testing.expect(t, should_ignore_file("src/main.go", "main.go"))
	testing.expect(t, should_ignore_file("src/readme.md", "readme.md"))

	testing.expect(t, should_ignore_file("actors/hot_exports.odin", "hot_exports.odin"))

	testing.expect(t, should_ignore_file("actors/tmp_build.odin", "tmp_build.odin"))

	testing.expect(t, should_ignore_file("/some/path/tmp/foo.odin", "foo.odin"))
	testing.expect(t, should_ignore_file("C:\\actors\\tmp\\foo.odin", "foo.odin"))

	testing.expect(t, !should_ignore_file("actors/main.odin", "main.odin"))
	testing.expect(t, !should_ignore_file("/abs/path/actors/handler.odin", "handler.odin"))
}
