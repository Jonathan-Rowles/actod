package actod

import "base:intrinsics"
import "core:encoding/endian"
import "core:log"
import "core:time"

wire_format_exact_size_impl :: proc(data: rawptr, info: ^Message_Type_Info, name_len: int) -> u32 {
	base := 4 + NETWORK_HEADER_SIZE + name_len + info.size

	if info.flags == {} {
		return u32(base)
	}

	total_variable_size := 0

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(data) + field.offset)
			total_variable_size += len(str_ptr^)
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(data, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(data) + field.offset)
				total_variable_size += len(str_ptr^)
			}
			for field in variant.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(data) + field.offset)
				total_variable_size += len(slice_ptr^)
			}
		}
	}

	return u32(base + total_variable_size)
}

build_wire_format_into_buffer_impl :: proc(
	buffer: []byte,
	data: rawptr,
	info: ^Message_Type_Info,
	to_handle: Handle,
	from_handle: Handle,
	base_flags: Network_Message_Flags,
	to_name: string,
) -> u32 {
	flags := base_flags | {.POD_PAYLOAD}
	struct_size := info.size

	to_name_bytes: []byte
	to_name_len: u16 = 0
	actual_to_handle := to_handle
	if .BY_NAME in base_flags {
		to_name_bytes = transmute([]byte)to_name
		to_name_len = u16(len(to_name_bytes))
		actual_to_handle = Handle {
			idx = u32(to_name_len),
			gen = 0,
		}
	}

	if info.flags == {} {
		message_size := NETWORK_HEADER_SIZE + int(to_name_len) + struct_size
		total_buffer_size := 4 + message_size
		if total_buffer_size > len(buffer) {
			return 0
		}

		endian.put_u32(buffer[0:4], .Little, u32(message_size))
		write_network_header(buffer[4:], flags, info.type_hash, from_handle, actual_to_handle)

		offset := 4 + NETWORK_HEADER_SIZE
		if .BY_NAME in base_flags {
			copy(buffer[offset:], to_name_bytes)
			offset += int(to_name_len)
		}

		if struct_size > 0 {
			intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), data, struct_size)
		}
		return u32(total_buffer_size)
	}

	total_variable_size := 0
	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(data) + field.offset)
			total_variable_size += len(str_ptr^)
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(data, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(data) + field.offset)
				total_variable_size += len(str_ptr^)
			}
			for field in variant.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(data) + field.offset)
				total_variable_size += len(slice_ptr^)
			}
		}
	}

	message_size := NETWORK_HEADER_SIZE + int(to_name_len) + struct_size + total_variable_size
	total_buffer_size := 4 + message_size
	if total_buffer_size > len(buffer) {
		return 0
	}

	endian.put_u32(buffer[0:4], .Little, u32(message_size))
	write_network_header(buffer[4:], flags, info.type_hash, from_handle, actual_to_handle)

	offset := 4 + NETWORK_HEADER_SIZE
	if .BY_NAME in base_flags {
		copy(buffer[offset:], to_name_bytes)
		offset += int(to_name_len)
	}

	if struct_size > 0 {
		intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), data, struct_size)
	}
	offset += struct_size

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(data) + field.offset)
			if len(str_ptr^) > 0 {
				intrinsics.mem_copy_non_overlapping(
					rawptr(&buffer[offset]),
					raw_data(str_ptr^),
					len(str_ptr^),
				)
				offset += len(str_ptr^)
			}
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(data, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(data) + field.offset)
				if len(str_ptr^) > 0 {
					intrinsics.mem_copy_non_overlapping(
						rawptr(&buffer[offset]),
						raw_data(str_ptr^),
						len(str_ptr^),
					)
					offset += len(str_ptr^)
				}
			}
			for field in variant.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(data) + field.offset)
				if len(slice_ptr^) > 0 {
					intrinsics.mem_copy_non_overlapping(
						rawptr(&buffer[offset]),
						raw_data(slice_ptr^),
						len(slice_ptr^),
					)
					offset += len(slice_ptr^)
				}
			}
		}
	}

	return u32(total_buffer_size)
}

send_to_connection_ring_impl :: proc(
	ring: ^Connection_Ring,
	to: PID,
	data: rawptr,
	info: ^Message_Type_Info,
	base_flags: Network_Message_Flags,
) -> Send_Error {
	if ring == nil || ring.state != .Ready {
		return .NETWORK_ERROR
	}

	to_handle, _ := unpack_pid(to)
	from_handle, _ := unpack_pid(get_self_pid())

	exact_size := wire_format_exact_size_impl(data, info, 0)

	dst, sid, ok := batch_reserve(ring, exact_size)
	if !ok {
		return .NETWORK_RING_FULL
	}

	msg_len := build_wire_format_into_buffer_impl(
		dst,
		data,
		info,
		to_handle,
		from_handle,
		base_flags,
		"",
	)
	if msg_len == 0 {
		batch_abort(ring, sid, dst)
		return .NETWORK_ERROR
	}

	when ODIN_DEBUG {
		assert(msg_len == exact_size, "wire format size mismatch in send_to_connection_ring_impl")
	}

	batch_commit(ring, sid)
	return .OK
}

