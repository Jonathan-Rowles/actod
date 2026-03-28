package gen_hot_api

import "core:fmt"
import vmem "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

Import_Entry :: struct {
	prefix:      string,
	import_line: string,
}

KNOWN_IMPORTS :: []Import_Entry {
	{"runtime.", `import "base:runtime"`},
	{"log.",     `import "core:log"`},
	{"time.",    `import "core:time"`},
	{"net.",     `import "core:net"`},
	{"sync.",    `import "core:sync"`},
	{"nbio.",    `import "core:nbio"`},
	{"thread.",  `import "core:thread"`},
}

emit_needed_imports :: proc(sb: ^strings.Builder, text: string) {
	for entry in KNOWN_IMPORTS {
		if strings.contains(text, entry.prefix) {
			fmt.sbprintf(sb, "%s\n", entry.import_line)
		}
	}
}

Hot_Kind :: enum {
	Auto,
	Skip,
	Noop,
	Compose,
}

Default_Override :: struct {
	param_name: string,
	value:      string,
}

Proc_Info :: struct {
	name:              string,
	kind:              Hot_Kind,
	host_name:         string,
	compose_body:      string,
	default_overrides: [dynamic]Default_Override,
	extra_params:      [dynamic]string,
	params:            [dynamic]Param_Info,
	results:           [dynamic]Result_Info,
	is_generic:        bool,
	calling_conv:      string,
}

Param_Info :: struct {
	name:         string,
	type_str:     string,
	default_expr: string,
	is_poly:      bool,
}

Result_Info :: struct {
	name:     string,
	type_str: string,
}

Type_Alias :: struct {
	name:   string,
	target: string,
}

main :: proc() {
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil {
		fmt.eprintln("Failed to init arena")
		os.exit(1)
	}
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	if !os.is_file("act.odin") {
		fmt.eprintln("Error: act.odin not found. Run from project root.")
		os.exit(1)
	}

	aliases, procs := parse_act_file()
	types_shim, discovered_types := build_types_shim("src/actod", aliases[:], procs[:])
	actod_shim := build_actod_shim(procs[:], aliases[:], discovered_types)
	hot_api_struct := build_hot_api_struct_text(procs[:])
	hot_api_init := build_hot_api_init(procs[:])

	write_generated_shims(types_shim, actod_shim)
	write_hot_api_generated(hot_api_struct, hot_api_init)

	fmt.println("Generated:")
	fmt.println("  src/pkgs/hot_reload/generated_shims.odin")
	fmt.println("  src/actod/hot_api_generated.odin")
}


parse_act_file :: proc() -> (aliases: [dynamic]Type_Alias, procs: [dynamic]Proc_Info) {
	p := parser.default_parser()
	pkg, parse_ok := parser.parse_package_from_path(".", &p)
	if !parse_ok || pkg == nil {
		fmt.eprintln("Failed to parse root package")
		os.exit(1)
	}

	file: ^ast.File
	for _, f in pkg.files {
		base := filepath.base(f.fullpath)
		if base == "act.odin" {
			file = f
			break
		}
	}
	if file == nil {
		fmt.eprintln("act.odin not found in parsed package")
		os.exit(1)
	}

	for decl in file.decls {
		v_decl, is_vdecl := decl.derived.(^ast.Value_Decl)
		if !is_vdecl do continue
		if len(v_decl.names) == 0 || len(v_decl.values) == 0 do continue

		name := ident_name(v_decl.names[0])
		if name == "" do continue

		if sel, is_sel := v_decl.values[0].derived.(^ast.Selector_Expr); is_sel {
			prefix := expr_to_string(sel.expr)
			field := sel.field.name if sel.field != nil else ""
			if prefix == "actod" && field != "" {
				append(&aliases, Type_Alias{name = name, target = field})
			}
			continue
		}

		proc_lit, is_proc := v_decl.values[0].derived.(^ast.Proc_Lit)
		if !is_proc do continue

		info := Proc_Info {
			name = name,
		}
		parse_hot_attribute(v_decl, &info)

		if proc_lit.type != nil {
			#partial switch cc in proc_lit.type.calling_convention {
			case string:
				if cc != "" do info.calling_conv = cc
			}
		}

		if proc_lit.type != nil && proc_lit.type.params != nil {
			for field in proc_lit.type.params.list {
				type_str := expr_to_string(field.type)
				default_str :=
					expr_to_string(field.default_value) if field.default_value != nil else ""

				is_poly := strings.has_prefix(type_str, "$")
				if is_poly do info.is_generic = true
				if strings.contains(type_str, "(T)") do info.is_generic = true

				if len(field.names) == 0 {
					append(
						&info.params,
						Param_Info {
							type_str = type_str,
							default_expr = default_str,
							is_poly = is_poly,
						},
					)
				} else {
					for name_expr in field.names {
						append(
							&info.params,
							Param_Info {
								name = ident_name(name_expr),
								type_str = type_str,
								default_expr = default_str,
								is_poly = is_poly,
							},
						)
					}
				}
			}
		}

		if proc_lit.type != nil && proc_lit.type.results != nil {
			for field in proc_lit.type.results.list {
				type_str := expr_to_string(field.type)
				if len(field.names) > 0 {
					for name_expr in field.names {
						rname := ident_name(name_expr)
						append(&info.results, Result_Info{name = rname, type_str = type_str})
					}
				} else {
					append(&info.results, Result_Info{type_str = type_str})
				}
			}
		}

		append(&procs, info)
	}

	return
}

