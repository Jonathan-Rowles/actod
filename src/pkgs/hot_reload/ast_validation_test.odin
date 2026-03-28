package hot_reload

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

@(private)
make_test_package :: proc(name: string, source: string) -> string {
	uid := sync.atomic_add(&test_build_counter, 1)
	tmp, _ := os.temp_directory(context.temp_allocator)
	base, _ := filepath.join({tmp, fmt.tprintf("actod_test_ast_%d", uid)}, context.temp_allocator)
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	os.make_directory(base)
	os.make_directory(dir)
	pkg_file, _ := filepath.join({dir, fmt.tprintf("%s.odin", name)}, context.temp_allocator)
	_ = os.write_entire_file(pkg_file, transmute([]u8)source)
	return dir
}

@(test)
test_validate_package_valid :: proc(t: ^testing.T) {
	source := `package valid_actor

Counter_State :: struct {
	count: i32,
}

PID :: distinct u64

handle_message :: proc(data: ^Counter_State, from: PID, content: any) {
	data.count += 1
}
`

	dir := make_test_package("valid_actor", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "Counter_State",
			field_names = []string{"count"},
			field_types = []string{"i32"},
		},
		[]Proc_Expectation{{name = "handle_message", param_count = 3, required = true}},
	)

	testing.expect(t, result.ok, "valid package should pass validation")
	testing.expect_value(t, len(result.errors), 0)
	destroy_validation_result(result)
}

@(test)
test_validate_state_layout_changed :: proc(t: ^testing.T) {
	source := `package changed_state

Counter_State :: struct {
	count: string,
}
`

	dir := make_test_package("changed_state", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "Counter_State",
			field_names = []string{"count"},
			field_types = []string{"i32"},
		},
		nil,
	)

	testing.expect(t, !result.ok, "changed state should fail validation")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.State_Layout_Changed)
		testing.expect(t, result.errors[0].line > 0, "should have line number")
	}
	destroy_validation_result(result)
}

@(test)
test_validate_signature_mismatch :: proc(t: ^testing.T) {
	source := `package sig_mismatch

handle_message :: proc(data: rawptr) {
}
`

	dir := make_test_package("sig_mismatch", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation{},
		[]Proc_Expectation{{name = "handle_message", param_count = 3, required = true}},
	)

	testing.expect(t, !result.ok, "mismatched signature should fail")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.Signature_Mismatch)
	}
	destroy_validation_result(result)
}

@(test)
test_validate_init_proc_allowed :: proc(t: ^testing.T) {
	source := `package init_ok

@(init)
setup :: proc "contextless" () {
}
`

	dir := make_test_package("init_ok", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(dir, State_Expectation{}, nil)

	testing.expect(t, result.ok, "@(init) should pass validation (stripped at build time)")
	destroy_validation_result(result)
}

@(test)
test_validate_state_not_found :: proc(t: ^testing.T) {
	source := `package no_state

handle_message :: proc() {
}
`

	dir := make_test_package("no_state", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(dir, State_Expectation{name = "Missing_State"}, nil)

	testing.expect(t, !result.ok, "missing state should fail")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.State_Not_Found)
	}
	destroy_validation_result(result)
}

@(test)
test_validate_odin_check_bad_syntax :: proc(t: ^testing.T) {
	source := `package bad_syntax

this is not valid odin !!!
`

	dir := make_test_package("bad_syntax", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(dir, State_Expectation{}, nil)

	testing.expect(t, !result.ok, "bad syntax should fail validation")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.Parse_Error)
		testing.expect(t, len(result.errors[0].message) > 0, "should have compiler error message")
	}
	destroy_validation_result(result)
}

@(test)
test_validate_field_added :: proc(t: ^testing.T) {
	source := `package field_added

My_State :: struct {
	count: i32,
	name:  string,
}
`

	dir := make_test_package("field_added", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"count"},
			field_types = []string{"i32"},
		},
		nil,
	)

	testing.expect(t, !result.ok, "added field should fail validation")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.State_Layout_Changed)
		testing.expect(
			t,
			strings.contains(result.errors[0].message, "Field count changed"),
			"should mention field count change",
		)
	}
	destroy_validation_result(result)
}

