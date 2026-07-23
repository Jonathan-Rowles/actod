package actod

import "base:intrinsics"
import "core:encoding/endian"
import "core:log"
import "core:mem"
import "core:sync"
import "core:time"

wire_format_exact_size_impl :: proc(data: rawptr, info: ^Message_Type_Info, name_len: int) -> u32 {
	base := 4 + NETWORK_HEADER_SIZE + name_len + info.size

	if info.flags == {} {
		return u32(base)
	}

	return u32(base + calculate_variable_data_size(data, info))
}

@(private)
append_variable_data :: proc(
	buffer: []byte,
	start_offset: int,
	data: rawptr,
	info: ^Message_Type_Info,
) -> int {
	offset := start_offset

	if .Has_Var_Fields in info.flags {
		for field in info.var_fields {
			f := cast(^mem.Raw_Slice)(uintptr(data) + field.offset)
			if f.len > 0 {
				intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), f.data, f.len)
				offset += f.len
			}
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(data, uf)
			if !ok do continue
			for field in variant.var_fields {
				f := cast(^mem.Raw_Slice)(uintptr(data) + field.offset)
				if f.len > 0 {
					intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), f.data, f.len)
					offset += f.len
				}
			}
		}
	}

	return offset
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

	total_variable_size := calculate_variable_data_size(data, info)

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

	_ = append_variable_data(buffer, offset, data, info)

	return u32(total_buffer_size)
}

