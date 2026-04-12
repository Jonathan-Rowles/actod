package actod

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"

String_Field_Info :: struct {
	offset: uintptr,
}

Byte_Slice_Field_Info :: struct {
	offset: uintptr,
}

Union_Variant_Fields :: struct {
	string_fields:     []String_Field_Info,
	byte_slice_fields: []Byte_Slice_Field_Info,
}

Union_Field_Info :: struct {
	tag_offset: uintptr,
	tag_size:   int,
	no_nil:     bool,
	variants:   []Union_Variant_Fields,
}

Message_Type_Flags :: enum u32 {
	Has_Strings     = 0,
	Has_Byte_Slices = 1,
	Has_Unions      = 2,
}

Message_Type_Flags_Set :: bit_set[Message_Type_Flags;u32]

Message_Deliver_Proc :: proc(to_pid: PID, from_pid: PID, payload: []byte) -> Send_Error

Message_Type_Info :: struct {
	type_id:           typeid,
	name:              string,
	type_hash:         u64,
	size:              int,
	wire_header_size:  int,
	type_info:         ^runtime.Type_Info,
	flags:             Message_Type_Flags_Set,
	string_fields:     []String_Field_Info,
	byte_slice_fields: []Byte_Slice_Field_Info,
	union_fields:      []Union_Field_Info,
	deliver:           Message_Deliver_Proc,
}

MAX_MESSAGE_TYPES :: 256

@(private)
g_message_registry: Name_Registry(Message_Type_Info, MAX_MESSAGE_TYPES)

@(fini)
cleanup_message_registry :: proc "contextless" () {
	context = runtime.default_context()
	registry_destroy(&g_message_registry)
}

get_type_info :: proc(id: typeid) -> (Message_Type_Info, bool) {
	registry_ensure_init(&g_message_registry)

	for i in 0 ..< g_message_registry.count {
		if g_message_registry.entries[i].value.type_id == id {
			return g_message_registry.entries[i].value, true
		}
	}

	log.infof("id not found %s", id)
	return {}, false
}

get_type_info_by_hash :: #force_inline proc(type_hash: u64) -> (Message_Type_Info, bool) {
	val, found := registry_get_by_hash(&g_message_registry, type_hash)
	if found {
		return val^, true
	}
	return {}, false
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
	string_fields:     [dynamic]String_Field_Info,
	byte_slice_fields: [dynamic]Byte_Slice_Field_Info,
}