parse_hot_attribute :: proc(v_decl: ^ast.Value_Decl, info: ^Proc_Info) {
	for attr in v_decl.attributes {
		if attr == nil do continue
		for expr in attr.elems {
			fv, is_fv := expr.derived.(^ast.Field_Value)
			if !is_fv do continue

			field_ident, is_ident := fv.field.derived.(^ast.Ident)
			if !is_ident || field_ident.name != "hot" do continue

			value_str := ""
			if lit, is_lit := fv.value.derived.(^ast.Basic_Lit); is_lit {
				value_str = unquote(lit.tok.text)
			}
			if value_str == "" do continue

			if value_str == "skip" {
				info.kind = .Skip
				return
			}
			if value_str == "noop" {
				info.kind = .Noop
				return
			}
			if strings.has_prefix(value_str, "host_name ") {
				info.host_name = strings.trim_space(value_str[len("host_name "):])
				return
			}
			if strings.has_prefix(value_str, "extra_param ") {
				append(&info.extra_params, strings.trim_space(value_str[len("extra_param "):]))
				return
			}
			if strings.has_prefix(value_str, "compose") {
				info.kind = .Compose
				body_text := strings.trim_left(value_str[len("compose"):], "\n")

				body_lines: [dynamic]string
				for line in strings.split_lines(body_text) {
					trimmed := strings.trim_space(line)
					if trimmed == "" do continue

					if strings.has_prefix(trimmed, "default ") {
						rest := strings.trim_space(trimmed[len("default "):])
						eq_idx := strings.index_byte(rest, '=')
						if eq_idx > 0 {
							append(
								&info.default_overrides,
								Default_Override {
									param_name = strings.trim_space(rest[:eq_idx]),
									value = strings.trim_space(rest[eq_idx + 1:]),
								},
							)
						}
					} else {
						append(&body_lines, line)
					}
				}
				info.compose_body = strings.join(body_lines[:], "\n")
				return
			}
		}
	}
}


needs_hot_api_entry :: proc(p: Proc_Info) -> bool {
	if p.kind == .Noop do return false
	if p.kind == .Auto do return true
	if p.kind == .Skip {
		if p.is_generic do return false
		for param in p.params {
			if param.type_str == "?" || strings.has_prefix(param.type_str, "..") do return false
		}
		return true
	}
	if p.kind == .Compose {
		needle := fmt.tprintf("hot_api.%s(", p.name)
		return strings.contains(p.compose_body, needle)
	}
	return false
}

api_field_name :: proc(p: Proc_Info) -> string {
	return p.name
}

host_func_name :: proc(p: Proc_Info) -> string {
	if p.host_name != "" do return p.host_name
	if p.is_generic && p.kind == .Auto {
		switch p.name {
		case "send_message":
			return "send_message_any"
		case "broadcast":
			return "broadcast_any"
		case "publish":
			return "publish_any"
		}
	}
	return p.name
}


