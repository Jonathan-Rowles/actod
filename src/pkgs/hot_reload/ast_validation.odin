package hot_reload

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

Validation_Error_Kind :: enum {
	State_Layout_Changed,
	Signature_Mismatch,
	State_Not_Found,
	Parse_Error,
}

Validation_Error :: struct {
	kind:    Validation_Error_Kind,
	file:    string,
	line:    int,
	col:     int,
	message: string,
}

Validation_Result :: struct {
	ok:     bool,
	errors: []Validation_Error,
}

State_Expectation :: struct {
	name:        string,
	field_names: []string,
	field_types: []string,
	size:        int,
}

Proc_Expectation :: struct {
	name:        string,
	param_count: int,
	param_types: []string,
	required:    bool,
}

validate_package :: proc(
	package_path: string,
	expected_state: State_Expectation,
	expected_procs: []Proc_Expectation,
	allocator := context.allocator,
) -> Validation_Result {
	caller_alloc := allocator

	errors: [dynamic]Validation_Error
	errors.allocator = caller_alloc
	ok := true

	if !run_odin_check(package_path, &errors, caller_alloc) {
		return Validation_Result{ok = false, errors = errors[:]}
	}

	arena: vmem.Arena
	arena_err := vmem.arena_init_growing(&arena)
	if arena_err != nil {
		append(
			&errors,
			Validation_Error {
				kind = .Parse_Error,
				message = strings.clone("Failed to allocate arena for parser", caller_alloc),
			},
		)
		return Validation_Result{ok = false, errors = errors[:]}
	}
	defer vmem.arena_destroy(&arena)
	arena_allocator := vmem.arena_allocator(&arena)

	context.allocator = arena_allocator

	p := parser.default_parser()
	pkg, parse_ok := parser.parse_package_from_path(package_path, &p)
	if !parse_ok || pkg == nil {
		append(
			&errors,
			Validation_Error {
				kind = .Parse_Error,
				message = fmt.aprintf(
					"Failed to parse package at '%s'",
					package_path,
					allocator = caller_alloc,
				),
			},
		)
		return Validation_Result{ok = false, errors = errors[:]}
	}

	for _, file in pkg.files {
		if file.syntax_error_count > 0 {
			append(
				&errors,
				Validation_Error {
					kind = .Parse_Error,
					file = strings.clone(file.fullpath, caller_alloc),
					message = fmt.aprintf(
						"%d syntax error(s) in '%s'",
						file.syntax_error_count,
						file.fullpath,
						allocator = caller_alloc,
					),
				},
			)
			return Validation_Result{ok = false, errors = errors[:]}
		}
	}

	state_found := false

	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_vdecl := decl.derived.(^ast.Value_Decl)
			if !is_vdecl do continue

			if len(v_decl.names) == 0 do continue
			decl_name := ident_name(v_decl.names[0])
			if decl_name == "" do continue

			if decl_name == expected_state.name && len(v_decl.values) > 0 {
				if st, is_struct := v_decl.values[0].derived.(^ast.Struct_Type); is_struct {
					state_found = true
					validate_struct_fields(st, file, expected_state, &errors, &ok, caller_alloc)
				}
			}

			if len(v_decl.values) > 0 {
				if proc_lit, is_proc := v_decl.values[0].derived.(^ast.Proc_Lit); is_proc {
					for exp in expected_procs {
						if decl_name == exp.name {
							validate_proc_signature(
								proc_lit,
								file,
								v_decl,
								exp,
								&errors,
								&ok,
								caller_alloc,
							)
						}
					}
				}
			}
		}
	}

	if !state_found && expected_state.name != "" {
		ok = false
		append(
			&errors,
			Validation_Error {
				kind = .State_Not_Found,
				message = fmt.aprintf(
					"State struct '%s' not found in package '%s'",
					expected_state.name,
					package_path,
					allocator = caller_alloc,
				),
			},
		)
	}

	return Validation_Result{ok = ok, errors = errors[:]}
}

@(private)
run_odin_check :: proc(
	package_path: string,
	errors: ^[dynamic]Validation_Error,
	allocator: mem.Allocator,
) -> bool {
	args := [?]string {
		"odin",
		"check",
		package_path,
		"-no-entry-point",
	}

	stderr_buf: [dynamic]u8
	stderr_buf.allocator = context.temp_allocator

	state, err := run_process(args[:], nil, &stderr_buf)
	if err != nil {
		return true
	}

	if state.exit_code != 0 {
		msg := strings.clone(string(stderr_buf[:]) if len(stderr_buf) > 0 else "odin check failed", allocator)
		append(errors, Validation_Error{kind = .Parse_Error, message = msg})
		return false
	}

	return true
}