@(test)
test_validate_field_removed :: proc(t: ^testing.T) {
	source := `package field_removed

My_State :: struct {
	count: i32,
}
`

	dir := make_test_package("field_removed", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"count", "name"},
			field_types = []string{"i32", "string"},
		},
		nil,
	)

	testing.expect(t, !result.ok, "removed field should fail validation")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.State_Layout_Changed)
		testing.expect(
			t,
			strings.contains(result.errors[0].message, "Field count changed"),
			"should mention field count change",
		)
	}
	destroy_validation_result(result)
}

@(test)
test_validate_field_type_changed :: proc(t: ^testing.T) {
	source := `package type_changed

My_State :: struct {
	value: f64,
}
`

	dir := make_test_package("type_changed", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"value"},
			field_types = []string{"i32"},
		},
		nil,
	)

	testing.expect(t, !result.ok, "changed field type should fail validation")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.State_Layout_Changed)
		testing.expect(
			t,
			strings.contains(result.errors[0].message, "i32"),
			"should mention old type",
		)
		testing.expect(
			t,
			strings.contains(result.errors[0].message, "f64"),
			"should mention new type",
		)
	}
	destroy_validation_result(result)
}

@(test)
test_validate_proc_param_type_mismatch :: proc(t: ^testing.T) {
	source := `package param_types

handle_message :: proc(data: rawptr, from: i32, content: any) {
}
`

	dir := make_test_package("param_types", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation{},
		[]Proc_Expectation {
			{
				name = "handle_message",
				param_count = 3,
				param_types = []string{"^State", "PID", "any"},
			},
		},
	)

	testing.expect(t, !result.ok, "param type mismatch should fail")
	testing.expect(t, len(result.errors) > 0, "should have errors")
	if len(result.errors) > 0 {
		testing.expect_value(t, result.errors[0].kind, Validation_Error_Kind.Signature_Mismatch)
	}
	destroy_validation_result(result)
}

@(test)
test_validate_multiple_procs :: proc(t: ^testing.T) {
	source := `package multi_procs

My_State :: struct {
	count: i32,
}

PID :: distinct u64

handle_message :: proc(data: ^My_State, from: PID, content: any) {
}

init :: proc(data: ^My_State) {
}

terminate :: proc(data: ^My_State) {
}
`

	dir := make_test_package("multi_procs", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"count"},
			field_types = []string{"i32"},
		},
		[]Proc_Expectation {
			{name = "handle_message", param_count = 3, required = true},
			{name = "init", param_count = 1, required = false},
			{name = "terminate", param_count = 1, required = false},
		},
	)

	testing.expect(t, result.ok, "valid multi-proc package should pass")
	testing.expect_value(t, len(result.errors), 0)
	destroy_validation_result(result)
}

@(test)
test_validate_optional_proc_missing :: proc(t: ^testing.T) {
	source := `package opt_missing

My_State :: struct {
	count: i32,
}

PID :: distinct u64

handle_message :: proc(data: ^My_State, from: PID, content: any) {
}
`

	dir := make_test_package("opt_missing", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"count"},
			field_types = []string{"i32"},
		},
		[]Proc_Expectation {
			{name = "handle_message", param_count = 3, required = true},
			{name = "terminate", param_count = 1, required = false},
		},
	)

	testing.expect(t, result.ok, "missing optional proc should pass")
	testing.expect_value(t, len(result.errors), 0)
	destroy_validation_result(result)
}

@(test)
test_validate_pointer_type_in_state :: proc(t: ^testing.T) {
	source := `package ptr_state

SomeType :: struct { x: i32 }

My_State :: struct {
	data: ^SomeType,
}
`

	dir := make_test_package("ptr_state", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"data"},
			field_types = []string{"^SomeType"},
		},
		nil,
	)

	testing.expect(t, result.ok, "pointer type should match")
	testing.expect_value(t, len(result.errors), 0)
	destroy_validation_result(result)
}

@(test)
test_validate_array_type_in_state :: proc(t: ^testing.T) {
	source := `package arr_state

My_State :: struct {
	buf: [64]u8,
}
`

	dir := make_test_package("arr_state", source)
	defer os.remove_all(filepath.dir(dir, context.temp_allocator))

	result := validate_package(
		dir,
		State_Expectation {
			name = "My_State",
			field_names = []string{"buf"},
			field_types = []string{"[64]u8"},
		},
		nil,
	)

	testing.expect(t, result.ok, "array type should match")
	testing.expect_value(t, len(result.errors), 0)
	destroy_validation_result(result)
}