format_results :: proc(results: []Result_Info, for_struct: bool) -> string {
	if len(results) == 0 do return ""
	if len(results) == 1 {
		return fmt.aprintf(" -> %s", results[0].type_str)
	}
	sb := strings.builder_make()
	fmt.sbprint(&sb, " -> (")
	for r, i in results {
		if i > 0 do fmt.sbprint(&sb, ", ")
		if r.name != "" && r.name != "_" && !for_struct {
			fmt.sbprintf(&sb, "%s: %s", r.name, r.type_str)
		} else {
			fmt.sbprint(&sb, r.type_str)
		}
	}
	fmt.sbprint(&sb, ")")
	return strings.to_string(sb)
}


build_types_shim :: proc(
	actod_pkg_path: string,
	aliases: []Type_Alias,
	procs: []Proc_Info,
) -> (
	string,
	map[string]bool,
) {
	p := parser.default_parser()
	pkg, parse_ok := parser.parse_package_from_path(actod_pkg_path, &p)
	if !parse_ok || pkg == nil {
		fmt.eprintln("Failed to parse actod package at", actod_pkg_path)
		os.exit(1)
	}

	all_decls: map[string]^ast.Value_Decl
	decl_files: map[string]^ast.File
	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_vdecl := decl.derived.(^ast.Value_Decl)
			if !is_vdecl do continue
			if len(v_decl.names) == 0 || len(v_decl.values) == 0 do continue
			name := ident_name(v_decl.names[0])
			if name == "" do continue
			for attr in v_decl.attributes {
				if attr == nil do continue
				for elem in attr.elems {
					if ident, ok := elem.derived.(^ast.Ident); ok && ident.name == "private" {
						continue
					}
				}
			}
			all_decls[name] = v_decl
			decl_files[name] = file
		}
	}

	needed: map[string]bool
	queue: [dynamic]string

	seed_name :: proc(name: string, all_decls: ^map[string]^ast.Value_Decl, needed: ^map[string]bool, queue: ^[dynamic]string) {
		if name in needed^ do return
		if name not_in all_decls^ do return
		needed[name] = true
		append(queue, name)
	}

	for a in aliases {
		seed_name(a.target, &all_decls, &needed, &queue)
	}
	for p in procs {
		for param in p.params {
			collect_idents_from_type_str(param.type_str, &all_decls, &needed, &queue)
		}
		for r in p.results {
			collect_idents_from_type_str(r.type_str, &all_decls, &needed, &queue)
		}
	}
	seed_name("Raw_Spawn_Behaviour", &all_decls, &needed, &queue)

	idx := 0
	for idx < len(queue) {
		name := queue[idx]
		idx += 1
		decl := all_decls[name]
		if decl == nil do continue

		refs: map[string]bool
		for val in decl.values {
			collect_idents_from_expr(val, &refs)
		}
		if decl.type != nil {
			collect_idents_from_expr(decl.type, &refs)
		}

		for ref_name in refs {
			seed_name(ref_name, &all_decls, &needed, &queue)
		}
	}

	type_sources: map[string]string
	ordered: [dynamic]string
	for name in needed {
		file := decl_files[name]
		decl := all_decls[name]
		if file == nil || decl == nil do continue

		start := decl.pos.offset
		end := decl.end.offset
		if start >= 0 && end > start && end <= len(file.src) {
			src := string(file.src[start:end])
			if strings.has_prefix(src, "@(private)") {
				nl := strings.index_byte(src, '\n')
				if nl >= 0 {
					src = strings.trim_left_space(src[nl + 1:])
				}
			}
			src = strip_inline_comments(src)
			type_sources[name] = src
			append(&ordered, name)
		}
	}

	all_type_text := strings.builder_make()
	for name in ordered {
		if src, ok := type_sources[name]; ok {
			fmt.sbprint(&all_type_text, src)
		}
	}

	sb := strings.builder_make()
	fmt.sbprint(&sb, "// Code generated by tools/gen_hot_api — DO NOT EDIT\npackage actod\n\n")
	emit_needed_imports(&sb, strings.to_string(all_type_text))
	fmt.sbprint(&sb, "\n")

	for name in ordered {
		if src, ok := type_sources[name]; ok {
			fmt.sbprintf(&sb, "%s\n\n", src)
		}
	}

	return strings.to_string(sb), needed
}

