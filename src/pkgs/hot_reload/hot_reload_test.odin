package hot_reload

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

TEST_SRC_DIR :: "src/pkgs/hot_reload/mocks"

@(private)
test_build_counter: u64

@(test)
test_load_module_bad_path :: proc(t: ^testing.T) {
	specs := []Symbol_Spec{{name = "handle_message", required = true}}

	mod, err := load_module(fmt.tprintf("/nonexistent/path/module%s", SHARED_LIB_EXT), specs, 4)
	testing.expect_value(t, err.kind, Load_Error_Kind.File_Not_Found)
	testing.expect(t, mod == nil, "module should be nil on error")
}

@(test)
test_generate_exports_file :: proc(t: ^testing.T) {
	uid := sync.atomic_add(&test_build_counter, 1)
	tmp, _ := os.temp_directory(context.temp_allocator)
	output_path, _ := filepath.join({tmp, fmt.tprintf("actod_test_hot_exports_%d.odin", uid)}, context.temp_allocator)
	defer os.remove(output_path)

	ok := generate_exports_file(
		output_path,
		"chat_handler",
		[]Actor_Export {
			{
				state_type_name = "Chat_State",
				procs = []Export_Proc {
					{field_name = "handle_message", proc_name = "handle_chat_msg"},
					{field_name = "init", proc_name = "chat_init"},
					{field_name = "terminate", proc_name = "chat_terminate"},
				},
			},
		},
	)
	testing.expect(t, ok, "generate_exports_file should succeed")

	data, read_err := os.read_entire_file(output_path, context.temp_allocator)
	testing.expect(t, read_err == nil, "should be able to read generated file")

	content := string(data)
	testing.expect(
		t,
		strings.contains(content, "package chat_handler"),
		"should contain package name",
	)
	testing.expect(
		t,
		strings.contains(content, "hot_Chat_State_handle_message") &&
		strings.contains(content, "handle_chat_msg"),
		"should export handle_message mapped to actual proc name",
	)
	testing.expect(
		t,
		strings.contains(content, "hot_Chat_State_init") &&
		strings.contains(content, "chat_init"),
		"should export init mapped to actual proc name",
	)
	testing.expect(
		t,
		strings.contains(content, "hot_Chat_State_terminate") &&
		strings.contains(content, "chat_terminate"),
		"should export terminate mapped to actual proc name",
	)
	testing.expect(
		t,
		strings.contains(content, "size_of(Chat_State)"),
		"should reference state type",
	)
}

@(test)
test_discover_actors_dir :: proc(t: ^testing.T) {
	uid := sync.atomic_add(&test_build_counter, 1)
	tmp, _ := os.temp_directory(context.temp_allocator)
	base, _ := filepath.join({tmp, fmt.tprintf("actod_test_discover_%d", uid)}, context.temp_allocator)
	actors_dir, _ := filepath.join({base, "actors"}, context.temp_allocator)
	nested, _ := filepath.join({base, "src", "app", "deep"}, context.temp_allocator)

	os.make_directory(base)
	os.make_directory(actors_dir)
	src_dir, _ := filepath.join({base, "src"}, context.temp_allocator)
	src_app_dir, _ := filepath.join({base, "src", "app"}, context.temp_allocator)
	os.make_directory(src_dir)
	os.make_directory(src_app_dir)
	os.make_directory(nested)

	defer os.remove_all(base)

	found, ok := discover_actors_dir(nested)
	testing.expect(t, ok, "should find actors/ directory")
	testing.expect(t, filepath.is_abs(found), "should return absolute path")
	sep_buf := [1]u8{filepath.SEPARATOR}
	sep := string(sep_buf[:])
	testing.expect(t, strings.has_suffix(found, strings.concatenate({sep, "actors"}, context.temp_allocator)), "should end with actors")
}

@(test)
test_discover_actors_dir_not_found :: proc(t: ^testing.T) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	search_path, _ := filepath.join({tmp, "actod_test_no_actors_here_ever"}, context.temp_allocator)
	_, ok := discover_actors_dir(search_path)
	testing.expect(t, !ok, "should not find actors/ directory")
}

@(test)
test_compile_module_failure :: proc(t: ^testing.T) {
	uid := sync.atomic_add(&test_build_counter, 1)
	tmp, _ := os.temp_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join({tmp, fmt.tprintf("actod_hot_reload_test_%d", uid)}, context.temp_allocator)
	os.make_directory(tmp_dir)
	defer os.remove_all(tmp_dir)

	out, _ := filepath.join({tmp_dir, fmt.tprintf("bad_source%s", SHARED_LIB_EXT)}, context.temp_allocator)
	src_path, _ := filepath.join({TEST_SRC_DIR, "bad_source"}, context.temp_allocator)
	result := compile_module(src_path, out)
	testing.expect(t, !result.ok, "compile should fail for invalid source")
	testing.expect(t, len(result.error_msg) > 0, "should have error message")
}

@(test)
test_error_message_none :: proc(t: ^testing.T) {
	msg := load_error_message(Load_Error{})
	testing.expect_value(t, msg, "")
}

@(test)
test_error_message_file_not_found :: proc(t: ^testing.T) {
	path := fmt.tprintf("/some/path/actor%s", SHARED_LIB_EXT)
	msg := load_error_message(
		Load_Error{kind = .File_Not_Found, module_path = path},
	)
	testing.expect(t, strings.contains(msg, path), "should contain module path")
	testing.expect(t, strings.contains(msg, "not found"), "should indicate not found")
}

@(test)
test_error_message_missing_required_symbol :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/chat%s", SHARED_LIB_EXT)
	msg := load_error_message(
		Load_Error {
			kind = .Missing_Required_Symbol,
			module_path = path,
			symbol_name = "hot_handle_message",
		},
	)
	testing.expect(t, strings.contains(msg, path), "should contain module path")
	testing.expect(t, strings.contains(msg, "hot_handle_message"), "should contain symbol name")
}

@(test)
test_error_message_state_size_mismatch :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/actor%s", SHARED_LIB_EXT)
	msg := load_error_message(
		Load_Error {
			kind = .State_Size_Mismatch,
			module_path = path,
			expected_size = 4,
			actual_size = 8,
		},
	)
	testing.expect(t, strings.contains(msg, path), "should contain module path")
	testing.expect(t, strings.contains(msg, "4"), "should contain expected size")
	testing.expect(t, strings.contains(msg, "8"), "should contain actual size")
}

@(test)
test_error_message_dlopen_failed :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/broken%s", SHARED_LIB_EXT)
	sys_msg := fmt.tprintf("libfoo%s: cannot open shared object file", SHARED_LIB_EXT)
	msg := load_error_message(
		Load_Error {
			kind = .Dlopen_Failed,
			module_path = path,
			system_message = sys_msg,
		},
	)
	testing.expect(t, strings.contains(msg, path), "should contain module path")
	testing.expect(t, strings.contains(msg, fmt.tprintf("libfoo%s", SHARED_LIB_EXT)), "should contain system error")
}