@(private)
validate_struct_fields :: proc(
	st: ^ast.Struct_Type,
	file: ^ast.File,
	expected: State_Expectation,
	errors: ^[dynamic]Validation_Error,
	ok: ^bool,
	allocator: mem.Allocator,
) {
	if st.fields == nil do return

	actual_names: [dynamic]string
	actual_types: [dynamic]string
	defer delete(actual_names)
	defer delete(actual_types)

	for field in st.fields.list {
		type_str := expr_to_string(field.type)
		for name_expr in field.names {
			name := ident_name(name_expr)
			if name != "" {
				append(&actual_names, name)
				append(&actual_types, type_str)
			}
		}
	}

	if len(expected.field_names) == 0 do return

	changed := false
	diff_msg := strings.builder_make(context.temp_allocator)

	if len(actual_names) != len(expected.field_names) {
		changed = true
		fmt.sbprintf(
			&diff_msg,
			"  Field count changed: %d -> %d\n",
			len(expected.field_names),
			len(actual_names),
		)
	}

	min_len :=
		len(actual_names) if len(actual_names) < len(expected.field_names) else len(expected.field_names)
	for i in 0 ..< min_len {
		if actual_names[i] != expected.field_names[i] {
			changed = true
			fmt.sbprintf(
				&diff_msg,
				"  Field %d name changed: '%s' -> '%s'\n",
				i,
				expected.field_names[i],
				actual_names[i],
			)
		} else if i < len(expected.field_types) &&
		   !types_match(actual_types[i], expected.field_types[i]) {
			changed = true
			fmt.sbprintf(
				&diff_msg,
				"  Field '%s' changed: %s -> %s\n",
				actual_names[i],
				expected.field_types[i],
				actual_types[i],
			)
		}
	}

	if changed {
		line, col := pos_to_line_col(st.pos)
		ok^ = false
		append(
			errors,
			Validation_Error {
				kind = .State_Layout_Changed,
				file = strings.clone(file.fullpath, allocator),
				line = line,
				col = col,
				message = fmt.aprintf(
					"State struct changed\n%s  Hot reload preserves actor state in memory — struct changes would corrupt it.",
					strings.to_string(diff_msg),
					allocator = allocator,
				),
			},
		)
	}
}

@(private)
validate_proc_signature :: proc(
	proc_lit: ^ast.Proc_Lit,
	file: ^ast.File,
	v_decl: ^ast.Value_Decl,
	expected: Proc_Expectation,
	errors: ^[dynamic]Validation_Error,
	ok: ^bool,
	allocator: mem.Allocator,
) {
	if proc_lit.type == nil do return

	param_count := 0
	param_types: [dynamic]string
	defer delete(param_types)

	if proc_lit.type.params != nil {
		for field in proc_lit.type.params.list {
			type_str := expr_to_string(field.type)
			name_count := len(field.names) if len(field.names) > 0 else 1
			for _ in 0 ..< name_count {
				append(&param_types, type_str)
				param_count += 1
			}
		}
	}

	if param_count != expected.param_count {
		line, col := pos_to_line_col(v_decl.pos)
		ok^ = false
		append(
			errors,
			Validation_Error {
				kind = .Signature_Mismatch,
				file = strings.clone(file.fullpath, allocator),
				line = line,
				col = col,
				message = fmt.aprintf(
					"Proc '%s' parameter count: expected %d, found %d",
					expected.name,
					expected.param_count,
					param_count,
					allocator = allocator,
				),
			},
		)
		return
	}

	for i in 0 ..< len(expected.param_types) {
		if i >= len(param_types) do break
		if param_types[i] != expected.param_types[i] {
			line, col := pos_to_line_col(v_decl.pos)
			ok^ = false
			append(
				errors,
				Validation_Error {
					kind = .Signature_Mismatch,
					file = strings.clone(file.fullpath, allocator),
					line = line,
					col = col,
					message = fmt.aprintf(
						"Proc '%s' param %d type: expected '%s', found '%s'",
						expected.name,
						i,
						expected.param_types[i],
						param_types[i],
						allocator = allocator,
					),
				},
			)
		}
	}
}