send_to_connection_ring_by_name_impl :: proc(
	ring: ^Connection_Ring,
	actor_name: string,
	data: rawptr,
	info: ^Message_Type_Info,
	base_flags: Network_Message_Flags,
) -> Send_Error {
	if ring == nil || ring.state != .Ready {
		return .NETWORK_ERROR
	}

	from_handle, _ := unpack_pid(get_self_pid())
	to_handle := Handle {
		idx = u32(len(actor_name)),
		gen = 0,
	}

	flags := base_flags | {.BY_NAME}

	exact_size := wire_format_exact_size_impl(data, info, len(actor_name))

	dst, sid, ok := batch_reserve(ring, exact_size)
	if !ok {
		return .NETWORK_RING_FULL
	}

	msg_len := build_wire_format_into_buffer_impl(
		dst,
		data,
		info,
		to_handle,
		from_handle,
		flags,
		actor_name,
	)
	if msg_len == 0 {
		batch_abort(ring, sid, dst)
		return .NETWORK_ERROR
	}

	when ODIN_DEBUG {
		assert(
			msg_len == exact_size,
			"wire format size mismatch in send_to_connection_ring_by_name_impl",
		)
	}

	batch_commit(ring, sid)
	return .OK
}

build_and_send_network_command_impl :: proc(
	conn_pid: PID,
	data: rawptr,
	info: ^Message_Type_Info,
	base_flags: Network_Message_Flags,
	to_handle: Handle,
	to_name: string,
) -> Send_Error {
	from_handle, _ := unpack_pid(get_self_pid())

	flags := base_flags | {.POD_PAYLOAD}
	struct_size := info.size

	to_name_bytes: []byte
	to_name_len: u16 = 0
	actual_to_handle := to_handle
	if .BY_NAME in base_flags {
		to_name_bytes = transmute([]byte)to_name
		to_name_len = u16(len(to_name_bytes))
		actual_to_handle = Handle {
			idx = u32(to_name_len),
			gen = 0,
		}
	}

	total_string_size := 0
	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(data) + field.offset)
			total_string_size += len(str_ptr^)
		}
	}
	payload_size := struct_size + total_string_size

	message_size := NETWORK_HEADER_SIZE + int(to_name_len) + payload_size
	total_buffer_size := 4 + message_size

	buffer := make([]byte, total_buffer_size)

	endian.put_u32(buffer[0:4], .Little, u32(message_size))
	write_network_header(buffer[4:], flags, info.type_hash, from_handle, actual_to_handle)

	offset := 4 + NETWORK_HEADER_SIZE

	if .BY_NAME in base_flags {
		copy(buffer[offset:], to_name_bytes)
		offset += int(to_name_len)
	}

	if struct_size > 0 {
		intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), data, struct_size)
		offset += struct_size
	}

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(data) + field.offset)
			if len(str_ptr^) > 0 {
				intrinsics.mem_copy_non_overlapping(
					rawptr(&buffer[offset]),
					raw_data(str_ptr^),
					len(str_ptr^),
				)
				offset += len(str_ptr^)
			}
		}
	}

	result := send_message(conn_pid, Raw_Network_Buffer{data = buffer})
	delete(buffer)
	return result
}

send_remote_impl :: proc(to: PID, data: rawptr, info: ^Message_Type_Info) -> Send_Error {
	_, node_id := unpack_pid(to)

	p_flags := priority_to_flags(
		current_actor_context != nil ? current_actor_context.send_priority : .NORMAL,
	)

	ring := get_connection_ring(node_id)
	if ring != nil && ring.state == .Ready {
		for retry in 0 ..< RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES {
			result := send_to_connection_ring_impl(ring, to, data, info, p_flags)
			if result == .OK {
				return .OK
			}
			if result != .NETWORK_RING_FULL {
				return result
			}
			if retry < RING_SEND_SPIN_RETRIES {
				intrinsics.cpu_relax()
			} else {
				time.sleep(1 * time.Microsecond)
			}
		}
	}

	conn_pid := get_or_create_connection(node_id)
	if conn_pid == 0 {
		return .NODE_DISCONNECTED
	}

	to_handle, _ := unpack_pid(to)
	return build_and_send_network_command_impl(conn_pid, data, info, p_flags, to_handle, "")
}

send_remote_by_name_impl :: proc(
	node_name: string,
	actor_name: string,
	data: rawptr,
	info: ^Message_Type_Info,
) -> Send_Error {
	node_id, ok := get_node_by_name(node_name)
	if !ok {
		log.errorf("Unknown node: %s", node_name)
		return .ACTOR_NOT_FOUND
	}

	p_flags := priority_to_flags(
		current_actor_context != nil ? current_actor_context.send_priority : .NORMAL,
	)

	ring := get_connection_ring(node_id)
	if ring != nil && ring.state == .Ready {
		for retry in 0 ..< RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES {
			result := send_to_connection_ring_by_name_impl(ring, actor_name, data, info, p_flags)
			if result == .OK {
				return .OK
			}
			if result != .NETWORK_RING_FULL {
				return result
			}
			if retry < RING_SEND_SPIN_RETRIES {
				intrinsics.cpu_relax()
			} else {
				time.sleep(1 * time.Microsecond)
			}
		}
	}

	conn_pid := get_or_create_connection(node_id)
	if conn_pid == 0 {
		return .NODE_DISCONNECTED
	}

	to_handle := Handle {
		idx = u32(len(actor_name)),
		gen = 0,
	}
	return build_and_send_network_command_impl(
		conn_pid,
		data,
		info,
		p_flags | {.BY_NAME},
		to_handle,
		actor_name,
	)
}