send_to_connection_ring_impl :: proc(
	ring: ^Connection_Ring,
	to: PID,
	data: rawptr,
	info: ^Message_Type_Info,
	base_flags: Network_Message_Flags,
	loc := #caller_location,
) -> Send_Error {
	if ring == nil {
		log.errorf(
			"Cannot send '%s' to %v: there is no connection ring for that node",
			info.name,
			to,
			location = loc,
		)
		return .NETWORK_ERROR
	}

	to_handle, _ := unpack_pid(to)
	from_handle, _ := unpack_pid(get_self_pid())

	exact_size := wire_format_exact_size_impl(data, info, 0)
	if exact_size > ring.usable_slot_size {
		log.errorf(
			"Message '%s' is %d bytes on the wire but the connection ring slot holds %d; raise connection_ring.send_slot_size in make_network_config or split the message",
			info.name,
			exact_size,
			ring.usable_slot_size,
			location = loc,
		)
		return .MESSAGE_TOO_LARGE
	}

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
		log.errorf(
			"Failed to serialize '%s' (%d bytes) for node %d; the message type may contain a field the wire format cannot encode",
			info.name,
			exact_size,
			ring.node_id,
			location = loc,
		)
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
	loc := #caller_location,
) -> Send_Error {
	if ring == nil {
		log.errorf(
			"Cannot send '%s' to '%s': there is no connection ring for that node",
			info.name,
			actor_name,
			location = loc,
		)
		return .NETWORK_ERROR
	}

	from_handle, _ := unpack_pid(get_self_pid())
	to_handle := Handle {
		idx = u32(len(actor_name)),
		gen = 0,
	}

	flags := base_flags | {.BY_NAME}

	exact_size := wire_format_exact_size_impl(data, info, len(actor_name))
	if exact_size > ring.usable_slot_size {
		log.errorf(
			"Message '%s' addressed to '%s' is %d bytes on the wire but the connection ring slot holds %d; raise connection_ring.send_slot_size in make_network_config or split the message",
			info.name,
			actor_name,
			exact_size,
			ring.usable_slot_size,
			location = loc,
		)
		return .MESSAGE_TOO_LARGE
	}

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
		log.errorf(
			"Failed to serialize '%s' (%d bytes) addressed to '%s'; the message type may contain a field the wire format cannot encode",
			info.name,
			exact_size,
			actor_name,
			location = loc,
		)
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

// The ring buffers while disconnected; ensure a connection actor exists to
// drain it whenever the fast path finds the ring absent or not yet Ready.
@(private)
ensure_ring_for_node :: proc(node_id: Node_ID) -> ^Connection_Ring {
	ring := get_connection_ring(node_id)
	if ring != nil && sync.atomic_load(&ring.state) == .Ready {
		return ring
	}
	if get_or_create_connection(node_id) == 0 {
		return nil
	}
	return get_connection_ring(node_id)
}

send_remote_impl :: proc(
	to: PID,
	data: rawptr,
	info: ^Message_Type_Info,
	priority: Message_Priority,
	base_flags: Network_Message_Flags = {},
	loc := #caller_location,
) -> Send_Error {
	_, node_id := unpack_pid(to)

	ring := ensure_ring_for_node(node_id)
	if ring == nil {
		log.warnf(
			"Dropping '%s' for %v: no connection to node %d could be established; register the node with register_node and check it is reachable",
			info.name,
			to,
			node_id,
			location = loc,
		)
		return .NODE_DISCONNECTED
	}

	p_flags := priority_to_flags(priority) | base_flags
	for retry in 0 ..< RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES {
		result := send_to_connection_ring_impl(ring, to, data, info, p_flags, loc)
		if result != .NETWORK_RING_FULL {
			return result
		}
		if retry < RING_SEND_SPIN_RETRIES {
			intrinsics.cpu_relax()
		} else {
			time.sleep(1 * time.Microsecond)
		}
	}
	log.warnf(
		"Dropping '%s' for %v: the send ring for node %d stayed full for %d retries; the peer is not draining fast enough, raise connection_ring.send_slot_count or slow the producer",
		info.name,
		to,
		node_id,
		RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES,
		location = loc,
	)
	return .NETWORK_RING_FULL
}

send_remote_by_name_impl :: proc(
	node_name: string,
	actor_name: string,
	data: rawptr,
	info: ^Message_Type_Info,
	loc := #caller_location,
) -> Send_Error {
	node_id, ok := get_node_by_name(node_name)
	if !ok {
		log.errorf(
			"Cannot send '%s' to '%s@%s': that node is not known; check the spelling and register it with register_node before sending",
			info.name,
			actor_name,
			node_name,
			location = loc,
		)
		return .ACTOR_NOT_FOUND
	}

	ring := ensure_ring_for_node(node_id)
	if ring == nil {
		log.warnf(
			"Dropping '%s' for '%s@%s': no connection to that node could be established; check it is running and reachable",
			info.name,
			actor_name,
			node_name,
			location = loc,
		)
		return .NODE_DISCONNECTED
	}

	p_flags := priority_to_flags(.NORMAL)
	for retry in 0 ..< RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES {
		result := send_to_connection_ring_by_name_impl(ring, actor_name, data, info, p_flags, loc)
		if result != .NETWORK_RING_FULL {
			return result
		}
		if retry < RING_SEND_SPIN_RETRIES {
			intrinsics.cpu_relax()
		} else {
			time.sleep(1 * time.Microsecond)
		}
	}
	log.warnf(
		"Dropping '%s' for '%s@%s': the send ring stayed full for %d retries; the peer is not draining fast enough, raise connection_ring.send_slot_count or slow the producer",
		info.name,
		actor_name,
		node_name,
		RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES,
		location = loc,
	)
	return .NETWORK_RING_FULL
}

send_unreliable :: #force_inline proc(
	to: PID,
	content: $T,
	loc := #caller_location,
) -> Send_Error {
	if is_local_pid(to) {
		return send_message(to, content)
	}
	v := content
	return send_unreliable_remote_impl(to, &v, get_validated_message_info_ptr(T), loc)
}

send_unreliable_remote_impl :: proc(
	to: PID,
	data: rawptr,
	info: ^Message_Type_Info,
	loc := #caller_location,
) -> Send_Error {
	_, node_id := unpack_pid(to)

	max_frame := udp_max_frame_bytes()
	if max_frame > 0 {
		exact_size := wire_format_exact_size_impl(data, info, 0)
		if int(exact_size) <= max_frame {
			to_handle, _ := unpack_pid(to)
			from_handle, _ := unpack_pid(get_self_pid())

			buf: [UDP_FRAME_BUFFER]byte
			msg_len := build_wire_format_into_buffer_impl(
				buf[:exact_size],
				data,
				info,
				to_handle,
				from_handle,
				priority_to_flags(.NORMAL),
				"",
			)
			if msg_len != 0 && udp_try_send(node_id, buf[:msg_len]) {
				return .OK
			}
		}
	}

	return send_remote_impl(to, data, info, .NORMAL, {}, loc)
}
