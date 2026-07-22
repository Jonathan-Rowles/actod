package actod

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"

Var_Field_Info :: struct {
	offset: uintptr,
}

Union_Variant_Fields :: struct {
	var_fields: []Var_Field_Info,
}

Union_Field_Info :: struct {
	tag_offset: uintptr,
	tag_size:   int,
	no_nil:     bool,
	variants:   []Union_Variant_Fields,
}

Message_Type_Flags :: enum u32 {
	Has_Var_Fields = 0,
	Has_Unions     = 1,
}

Message_Type_Flags_Set :: bit_set[Message_Type_Flags;u32]

Message_Deliver_Proc :: proc(to_pid: PID, from_pid: PID, payload: []byte) -> Send_Error

Message_Type_Info :: struct {
	type_id:          typeid,
	name:             string,
	type_hash:        u64,
	size:             int,
	wire_header_size: int,
	type_info:        ^runtime.Type_Info,
	flags:            Message_Type_Flags_Set,
	var_fields:       []Var_Field_Info,
	union_fields:     []Union_Field_Info,
	deliver:          Message_Deliver_Proc,
}

MAX_MESSAGE_TYPES :: 256

@(private)
g_message_registry: Name_Registry(Message_Type_Info, MAX_MESSAGE_TYPES)

@(fini)
cleanup_message_registry :: proc "contextless" () {
	context = runtime.default_context()
	registry_destroy(&g_message_registry)
}

get_type_info_ptr :: proc(
	id: typeid,
	loc := #caller_location,
) -> (
	^Message_Type_Info,
	bool,
) {
	registry_ensure_init(&g_message_registry, loc)

	for i in 0 ..< g_message_registry.count {
		if g_message_registry.entries[i].value.type_id == id {
			return &g_message_registry.entries[i].value, true
		}
	}

	return nil, false
}

get_type_info_by_hash :: #force_inline proc(
	type_hash: u64,
	loc := #caller_location,
) -> (
	^Message_Type_Info,
	bool,
) {
	return registry_get_by_hash(&g_message_registry, type_hash, loc)
}

get_active_union_variant :: #force_inline proc(
	value_ptr: rawptr,
	uf: Union_Field_Info,
) -> (
	Union_Variant_Fields,
	bool,
) {
	tag_ptr := rawptr(uintptr(value_ptr) + uf.tag_offset)
	tag: int
	switch uf.tag_size {
	case 1:
		tag = int((cast(^u8)tag_ptr)^)
	case 2:
		tag = int((cast(^u16)tag_ptr)^)
	case 4:
		tag = int((cast(^u32)tag_ptr)^)
	case 8:
		tag = int((cast(^u64)tag_ptr)^)
	case:
		return {}, false
	}

	variant_idx := tag if uf.no_nil else tag - 1
	if variant_idx < 0 || variant_idx >= len(uf.variants) {
		return {}, false
	}
	return uf.variants[variant_idx], true
}

Temp_Union_Info :: struct {
	tag_offset: uintptr,
	tag_size:   int,
	no_nil:     bool,
	variants:   []Temp_Variant_Info,
}

Temp_Variant_Info :: struct {
	var_fields: [dynamic]Var_Field_Info,
}