register_message_type :: proc "contextless" ($T: typeid) {
	context = runtime.default_context()
	registry_ensure_init(&g_message_registry)

	// Fast path: already registered?
	for i in 0 ..< g_message_registry.count {
		if g_message_registry.entries[i].value.type_id == T {
			return
		}
	}

	ti := type_info_of(T)

	type_name := get_type_name(ti, allocator = g_message_registry.allocator)
	if type_name == "" {
		panic("could not find type name")
	}

	allow_byte_slices := true

	temp_string_fields := make([dynamic]String_Field_Info)
	temp_byte_slice_fields := make([dynamic]Byte_Slice_Field_Info)
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
		&temp_string_fields,
		&temp_byte_slice_fields,
		allow_byte_slices,
		&temp_union_fields,
	)
	if !safe {
		delete(temp_string_fields)
		delete(temp_byte_slice_fields)
		cleanup_temp_union_fields(temp_union_fields[:])
		delete(temp_union_fields)
		log.panicf(
			"\n\nACTOR SAFETY ERROR: Message type '%v' contains unsafe field!\n" +
			"  Unsafe field: %s\n" +
			"  Use fixed-size arrays [N]T instead of slices []T.\n" +
			"  Remove pointers, maps, and dynamic arrays from message types.\n\n",
			typeid_of(T),
			unsafe_field,
		)
	}

	if len(temp_string_fields) > 0 {
		info.string_fields = make(
			[]String_Field_Info,
			len(temp_string_fields),
			g_message_registry.allocator,
		)
		copy(info.string_fields, temp_string_fields[:])
	}

	if len(temp_byte_slice_fields) > 0 {
		info.byte_slice_fields = make(
			[]Byte_Slice_Field_Info,
			len(temp_byte_slice_fields),
			g_message_registry.allocator,
		)
		copy(info.byte_slice_fields, temp_byte_slice_fields[:])
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
				if len(vf.string_fields) > 0 {
					info.union_fields[ui].variants[vi].string_fields = make(
						[]String_Field_Info,
						len(vf.string_fields),
						g_message_registry.allocator,
					)
					copy(info.union_fields[ui].variants[vi].string_fields, vf.string_fields[:])
				}
				if len(vf.byte_slice_fields) > 0 {
					info.union_fields[ui].variants[vi].byte_slice_fields = make(
						[]Byte_Slice_Field_Info,
						len(vf.byte_slice_fields),
						g_message_registry.allocator,
					)
					copy(
						info.union_fields[ui].variants[vi].byte_slice_fields,
						vf.byte_slice_fields[:],
					)
				}
			}
		}
	}

	// Payload format: [struct bytes][string1 data][string2 data]...[bytes1 data][bytes2 data]...
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

		type_info := get_validated_message_info(T)
		data_offset := size_of(T)
		payload_len := len(payload)

		if .Has_Strings in type_info.flags {
			for field in type_info.string_fields {
				str_ptr := cast(^string)(uintptr(&value) + field.offset)
				str_len := len(str_ptr^)
				if str_len > 0 {
					if data_offset + str_len > payload_len {
						log.errorf(
							"Payload too small for string field in %v: need %d, have %d",
							typeid_of(T),
							data_offset + str_len,
							payload_len,
						)
						return .NETWORK_ERROR
					}
					str_ptr^ = string(payload[data_offset:data_offset + str_len])
					data_offset += str_len
				}
			}
		}

		if .Has_Byte_Slices in type_info.flags {
			for field in type_info.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(&value) + field.offset)
				slice_len := len(slice_ptr^)
				if slice_len > 0 {
					if data_offset + slice_len > payload_len {
						log.errorf(
							"Payload too small for byte slice field in %v: need %d, have %d",
							typeid_of(T),
							data_offset + slice_len,
							payload_len,
						)
						return .NETWORK_ERROR
					}
					slice_ptr^ = payload[data_offset:data_offset + slice_len]
					data_offset += slice_len
				}
			}
		}

		if .Has_Unions in type_info.flags {
			for uf in type_info.union_fields {
				variant, ok := get_active_union_variant(&value, uf)
				if !ok do continue
				for field in variant.string_fields {
					str_ptr := cast(^string)(uintptr(&value) + field.offset)
					str_len := len(str_ptr^)
					if str_len > 0 {
						if data_offset + str_len > payload_len {
							log.errorf(
								"Payload too small for union string field in %v: need %d, have %d",
								typeid_of(T),
								data_offset + str_len,
								payload_len,
							)
							return .NETWORK_ERROR
						}
						str_ptr^ = string(payload[data_offset:data_offset + str_len])
						data_offset += str_len
					}
				}
				for field in variant.byte_slice_fields {
					slice_ptr := cast(^[]byte)(uintptr(&value) + field.offset)
					slice_len := len(slice_ptr^)
					if slice_len > 0 {
						if data_offset + slice_len > payload_len {
							log.errorf(
								"Payload too small for union byte slice field in %v: need %d, have %d",
								typeid_of(T),
								data_offset + slice_len,
								payload_len,
							)
							return .NETWORK_ERROR
						}
						slice_ptr^ = payload[data_offset:data_offset + slice_len]
						data_offset += slice_len
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
		existing, found := get_type_info_by_hash(type_hash)
		if found && existing.type_id != T {
			log.panicf(
				"FATAL: Message type hash collision! '%v' and '%v' both hash to %x",
				existing.type_id,
				typeid_of(T),
				type_hash,
			)
		}
	}

	registry_register(&g_message_registry, type_name, info)

	delete(temp_string_fields)
	delete(temp_byte_slice_fields)
	cleanup_temp_union_fields(temp_union_fields[:])
	delete(temp_union_fields)
}

cleanup_temp_union_fields :: proc(fields: []Temp_Union_Info) {
	for &uf in fields {
		for &vf in uf.variants {
			delete(vf.string_fields)
			delete(vf.byte_slice_fields)
		}
		delete(uf.variants)
	}
}

get_validated_message_info :: #force_inline proc($T: typeid) -> Message_Type_Info {
	@(static) _validated := false
	@(static) _cached_info: Message_Type_Info

	if !_validated {
		info, ok := get_type_info(T)
		if !ok {
			register_message_type(T)
			info, _ = get_type_info(T)
			log.warnf("use @(init) and register you types ahead of time: %s", info.name)
		}
		_cached_info = info
		_validated = true
	}
	return _cached_info
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
	string_fields: ^[dynamic]String_Field_Info = nil,
	byte_slice_fields: ^[dynamic]Byte_Slice_Field_Info = nil,
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
				info.flags |= {.Has_Byte_Slices}
			}
			if byte_slice_fields != nil {
				append(byte_slice_fields, Byte_Slice_Field_Info{offset = base_offset})
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
			info.flags |= {.Has_Strings}
		}
		if string_fields != nil {
			append(string_fields, String_Field_Info{offset = base_offset})
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
				&variant_temps[i].string_fields,
				&variant_temps[i].byte_slice_fields,
				allow_byte_slices,
				nil,
			)
			if !variant_safe {
				for &vt in variant_temps {
					delete(vt.string_fields)
					delete(vt.byte_slice_fields)
				}
				delete(variant_temps)
				return false, msg
			}

			if len(variant_temps[i].string_fields) > 0 ||
			   len(variant_temps[i].byte_slice_fields) > 0 {
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
				// No union_fields accumulator — clean up variant temps
				for &vt in variant_temps {
					delete(vt.string_fields)
					delete(vt.byte_slice_fields)
				}
				delete(variant_temps)
			}
		} else {
			for &vt in variant_temps {
				delete(vt.string_fields)
				delete(vt.byte_slice_fields)
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
			string_fields,
			byte_slice_fields,
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
				string_fields,
				byte_slice_fields,
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