@(private)
collect_idents_from_type_str :: proc(
	type_str: string,
	all_decls: ^map[string]^ast.Value_Decl,
	needed: ^map[string]bool,
	queue: ^[dynamic]string,
) {
	i := 0
	for i < len(type_str) {
		if !is_ident_start(type_str[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(type_str) && is_ident_char(type_str[i]) {
			i += 1
		}
		name := type_str[start:i]
		if name not_in needed^ && name in all_decls^ {
			needed[name] = true
			append(queue, name)
		}
	}
}

@(private)
is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

@(private)
is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

@(private)
collect_idents_from_expr :: proc(expr: ^ast.Expr, out: ^map[string]bool) {
	if expr == nil do return

	#partial switch e in expr.derived {
	case ^ast.Ident:
		out[e.name] = true
	case ^ast.Pointer_Type:
		collect_idents_from_expr(e.elem, out)
	case ^ast.Array_Type:
		collect_idents_from_expr(e.len, out)
		collect_idents_from_expr(e.elem, out)
	case ^ast.Dynamic_Array_Type:
		collect_idents_from_expr(e.elem, out)
	case ^ast.Map_Type:
		collect_idents_from_expr(e.key, out)
		collect_idents_from_expr(e.value, out)
	case ^ast.Distinct_Type:
		collect_idents_from_expr(e.type, out)
	case ^ast.Proc_Type:
		collect_idents_from_field_list(e.params, out)
		collect_idents_from_field_list(e.results, out)
	case ^ast.Struct_Type:
		collect_idents_from_field_list(e.fields, out)
	case ^ast.Union_Type:
		for variant in e.variants {
			collect_idents_from_expr(variant, out)
		}
	case ^ast.Enum_Type:
		collect_idents_from_expr(e.base_type, out)
	case ^ast.Selector_Expr:
		// Skip -- external package references (e.g. log.Level)
	case ^ast.Call_Expr:
		collect_idents_from_expr(e.expr, out)
		for arg in e.args {
			collect_idents_from_expr(arg, out)
		}
	case ^ast.Paren_Expr:
		collect_idents_from_expr(e.expr, out)
	case ^ast.Unary_Expr:
		collect_idents_from_expr(e.expr, out)
	case ^ast.Binary_Expr:
		collect_idents_from_expr(e.left, out)
		collect_idents_from_expr(e.right, out)
	case ^ast.Bit_Set_Type:
		collect_idents_from_expr(e.elem, out)
		collect_idents_from_expr(e.underlying, out)
	case ^ast.Field_Value:
		collect_idents_from_expr(e.value, out)
	case ^ast.Comp_Lit:
		collect_idents_from_expr(e.type, out)
		for elem in e.elems {
			collect_idents_from_expr(elem, out)
		}
	}
}

@(private)
collect_idents_from_field_list :: proc(fl: ^ast.Field_List, out: ^map[string]bool) {
	if fl == nil do return
	for field in fl.list {
		collect_idents_from_expr(field.type, out)
		collect_idents_from_expr(field.default_value, out)
	}
}

strip_inline_comments :: proc(src: string) -> string {
	lines := strings.split_lines(src)
	sb := strings.builder_make()
	for line, i in lines {
		cleaned := line
		if !strings.has_prefix(strings.trim_space(line), "//") {
			comment_idx := find_comment_start(line)
			if comment_idx >= 0 {
				cleaned = strings.trim_right_space(line[:comment_idx])
			}
		} else {
			continue
		}
		if i > 0 do fmt.sbprint(&sb, "\n")
		fmt.sbprint(&sb, cleaned)
	}
	return strings.to_string(sb)
}

find_comment_start :: proc(line: string) -> int {
	in_string := false
	for i := 0; i < len(line) - 1; i += 1 {
		if line[i] == '"' do in_string = !in_string
		if !in_string && line[i] == '/' && line[i + 1] == '/' {
			return i
		}
	}
	return -1
}


build_actod_shim :: proc(procs: []Proc_Info, aliases: []Type_Alias, discovered_types: map[string]bool) -> string {
	procs_sb := strings.builder_make()
	fmt.sbprint(&procs_sb, build_hot_api_struct_text(procs))
	fmt.sbprint(&procs_sb, "\n@(export)\nhot_api: ^Hot_API\n\n")
	for p in procs {
		if p.kind == .Skip && !needs_hot_api_entry(p) do continue
		emit_shim_proc(&procs_sb, p)
		fmt.sbprint(&procs_sb, "\n")
	}

	procs_text := strings.to_string(procs_sb)

	out := strings.builder_make()
	fmt.sbprint(&out, "// Code generated by tools/gen_hot_api — DO NOT EDIT\npackage actod\n\n")
	emit_needed_imports(&out, procs_text)
	fmt.sbprint(&out, "\n")
	fmt.sbprint(&out, procs_text)

	return strings.to_string(out)
}

emit_shim_proc :: proc(sb: ^strings.Builder, p: Proc_Info) {
	fmt.sbprintf(sb, "%s :: proc", p.name)

	if p.calling_conv != "" {
		fmt.sbprintf(sb, " %s", p.calling_conv)
	}

	fmt.sbprint(sb, "(")

	param_count := 0
	for param in p.params {
		if param_count > 0 do fmt.sbprint(sb, ", ")
		if param.name != "" {
			fmt.sbprintf(sb, "%s: ", param.name)
		}
		fmt.sbprint(sb, map_act_alias(param.type_str))

		default_val := get_shim_default(p, param)
		if default_val != "" {
			fmt.sbprintf(sb, " = %s", default_val)
		}
		param_count += 1
	}

	for extra in p.extra_params {
		if param_count > 0 do fmt.sbprint(sb, ", ")
		fmt.sbprint(sb, extra)
		param_count += 1
	}

	fmt.sbprint(sb, ")")
	fmt.sbprint(sb, format_results(p.results[:], false))
	fmt.sbprint(sb, " {\n")

	switch p.kind {
	case .Noop:
		fmt.sbprint(sb, "\t// no-op in hot reload shim — types are registered by the host\n")
	case .Compose:
		for line in strings.split_lines(p.compose_body) {
			if strings.trim_space(line) == "" do continue
			fmt.sbprintf(sb, "\t%s\n", line)
		}
	case .Auto, .Skip:
		emit_auto_bridge_body(sb, p)
	}

	fmt.sbprint(sb, "}\n")
}

emit_auto_bridge_body :: proc(sb: ^strings.Builder, p: Proc_Info) {
	has_return := len(p.results) > 0

	if has_return {
		fmt.sbprintf(sb, "\treturn hot_api.%s(", p.name)
	} else {
		fmt.sbprintf(sb, "\thot_api.%s(", p.name)
	}

	param_count := 0
	for param in p.params {
		if param_count > 0 do fmt.sbprint(sb, ", ")
		fmt.sbprint(sb, param.name)
		param_count += 1
	}

	for extra in p.extra_params {
		if param_count > 0 do fmt.sbprint(sb, ", ")
		colon_idx := strings.index_byte(extra, ':')
		if colon_idx > 0 {
			fmt.sbprint(sb, strings.trim_space(extra[:colon_idx]))
		}
		param_count += 1
	}

	fmt.sbprint(sb, ")\n")
}

get_shim_default :: proc(p: Proc_Info, param: Param_Info) -> string {
	for d in p.default_overrides {
		if d.param_name == param.name do return d.value
	}
	if param.default_expr != "" {
		if strings.contains(param.default_expr, "actod.") {
			return zero_default_for_type(param.type_str)
		}
		return param.default_expr
	}
	return ""
}

zero_default_for_type :: proc(type_str: string) -> string {
	if strings.has_prefix(type_str, "^") do return "nil"
	if strings.has_prefix(type_str, "proc") do return "nil"
	switch type_str {
	case "string", "cstring":             return `""`
	case "bool":                          return "false"
	case "int", "i8", "i16", "i32", "i64",
	     "uint", "u8", "u16", "u32", "u64",
	     "f32", "f64", "uintptr":         return "0"
	}
	return "{}"
}


SPAWN_RAW_FIELD :: `	spawn_raw:                proc(
		name: string,
		data_ptr: rawptr,
		data_size: int,
		behaviour: Raw_Spawn_Behaviour,
		opts: Actor_Config,
		parent_pid: PID,
	) -> (
		PID,
		bool,
	),
`

SPAWN_CHILD_RAW_FIELD :: `	spawn_child_raw:          proc(
		name: string,
		data_ptr: rawptr,
		data_size: int,
		behaviour: Raw_Spawn_Behaviour,
		opts: Actor_Config,
	) -> (PID, bool),
`

build_hot_api_struct_text :: proc(procs: []Proc_Info) -> string {
	sb := strings.builder_make()
	fmt.sbprint(&sb, "Hot_API :: struct {\n")

	need_spawn_raw := false
	need_spawn_child_raw := false

	for p in procs {
		if !needs_hot_api_entry(p) {
			if p.kind == .Compose {
				if strings.contains(p.compose_body, "hot_api.spawn_raw(") do need_spawn_raw = true
				if strings.contains(p.compose_body, "hot_api.spawn_child_raw(") do need_spawn_child_raw = true
			}
			continue
		}

		field_name := api_field_name(p)
		fmt.sbprintf(&sb, "\t%s:", field_name)

		pad := 26 - len(field_name)
		if pad < 1 do pad = 1
		for _ in 0 ..< pad do fmt.sbprint(&sb, " ")

		fmt.sbprint(&sb, "proc(")

		total_params := len(p.params) + len(p.extra_params)
		needs_multiline := total_params > 4

		param_count := 0
		if needs_multiline {
			fmt.sbprint(&sb, "\n")
			for param in p.params {
				if param_count > 0 do fmt.sbprint(&sb, ",\n")
				type_str := resolve_type(param.type_str)
				fmt.sbprintf(&sb, "\t\t%s: %s", param.name, type_str)
				param_count += 1
			}
			for extra in p.extra_params {
				if param_count > 0 do fmt.sbprint(&sb, ",\n")
				eq_idx := strings.index_byte(extra, '=')
				text := extra if eq_idx < 0 else strings.trim_space(extra[:eq_idx])
				fmt.sbprintf(&sb, "\t\t%s", text)
				param_count += 1
			}
			fmt.sbprint(&sb, ",\n\t)")
		} else {
			for param in p.params {
				if param_count > 0 do fmt.sbprint(&sb, ", ")
				type_str := resolve_type(param.type_str)
				if param.name != "" {
					fmt.sbprintf(&sb, "%s: %s", param.name, type_str)
				} else {
					fmt.sbprint(&sb, type_str)
				}
				param_count += 1
			}
			for extra in p.extra_params {
				if param_count > 0 do fmt.sbprint(&sb, ", ")
				eq_idx := strings.index_byte(extra, '=')
				text := extra if eq_idx < 0 else strings.trim_space(extra[:eq_idx])
				fmt.sbprint(&sb, text)
				param_count += 1
			}
			fmt.sbprint(&sb, ")")
		}

		fmt.sbprint(&sb, format_results(p.results[:], true))
		fmt.sbprint(&sb, ",\n")
	}

	if need_spawn_raw do fmt.sbprint(&sb, SPAWN_RAW_FIELD)
	if need_spawn_child_raw do fmt.sbprint(&sb, SPAWN_CHILD_RAW_FIELD)

	fmt.sbprint(&sb, "}\n")
	return strings.to_string(sb)
}

build_hot_api_init :: proc(procs: []Proc_Info) -> string {
	sb := strings.builder_make()
	fmt.sbprint(&sb, "g_hot_api := Hot_API{\n")

	need_spawn_raw := false
	need_spawn_child_raw := false

	for p in procs {
		if !needs_hot_api_entry(p) {
			if p.kind == .Compose {
				if strings.contains(p.compose_body, "hot_api.spawn_raw(") do need_spawn_raw = true
				if strings.contains(p.compose_body, "hot_api.spawn_child_raw(") do need_spawn_child_raw = true
			}
			continue
		}

		field := api_field_name(p)
		host := host_func_name(p)

		pad := 23 - len(field)
		if pad < 1 do pad = 1

		fmt.sbprintf(&sb, "\t%s", field)
		for _ in 0 ..< pad do fmt.sbprint(&sb, " ")
		fmt.sbprintf(&sb, "= %s,\n", host)
	}

	if need_spawn_raw {
		fmt.sbprint(&sb, "\tspawn_raw              = spawn_from_raw,\n")
	}
	if need_spawn_child_raw {
		fmt.sbprint(&sb, "\tspawn_child_raw        = spawn_child_from_raw,\n")
	}

	fmt.sbprint(&sb, "}\n")
	return strings.to_string(sb)
}


write_generated_shims :: proc(types_shim: string, actod_shim: string) {
	sb := strings.builder_make()
	fmt.sbprint(&sb, `// Code generated by tools/gen_hot_api — DO NOT EDIT
package hot_reload

`)
	fmt.sbprint(&sb, "TYPES_SHIM :: `")
	fmt.sbprint(&sb, types_shim)
	fmt.sbprint(&sb, "`\n\n")
	fmt.sbprint(&sb, "ACTOD_SHIM :: `")
	fmt.sbprint(&sb, actod_shim)
	fmt.sbprint(&sb, "`\n")

	path := "src/pkgs/hot_reload/generated_shims.odin"
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(sb)); err != nil {
		fmt.eprintln("Failed to write", path, err)
		os.exit(1)
	}
}

