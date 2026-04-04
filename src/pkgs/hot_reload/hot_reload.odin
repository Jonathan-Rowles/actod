package hot_reload

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

SHARED_LIB_EXT :: ".dylib" when ODIN_OS == .Darwin else ".dll" when ODIN_OS == .Windows else ".so"

@(private)
run_process_counter: u64

Hot_Module :: struct {
	path:       string,
	lib:        dynlib.Library,
	symbols:    [dynamic]Resolved_Symbol,
	state_size: int,
	load_time:  time.Time,
	generation: u32,
}

Resolved_Symbol :: struct {
	name:     string,
	ptr:      rawptr,
	required: bool,
}

Symbol_Spec :: struct {
	name:     string,
	required: bool,
}

Load_Error_Kind :: enum {
	None,
	File_Not_Found,
	Dlopen_Failed,
	Missing_Required_Symbol,
	State_Size_Mismatch,
}

Load_Error :: struct {
	kind:           Load_Error_Kind,
	module_path:    string,
	symbol_name:    string, // for Missing_Required_Symbol
	expected_size:  int, // for State_Size_Mismatch
	actual_size:    int, // for State_Size_Mismatch
	system_message: string, // OS-level error from dlopen
}

load_error_message :: proc(err: Load_Error) -> string {
	switch err.kind {
	case .None:
		return ""
	case .File_Not_Found:
		return fmt.tprintf("HOT RELOAD ERROR: Module not found: %s", err.module_path)
	case .Dlopen_Failed:
		return fmt.tprintf(
			"HOT RELOAD ERROR: Failed to load module '%s': %s",
			err.module_path,
			err.system_message,
		)
	case .Missing_Required_Symbol:
		return fmt.tprintf(
			"HOT RELOAD ERROR: Required symbol '%s' not found in '%s'\n" +
			"  The shared library must export '%s' (via @(export) or generated hot_exports.odin).",
			err.symbol_name,
			err.module_path,
			err.symbol_name,
		)
	case .State_Size_Mismatch:
		return fmt.tprintf(
			"HOT RELOAD REJECTED: State layout changed in '%s'\n" +
			"  Expected size: %d bytes, got: %d bytes.\n" +
			"  Hot reload preserves actor state in memory — struct changes would corrupt it.\n" +
			"  For struct changes, use graceful restart (see graceful-restart.md).",
			err.module_path,
			err.expected_size,
			err.actual_size,
		)
	}
	return ""
}

Compile_Result :: struct {
	ok:          bool,
	output_path: string,
	error_msg:   string,
}

load_module :: proc(
	path: string,
	expected_symbols: []Symbol_Spec,
	expected_state_size: int,
	generation: u32 = 0,
	state_type_prefix := "",
	allocator := context.allocator,
) -> (
	^Hot_Module,
	Load_Error,
) {
	if !os.exists(path) {
		return nil, Load_Error{kind = .File_Not_Found, module_path = path}
	}

	lib, lib_ok := dynlib.load_library(path)
	if !lib_ok {
		return nil, Load_Error {
			kind = .Dlopen_Failed,
			module_path = path,
			system_message = dynlib.last_error(),
		}
	}

	entry_point, ep_found := dynlib.symbol_address(lib, "_odin_entry_point")
	if ep_found && entry_point != nil {
		(cast(proc "c" ())entry_point)()
	}

	symbols: [dynamic]Resolved_Symbol
	symbols.allocator = allocator

	for spec in expected_symbols {
		sym_name: string
		if state_type_prefix != "" {
			sym_name = fmt.tprintf("hot_%s_%s", state_type_prefix, spec.name)
		} else {
			sym_name = fmt.tprintf("hot_%s", spec.name)
		}
		ptr, found := dynlib.symbol_address(lib, sym_name)

		if spec.required && !found {
			dynlib.unload_library(lib)
			delete(symbols)
			return nil, Load_Error {
				kind = .Missing_Required_Symbol,
				module_path = path,
				symbol_name = sym_name,
			}
		}

		resolved_ptr: rawptr = nil
		if found && ptr != nil {
			getter := cast(proc "c" () -> rawptr)ptr
			resolved_ptr = getter()
		}

		append(
			&symbols,
			Resolved_Symbol{name = spec.name, ptr = resolved_ptr, required = spec.required},
		)
	}

	state_size_sym: string
	if state_type_prefix != "" {
		state_size_sym = fmt.tprintf("hot_%s_state_size", state_type_prefix)
	} else {
		state_size_sym = "hot_state_size"
	}
	state_size_ptr, state_size_found := dynlib.symbol_address(lib, state_size_sym)
	if state_size_found && state_size_ptr != nil {
		state_size_fn := cast(proc "c" () -> int)state_size_ptr
		actual_size := state_size_fn()
		if actual_size != expected_state_size {
			dynlib.unload_library(lib)
			delete(symbols)
			return nil, Load_Error {
				kind = .State_Size_Mismatch,
				module_path = path,
				expected_size = expected_state_size,
				actual_size = actual_size,
			}
		}
	}

	mod := new(Hot_Module, allocator)
	mod^ = Hot_Module {
		path       = strings.clone(path, allocator),
		lib        = lib,
		symbols    = symbols,
		state_size = expected_state_size,
		load_time  = time.now(),
		generation = generation,
	}

	return mod, {}
}