register_message_type :: proc "contextless" ($T: typeid, loc := #caller_location) {
	assert_message_fits_page(T)

	context = runtime.default_context()
	registry_ensure_init(&g_message_registry, loc)

	// Fast path: already registered?
	for i in 0 ..< g_message_registry.count {
		if g_message_registry.entries[i].value.type_id == T {
			return
		}
	}

	ti := type_info_of(T)

	type_name := get_type_name(ti, allocator = g_message_registry.allocator)
	if type_name == "" {
		panic_at(
			loc,
			"register_message_type: could not derive a name for type %v, message types must be named types, not anonymous ones",
			typeid_of(T),
		)
	}

	allow_byte_slices := true

	temp_var_fields := make([dynamic]Var_Field_Info)
	temp_union_fields := make([dynamic]Temp_Union_Info)

	info := Message_Type_Info {
		type_id          = T,
		size             = size_of(T),
		wire_header_size = 4 + NETWORK_HEADER_SIZE + size_of(T),
		type_info        = ti,
		flags            = {},
	}

	safe, unsafe_field := check_type_safety(
		ti,
		"",
		&info,
		0,
		&temp_var_fields,
		allow_byte_slices,
		&temp_union_fields,
	)
	if !safe {
		delete(temp_var_fields)
		cleanup_temp_union_fields(temp_union_fields[:])
		delete(temp_union_fields)
		panic_at(
			loc,
			"\n\nACTOR SAFETY ERROR: Message type '%v' contains unsafe field!\n" +
			"  Unsafe field: %s\n" +
			"  Use fixed-size arrays [N]T instead of slices []T.\n" +
			"  Remove pointers, maps, and dynamic arrays from message types.\n\n",
			typeid_of(T),
			unsafe_field,
		)
	}

	if len(temp_var_fields) > 0 {
		info.var_fields = make(
			[]Var_Field_Info,
			len(temp_var_fields),
			g_message_registry.allocator,
		)
		copy(info.var_fields, temp_var_fields[:])
	}

	if len(temp_union_fields) > 0 {
		info.union_fields = make(
			[]Union_Field_Info,
			len(temp_union_fields),
			g_message_registry.allocator,
		)
		for &uf, ui in temp_union_fields {
			info.union_fields[ui] = Union_Field_Info {
				tag_offset = uf.tag_offset,
				tag_size   = uf.tag_size,
				no_nil     = uf.no_nil,
			}
			info.union_fields[ui].variants = make(
				[]Union_Variant_Fields,
				len(uf.variants),
				g_message_registry.allocator,
			)
			for &vf, vi in uf.variants {
				if len(vf.var_fields) > 0 {
					info.union_fields[ui].variants[vi].var_fields = make(
						[]Var_Field_Info,
						len(vf.var_fields),
						g_message_registry.allocator,
					)
					copy(info.union_fields[ui].variants[vi].var_fields, vf.var_fields[:])
				}
			}
		}
	}

	info.deliver = proc(to_pid: PID, from_pid: PID, payload: []byte) -> Send_Error {
		if len(payload) < size_of(T) {
			log.errorf(
				"Payload too small for %v: expected >= %d, got %d",
				typeid_of(T),
				size_of(T),
				len(payload),
			)
			return .NETWORK_ERROR
		}

		value := (cast(^T)raw_data(payload))^

		type_info := get_validated_message_info_ptr(T)
		data_offset := size_of(T)
		payload_len := len(payload)

		if .Has_Var_Fields in type_info.flags {
			for field in type_info.var_fields {
				field_ptr := cast(^[]byte)(uintptr(&value) + field.offset)
				field_len := len(field_ptr^)
				if field_len > 0 {
					if data_offset + field_len > payload_len {
						log.errorf(
							"Payload too small for variable field in %v: need %d, have %d",
							typeid_of(T),
							data_offset + field_len,
							payload_len,
						)
						return .NETWORK_ERROR
					}
					field_ptr^ = payload[data_offset:data_offset + field_len]
					data_offset += field_len
				}
			}
		}

		if .Has_Unions in type_info.flags {
			for uf in type_info.union_fields {
				variant, ok := get_active_union_variant(&value, uf)
				if !ok do continue
				for field in variant.var_fields {
					field_ptr := cast(^[]byte)(uintptr(&value) + field.offset)
					field_len := len(field_ptr^)
					if field_len > 0 {
						if data_offset + field_len > payload_len {
							log.errorf(
								"Payload too small for union variable field in %v: need %d, have %d",
								typeid_of(T),
								data_offset + field_len,
								payload_len,
							)
							return .NETWORK_ERROR
						}
						field_ptr^ = payload[data_offset:data_offset + field_len]
						data_offset += field_len
					}
				}
			}
		}

		result := send_message(to_pid, value)

		return result
	}

	type_hash := fnv1a_hash(type_name)
	info.type_hash = type_hash
	info.name = type_name

	when ODIN_DEBUG {
		existing, found := get_type_info_by_hash(type_hash, loc)
		if found && existing.type_id != T {
			panic_at(
				loc,
				"message type hash collision: '%v' and '%v' both hash to %x. Rename one of them.",
				existing.type_id,
				typeid_of(T),
				type_hash,
			)
		}
	}

	registry_register(&g_message_registry, type_name, info, loc)

	delete(temp_var_fields)
	cleanup_temp_union_fields(temp_union_fields[:])
	delete(temp_union_fields)
}

cleanup_temp_union_fields :: proc(fields: []Temp_Union_Info) {
	for &uf in fields {
		for &vf in uf.variants {
			delete(vf.var_fields)
		}
		delete(uf.variants)
	}
}

get_validated_message_info_ptr :: #force_inline proc(
	$T: typeid,
	loc := #caller_location,
) -> ^Message_Type_Info {
	assert_message_fits_page(T)

	@(static) _cached: ^Message_Type_Info
	@(static) _sentinel: Message_Type_Info

	if _cached == nil {
		ptr, ok := get_type_info_ptr(T, loc)
		if !ok {
			register_message_type(T, loc)
			ptr, _ = get_type_info_ptr(T, loc)
			if ptr == nil {
				log.warnf(
					"message type %v is not registered and registering it now failed, most likely a type name hash collision or a full message registry (cap %d)",
					typeid_of(T),
					MAX_MESSAGE_TYPES,
					location = loc,
				)
				_cached = &_sentinel
				return _cached
			}
			log.warnf(
				"message type %s was registered lazily on first use, register your types ahead of time with register_message_type in an @(init) proc",
				ptr.name,
				location = loc,
			)
		}
		_cached = ptr
	}
	return _cached
}

get_type_name :: proc(ti: ^runtime.Type_Info, allocator := context.allocator) -> string {
	if ti == nil do return ""

	base := runtime.type_info_base(ti)

	#partial switch info in base.variant {
	case runtime.Type_Info_Named:
		if info.pkg != "" && info.name != "" {
			return fmt.aprintf("%s.%s", info.pkg, info.name, allocator = allocator)
		} else if info.name != "" {
			return strings.clone(info.name, allocator)
		}
	}

	return fmt.aprintf("%v", ti.id, allocator = allocator)
}