write_hot_api_generated :: proc(hot_api_struct: string, hot_api_init: string) {
	combined := strings.concatenate({hot_api_struct, "\n", hot_api_init})

	sb := strings.builder_make()
	fmt.sbprint(&sb, "// Code generated by tools/gen_hot_api — DO NOT EDIT\npackage actod\n\n")
	emit_needed_imports(&sb, combined)
	fmt.sbprint(&sb, "\n")
	fmt.sbprint(&sb, hot_api_struct)
	fmt.sbprint(&sb, "\n")
	fmt.sbprint(&sb, hot_api_init)

	path := "src/actod/hot_api_generated.odin"
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(sb)); err != nil {
		fmt.eprintln("Failed to write", path, err)
		os.exit(1)
	}
}


map_act_alias :: proc(type_str: string) -> string {
	if type_str == "Log_Level" do return "log.Level"
	if type_str == "Log_Options" do return "log.Options"
	return type_str
}

resolve_type :: proc(type_str: string) -> string {
	if type_str == "$T" || strings.has_prefix(type_str, "$") do return "any"
	return map_act_alias(type_str)
}

ident_name :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	if ident, ok := expr.derived.(^ast.Ident); ok do return ident.name
	return ""
}

expr_to_string :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""

	#partial switch e in expr.derived {
	case ^ast.Ident:
		return e.name
	case ^ast.Poly_Type:
		return fmt.aprintf("$%s", expr_to_string(e.type))
	case ^ast.Pointer_Type:
		return fmt.aprintf("^%s", expr_to_string(e.elem))
	case ^ast.Array_Type:
		if e.len != nil {
			return fmt.aprintf("[%s]%s", expr_to_string(e.len), expr_to_string(e.elem))
		}
		return fmt.aprintf("[]%s", expr_to_string(e.elem))
	case ^ast.Dynamic_Array_Type:
		return fmt.aprintf("[dynamic]%s", expr_to_string(e.elem))
	case ^ast.Selector_Expr:
		return fmt.aprintf(
			"%s.%s",
			expr_to_string(e.expr),
			e.field.name if e.field != nil else "?",
		)
	case ^ast.Map_Type:
		return fmt.aprintf("map[%s]%s", expr_to_string(e.key), expr_to_string(e.value))
	case ^ast.Distinct_Type:
		return fmt.aprintf("distinct %s", expr_to_string(e.type))
	case ^ast.Proc_Type:
		return "proc"
	case ^ast.Basic_Lit:
		return e.tok.text
	case ^ast.Typeid_Type:
		return "typeid"
	case ^ast.Unary_Expr:
		return fmt.aprintf("%s%s", e.op.text, expr_to_string(e.expr))
	case ^ast.Binary_Expr:
		return fmt.aprintf("%s %s %s", expr_to_string(e.left), e.op.text, expr_to_string(e.right))
	case ^ast.Paren_Expr:
		return fmt.aprintf("(%s)", expr_to_string(e.expr))
	case ^ast.Call_Expr:
		args_sb := strings.builder_make()
		for arg, i in e.args {
			if i > 0 do fmt.sbprint(&args_sb, ", ")
			fmt.sbprint(&args_sb, expr_to_string(arg))
		}
		return fmt.aprintf("%s(%s)", expr_to_string(e.expr), strings.to_string(args_sb))
	case ^ast.Index_Expr:
		return fmt.aprintf("%s(%s)", expr_to_string(e.expr), expr_to_string(e.index))
	case ^ast.Implicit_Selector_Expr:
		if e.field != nil do return fmt.aprintf(".%s", e.field.name)
		return ".?"
	}

	return "?"
}

unquote :: proc(s: string) -> string {
	if len(s) < 2 do return s
	if s[0] == '"' && s[len(s) - 1] == '"' do return s[1:len(s) - 1]
	if s[0] == '`' && s[len(s) - 1] == '`' do return s[1:len(s) - 1]
	return s
}