unload_module :: proc(mod: ^Hot_Module, allocator := context.allocator) {
	if mod == nil do return

	if mod.lib != nil {
		dynlib.unload_library(mod.lib)
	}

	delete(mod.path, allocator)
	delete(mod.symbols)
	free(mod, allocator)
}

Export_Proc :: struct {
	field_name: string, // behaviour field: "handle_message"
	proc_name:  string, // actual proc in source: "handle_pair_message"
}

Actor_Export :: struct {
	state_type_name: string,
	procs:           []Export_Proc,
}

generate_exports_file :: proc(
	output_path: string,
	package_name: string,
	actors: []Actor_Export,
) -> bool {
	b := strings.builder_make(context.temp_allocator)

	strings.write_string(&b, "// AUTO-GENERATED by actod hot reload — do not edit\n")
	fmt.sbprintf(&b, "package %s\n\n", package_name)

	for actor in actors {
		for p in actor.procs {
			fmt.sbprintf(
				&b,
				"@(export) hot_%s_%s :: proc \"c\" () -> rawptr {{ return rawptr(%s) }}\n",
				actor.state_type_name,
				p.field_name,
				p.proc_name,
			)
		}
		fmt.sbprintf(
			&b,
			"@(export) hot_%s_state_size :: proc \"c\" () -> int {{ return size_of(%s) }}\n\n",
			actor.state_type_name,
			actor.state_type_name,
		)
	}

	content := strings.to_string(b)
	err := os.write_entire_file(output_path, transmute([]u8)content)
	return err == nil
}

compile_module :: proc(
	package_path: string,
	output_path: string,
	extra_flags: []string = nil,
) -> Compile_Result {
	base_args := [?]string {
		"odin",
		"build",
		package_path,
		"-build-mode:shared",
		fmt.tprintf("-out:%s", output_path),
	}

	args: [dynamic]string
	args.allocator = context.temp_allocator
	append(&args, ..base_args[:])
	for flag in extra_flags {
		append(&args, flag)
	}

	stdout_buf, stderr_buf: [dynamic]u8
	stdout_buf.allocator = context.temp_allocator
	stderr_buf.allocator = context.temp_allocator

	state, err := run_process(args[:], &stdout_buf, &stderr_buf)
	if err != nil {
		return Compile_Result {
			ok = false,
			error_msg = fmt.tprintf("Failed to start odin compiler: %v", err),
		}
	}

	if state.exit_code == 0 {
		return Compile_Result{ok = true, output_path = output_path}
	}

	return Compile_Result {
		ok = false,
		error_msg = string(stdout_buf[:]) if len(stdout_buf) > 0 else string(stderr_buf[:]),
	}
}