@(private)
strip_package_prefix :: proc(type_str: string) -> string {
	if dot := strings.last_index_byte(type_str, '.'); dot >= 0 {
		start := dot
		for start > 0 {
			c := type_str[start - 1]
			if c == '[' || c == '^' || c == ']' do break
			start -= 1
		}
		return strings.concatenate({type_str[:start], type_str[dot + 1:]}, context.temp_allocator)
	}
	return type_str
}

@(private)
types_match :: proc(ast_type: string, runtime_type: string) -> bool {
	if ast_type == runtime_type do return true
	return strip_package_prefix(ast_type) == strip_package_prefix(runtime_type)
}

@(private)
ident_name :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	if ident, ok := expr.derived.(^ast.Ident); ok {
		return ident.name
	}
	return ""
}

@(private)
normalize_builtin_type :: proc(name: string) -> string {
	when size_of(int) == 8 {
		switch name {
		case "int":  return "i64"
		case "uint": return "u64"
		}
	} else {
		switch name {
		case "int":  return "i32"
		case "uint": return "u32"
		}
	}
	when size_of(uintptr) == 8 {
		if name == "uintptr" do return "u64"
	} else {
		if name == "uintptr" do return "u32"
	}
	switch name {
	case "byte": return "u8"
	case "rune": return "i32"
	}
	return name
}

@(private)
expr_to_string :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""

	#partial switch e in expr.derived {
	case ^ast.Ident:
		return normalize_builtin_type(e.name)
	case ^ast.Pointer_Type:
		return fmt.tprintf("^%s", expr_to_string(e.elem))
	case ^ast.Array_Type:
		if e.len != nil {
			return fmt.tprintf("[%s]%s", expr_to_string(e.len), expr_to_string(e.elem))
		}
		return fmt.tprintf("[]%s", expr_to_string(e.elem))
	case ^ast.Dynamic_Array_Type:
		return fmt.tprintf("[dynamic]%s", expr_to_string(e.elem))
	case ^ast.Selector_Expr:
		return fmt.tprintf(
			"%s.%s",
			expr_to_string(e.expr),
			e.field.name if e.field != nil else "?",
		)
	case ^ast.Map_Type:
		return fmt.tprintf("map[%s]%s", expr_to_string(e.key), expr_to_string(e.value))
	case ^ast.Distinct_Type:
		return fmt.tprintf("distinct %s", expr_to_string(e.type))
	case ^ast.Proc_Type:
		return "proc"
	case ^ast.Basic_Lit:
		return e.tok.text
	case ^ast.Helper_Type:
		return fmt.tprintf("[^]%s", expr_to_string(e.type))
	}

	return "?"
}

@(private)
pos_to_line_col :: proc(pos: tokenizer.Pos) -> (line: int, col: int) {
	if pos.line > 0 {
		return pos.line, pos.column
	}
	return 0, 0
}

destroy_validation_result :: proc(result: Validation_Result, allocator := context.allocator) {
	for err in result.errors {
		delete(err.file, allocator)
		delete(err.message, allocator)
	}
	delete(result.errors, allocator)
}

format_validation_error :: proc(err: Validation_Error, actor_name: string) -> string {
	loc: string
	if err.file != "" {
		loc = fmt.tprintf(" (%s:%d:%d)", err.file, err.line, err.col)
	}

	return fmt.tprintf("HOT RELOAD BLOCKED [%s]: %s%s", actor_name, err.message, loc)
}

Proc_Name_Mapping :: struct {
	field_name: string, // e.g. "handle_message"
	proc_name:  string, // e.g. "handle_pair_message"
}

discover_package_procs :: proc(package_path: string, allocator := context.allocator) -> []string {
	arena: vmem.Arena
	arena_err := vmem.arena_init_growing(&arena)
	if arena_err != nil do return nil
	defer vmem.arena_destroy(&arena)
	arena_allocator := vmem.arena_allocator(&arena)

	context.allocator = arena_allocator

	p := parser.default_parser()
	pkg, parse_ok := parser.parse_package_from_path(package_path, &p)
	if !parse_ok || pkg == nil do return nil

	result: [dynamic]string
	result.allocator = allocator

	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_vdecl := decl.derived.(^ast.Value_Decl)
			if !is_vdecl do continue
			if len(v_decl.names) == 0 || len(v_decl.values) == 0 do continue

			if _, is_proc := v_decl.values[0].derived.(^ast.Proc_Lit); is_proc {
				name := ident_name(v_decl.names[0])
				if name != "" {
					append(&result, strings.clone(name, allocator))
				}
			}
		}
	}

	return result[:]
}