check_type_safety :: proc(
	ti: ^runtime.Type_Info,
	path: string = "",
	info: ^Message_Type_Info = nil,
	base_offset: uintptr = 0,
	var_fields: ^[dynamic]Var_Field_Info = nil,
	allow_byte_slices: bool = false,
	union_fields: ^[dynamic]Temp_Union_Info = nil,
) -> (
	safe: bool,
	error_msg: string,
) {
	if ti == nil do return true, ""

	base := runtime.type_info_base(ti)

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	build_error :: proc(path: string, type_desc: string) -> string {
		sb: strings.Builder
		strings.builder_init(&sb, 0, 64, context.temp_allocator)
		strings.write_string(&sb, path)
		strings.write_string(&sb, " (")
		strings.write_string(&sb, type_desc)
		strings.write_string(&sb, ")")
		return strings.to_string(sb)
	}

	#partial switch v in base.variant {
	case runtime.Type_Info_Pointer:
		return false, build_error(path, "pointer")
	case runtime.Type_Info_Multi_Pointer:
		return false, build_error(path, "multi-pointer")
	case runtime.Type_Info_Slice:
		if v.elem.id == typeid_of(byte) && allow_byte_slices {
			if info != nil {
				info.flags |= {.Has_Var_Fields}
			}
			if var_fields != nil {
				append(var_fields, Var_Field_Info{offset = base_offset})
			}
			return true, ""
		}
		return false, build_error(path, "slice")
	case runtime.Type_Info_Dynamic_Array:
		return false, build_error(path, "dynamic array")
	case runtime.Type_Info_Map:
		// Allow maps for internal system messages Actor_Stats
		// Allocated on in globally allocator.
		if path == "stats.received_from" ||
		   path == "stats.sent_to" ||
		   path == "active_stats" ||
		   path == "terminated_stats" {
			return true, ""
		}
		return false, build_error(path, "map")
	case runtime.Type_Info_String:
		if info != nil {
			info.flags |= {.Has_Var_Fields}
		}
		if var_fields != nil {
			append(var_fields, Var_Field_Info{offset = base_offset})
		}
		return true, ""
	case runtime.Type_Info_Any:
		return false, build_error(path, "any type")
	case runtime.Type_Info_Procedure:
		return true, ""
	case runtime.Type_Info_Union:
		variant_temps := make([]Temp_Variant_Info, len(v.variants))
		any_has_variable_data := false

		for variant, i in v.variants {
			sb: strings.Builder
			strings.builder_init(&sb, 0, 64, context.temp_allocator)
			strings.write_string(&sb, path)
			strings.write_string(&sb, ".variant[")
			strings.write_int(&sb, i)
			strings.write_string(&sb, "]")
			variant_path := strings.to_string(sb)

			variant_safe, msg := check_type_safety(
				variant,
				variant_path,
				nil,
				base_offset,
				&variant_temps[i].var_fields,
				allow_byte_slices,
				nil,
			)
			if !variant_safe {
				for &vt in variant_temps {
					delete(vt.var_fields)
				}
				delete(variant_temps)
				return false, msg
			}

			if len(variant_temps[i].var_fields) > 0 {
				any_has_variable_data = true
			}
		}

		if any_has_variable_data {
			if info != nil {
				info.flags |= {.Has_Unions}
			}
			if union_fields != nil {
				tag_size := v.tag_type != nil ? v.tag_type.size : 1
				append(
					union_fields,
					Temp_Union_Info {
						tag_offset = base_offset + v.tag_offset,
						tag_size = tag_size,
						no_nil = v.no_nil,
						variants = variant_temps,
					},
				)
			} else {
				// No union_fields accumulator, clean up variant temps
				for &vt in variant_temps {
					delete(vt.var_fields)
				}
				delete(variant_temps)
			}
		} else {
			for &vt in variant_temps {
				delete(vt.var_fields)
			}
			delete(variant_temps)
		}
		return true, ""
	case runtime.Type_Info_Array:
		sb: strings.Builder
		strings.builder_init(&sb, 0, 64, context.temp_allocator)
		strings.write_string(&sb, path)
		strings.write_string(&sb, "[]")
		array_path := strings.to_string(sb)

		return check_type_safety(
			v.elem,
			array_path,
			info,
			base_offset,
			var_fields,
			allow_byte_slices,
			union_fields,
		)
	case runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			field_path: string
			if path == "" {
				field_path = string(v.names[i])
			} else {
				sb: strings.Builder
				strings.builder_init(&sb, 0, 64, context.temp_allocator)
				strings.write_string(&sb, path)
				strings.write_string(&sb, ".")
				strings.write_string(&sb, string(v.names[i]))
				field_path = strings.to_string(sb)
			}
			field_offset := base_offset + uintptr(v.offsets[i])
			field_safe, msg := check_type_safety(
				v.types[i],
				field_path,
				info,
				field_offset,
				var_fields,
				allow_byte_slices,
				union_fields,
			)
			if !field_safe do return false, msg
		}
		return true, ""
	case:
		return true, ""
	}
}