run_process :: proc(
	args: []string,
	stdout_buf: ^[dynamic]u8,
	stderr_buf: ^[dynamic]u8,
) -> (
	os.Process_State,
	os.Error,
) {
	uid := sync.atomic_add(&run_process_counter, 1)
	tmp_dir, tmp_err := os.temp_directory(context.temp_allocator)
	if tmp_err != nil do return {}, tmp_err
	stdout_path, _ := filepath.join(
		{tmp_dir, fmt.tprintf("actod_proc_%d_%d_out", os.get_pid(), uid)},
		context.temp_allocator,
	)
	stderr_path, _ := filepath.join(
		{tmp_dir, fmt.tprintf("actod_proc_%d_%d_err", os.get_pid(), uid)},
		context.temp_allocator,
	)
	defer os.remove(stdout_path)
	defer os.remove(stderr_path)

	stdout_f, stdout_err := os.open(stdout_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if stdout_err != nil do return {}, stdout_err
	stderr_f, stderr_err := os.open(stderr_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if stderr_err != nil {
		os.close(stdout_f)
		return {}, stderr_err
	}

	process: os.Process
	{
		defer os.close(stdout_f)
		defer os.close(stderr_f)
		p, err := os.process_start(
			os.Process_Desc{command = args, stdout = stdout_f, stderr = stderr_f},
		)
		if err != nil do return {}, err
		process = p
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil do return state, wait_err

	if stdout_buf != nil {
		data, read_err := os.read_entire_file(stdout_path, context.temp_allocator)
		if read_err == nil do append(stdout_buf, ..data)
	}
	if stderr_buf != nil {
		data, read_err := os.read_entire_file(stderr_path, context.temp_allocator)
		if read_err == nil do append(stderr_buf, ..data)
	}

	return state, nil
}

discover_actors_dir :: proc(start_path: string) -> (string, bool) {
	join :: proc(elems: []string) -> string {
		result, _ := filepath.join(elems, context.temp_allocator)
		return result
	}

	current := start_path
	for {
		candidate := join({current, "actors"})
		if os.is_dir(candidate) {
			abs_path, abs_err := filepath.abs(candidate, context.temp_allocator)
			if abs_err == nil {
				return abs_path, true
			}
			return candidate, true
		}

		parent := filepath.dir(current, context.temp_allocator)
		if parent == current || parent == "" || parent == "." {
			return "", false
		}
		current = parent
	}
}

Collection :: struct {
	name:     string,
	abs_path: string,
}

discover_collections :: proc(start_path: string, allocator := context.allocator) -> []Collection {
	join :: proc(elems: []string) -> string {
		result, _ := filepath.join(elems, context.temp_allocator)
		return result
	}

	ols_dir: string
	current := start_path
	for {
		candidate := join({current, "ols.json"})
		if os.exists(candidate) {
			ols_dir = current
			break
		}
		parent := filepath.dir(current, context.temp_allocator)
		if parent == current || parent == "" || parent == "." {
			return nil
		}
		current = parent
	}

	ols_path := join({ols_dir, "ols.json"})
	data, read_err := os.read_entire_file(ols_path, context.temp_allocator)
	if read_err != nil do return nil

	val, parse_err := json.parse(data, allocator = context.temp_allocator)
	if parse_err != .None do return nil
	defer json.destroy_value(val, context.temp_allocator)

	root, is_obj := val.(json.Object)
	if !is_obj do return nil

	collections_val, has_collections := root["collections"]
	if !has_collections do return nil

	collections_arr, is_arr := collections_val.(json.Array)
	if !is_arr do return nil

	result: [dynamic]Collection
	result.allocator = allocator

	for item in collections_arr {
		obj, is_item_obj := item.(json.Object)
		if !is_item_obj do continue

		name_val, has_name := obj["name"]
		path_val, has_path := obj["path"]
		if !has_name || !has_path do continue

		name_str, is_name := name_val.(json.String)
		path_str, is_path := path_val.(json.String)
		if !is_name || !is_path do continue
		if name_str == "" do continue

		joined := join({ols_dir, path_str})
		abs_path, abs_err := filepath.abs(joined, context.temp_allocator)
		resolved := abs_path if abs_err == nil else joined

		append(
			&result,
			Collection {
				name = strings.clone(name_str, allocator),
				abs_path = strings.clone(resolved, allocator),
			},
		)
	}

	return result[:]
}

resolve_collection_import :: proc(import_path: string, collections: []Collection) -> string {
	colon := strings.index_byte(import_path, ':')
	if colon <= 0 do return ""

	col_name := import_path[:colon]
	sub_path := import_path[colon + 1:]

	for c in collections {
		if c.name == col_name {
			if sub_path == "" do return c.abs_path
			result, _ := filepath.join({c.abs_path, sub_path}, context.temp_allocator)
			return result
		}
	}

	return ""
}