discover_proc_names :: proc(
	package_path: string,
	state_type_name: string,
	behaviour_field_names: []string = nil,
	allocator := context.allocator,
) -> []Proc_Name_Mapping {
	arena: vmem.Arena
	arena_err := vmem.arena_init_growing(&arena)
	if arena_err != nil do return nil
	defer vmem.arena_destroy(&arena)
	arena_allocator := vmem.arena_allocator(&arena)

	context.allocator = arena_allocator

	p := parser.default_parser()
	pkg, parse_ok := parser.parse_package_from_path(package_path, &p)
	if !parse_ok || pkg == nil do return nil

	result: [dynamic]Proc_Name_Mapping
	result.allocator = allocator

	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_vdecl := decl.derived.(^ast.Value_Decl)
			if !is_vdecl do continue
			if len(v_decl.values) == 0 do continue

			comp_lit, is_comp := v_decl.values[0].derived.(^ast.Comp_Lit)
			if !is_comp do continue

			type_str := expr_to_string(comp_lit.type)
			if !strings.contains(type_str, state_type_name) do continue

			for elem in comp_lit.elems {
				fv, is_fv := elem.derived.(^ast.Field_Value)
				if !is_fv do continue

				field_name := ident_name(fv.field)
				value_name := ident_name(fv.value)
				if field_name != "" && value_name != "" {
					append(
						&result,
						Proc_Name_Mapping {
							field_name = strings.clone(field_name, allocator),
							proc_name = strings.clone(value_name, allocator),
						},
					)
				}
			}
		}
	}

	if len(result) > 0 || behaviour_field_names == nil {
		return result[:]
	}

	Candidate :: struct {
		name:        string,
		param_count: int,
		param_types: [8]string,
	}

	candidates: [dynamic]Candidate
	ptr_state := fmt.tprintf("^%s", state_type_name)

	for _, file in pkg.files {
		for decl in file.decls {
			vd, is_vd := decl.derived.(^ast.Value_Decl)
			if !is_vd do continue
			if len(vd.names) == 0 || len(vd.values) == 0 do continue

			proc_lit, is_proc := vd.values[0].derived.(^ast.Proc_Lit)
			if !is_proc do continue
			if proc_lit.type == nil || proc_lit.type.params == nil do continue

			pname := ident_name(vd.names[0])
			if pname == "" do continue

			c: Candidate
			c.name = pname

			for field in proc_lit.type.params.list {
				ts := expr_to_string(field.type)
				nc := len(field.names) if len(field.names) > 0 else 1
				for _ in 0 ..< nc {
					if c.param_count < 8 {
						c.param_types[c.param_count] = ts
					}
					c.param_count += 1
				}
			}

			if c.param_count > 0 && c.param_types[0] == ptr_state {
				append(&candidates, c)
			}
		}
	}

	used: map[string]bool

	for field_name in behaviour_field_names {
		if field_name != "handle_message" do continue
		for c in candidates {
			if c.name in used do continue
			if c.param_count == 3 && c.param_types[2] == "any" {
				append(
					&result,
					Proc_Name_Mapping {
						field_name = strings.clone(field_name, allocator),
						proc_name = strings.clone(c.name, allocator),
					},
				)
				used[c.name] = true
				break
			}
		}
	}

	for field_name in behaviour_field_names {
		if field_name == "handle_message" do continue
		for c in candidates {
			if c.name in used do continue
			if c.name == field_name {
				append(
					&result,
					Proc_Name_Mapping {
						field_name = strings.clone(field_name, allocator),
						proc_name = strings.clone(c.name, allocator),
					},
				)
				used[c.name] = true
				break
			}
		}
	}

	for field_name in behaviour_field_names {
		already := false
		for m in result {
			if m.field_name == field_name {
				already = true
				break
			}
		}
		if already do continue

		for c in candidates {
			if c.name in used do continue
			suffix := strings.concatenate({"_", field_name}, context.temp_allocator)
			if strings.has_suffix(c.name, suffix) ||
			   strings.has_suffix(
				   field_name,
				   strings.concatenate({"_", c.name}, context.temp_allocator),
			   ) {
				append(
					&result,
					Proc_Name_Mapping {
						field_name = strings.clone(field_name, allocator),
						proc_name = strings.clone(c.name, allocator),
					},
				)
				used[c.name] = true
				break
			}
		}
	}

	return result[:]
}
