package actod

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"

NETWORK_HEADER_SIZE :: 26
LARGE_MESSAGE_THRESHOLD :: 16 * 1024
MAX_MESSAGE_SIZE :: 1024 * 1024
WIRE_FORMAT_OVERHEAD :: 64
MAX_WIRE_BUFFER_SIZE :: 64 * 1024
WIRE_FORMAT_NAME_OVERHEAD :: 256

Network_Message_Flags :: bit_set[Network_Message_Flag;u16]

Network_Message_Flag :: enum u16 {
	POD_PAYLOAD     = 0,
	BY_NAME         = 1,
	CONTROL         = 2,
	LIFECYCLE_EVENT = 3,
	PRIORITY_HIGH   = 4,
	PRIORITY_LOW    = 5,
	BROADCAST       = 6,
}

Parsed_Network_Header :: struct {
	flags:       Network_Message_Flags,
	from_handle: Handle,
	to_handle:   Handle,
	type_hash:   u64,
	to_name:     string,
	payload:     []byte,
}

// Format: [flags:u16][type_hash:u64][from:Handle(8)][to:Handle(8)]
write_network_header :: proc(
	buffer: []byte,
	flags: Network_Message_Flags,
	type_hash: u64,
	from_handle: Handle,
	to_handle: Handle,
) {
	endian.put_u16(buffer[0:2], .Little, transmute(u16)flags)
	endian.put_u64(buffer[2:10], .Little, type_hash)
	(cast(^Handle)&buffer[10])^ = from_handle
	(cast(^Handle)&buffer[18])^ = to_handle
}

// Wire format: [flags:u16][type_hash:u64][from:Handle(8)][to:Handle(8)][to_name?][payload]
parse_network_header :: proc(raw_data: []byte) -> (header: Parsed_Network_Header, ok: bool) {
	if len(raw_data) < NETWORK_HEADER_SIZE {
		return {}, false
	}

	header.flags = transmute(Network_Message_Flags)endian.unchecked_get_u16le(raw_data[0:2])
	header.type_hash = endian.unchecked_get_u64le(raw_data[2:10])
	header.from_handle = (cast(^Handle)&raw_data[10])^
	header.to_handle = (cast(^Handle)&raw_data[18])^

	payload_start := NETWORK_HEADER_SIZE
	if .BY_NAME in header.flags {
		to_name_len := int(header.to_handle.idx)
		payload_start = NETWORK_HEADER_SIZE + to_name_len
		if len(raw_data) < payload_start {
			return {}, false
		}
		header.to_name = string(raw_data[NETWORK_HEADER_SIZE:payload_start])
	}

	header.payload = raw_data[payload_start:]
	return header, true
}

wire_format_exact_size :: proc(content: $T, name_len: int) -> u32 {
	info := get_validated_message_info(T)
	base := 4 + NETWORK_HEADER_SIZE + name_len + size_of(T)

	if info.flags == {} {
		return u32(base)
	}

	content_ref := content
	total_variable_size := 0

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(&content_ref) + field.offset)
			total_variable_size += len(str_ptr^)
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(&content_ref, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(&content_ref) + field.offset)
				total_variable_size += len(str_ptr^)
			}
			for field in variant.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(&content_ref) + field.offset)
				total_variable_size += len(slice_ptr^)
			}
		}
	}

	return u32(base + total_variable_size)
}

build_wire_format_into_buffer :: proc(
	buffer: []byte,
	content: $T,
	to_handle: Handle,
	from_handle: Handle,
	base_flags: Network_Message_Flags,
	to_name: string,
) -> u32 {
	info := get_validated_message_info(T)
	flags := base_flags | {.POD_PAYLOAD}

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
		message_size := NETWORK_HEADER_SIZE + int(to_name_len) + size_of(T)
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

		when size_of(T) > 0 {
			content_pod := content
			intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), &content_pod, size_of(T))
		}
		return u32(total_buffer_size)
	}

	content_copy := content
	total_variable_size := 0
	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
			total_variable_size += len(str_ptr^)
		}
	}

	if .Has_Unions in info.flags {
		for uf in info.union_fields {
			variant, ok := get_active_union_variant(&content_copy, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
				total_variable_size += len(str_ptr^)
			}
			for field in variant.byte_slice_fields {
				slice_ptr := cast(^[]byte)(uintptr(&content_copy) + field.offset)
				total_variable_size += len(slice_ptr^)
			}
		}
	}

	message_size := NETWORK_HEADER_SIZE + int(to_name_len) + size_of(T) + total_variable_size
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

	when size_of(T) > 0 {
		intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), &content_copy, size_of(T))
	}
	offset += size_of(T)

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
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
			variant, ok := get_active_union_variant(&content_copy, uf)
			if !ok do continue
			for field in variant.string_fields {
				str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
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
				slice_ptr := cast(^[]byte)(uintptr(&content_copy) + field.offset)
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

Recv_Frame_Error :: enum {
	None,
	Zero_Size,
	Too_Large,
}

// Parses [size:u32][body] frames, compacts remaining data. Returns new write position.
process_recv_frames :: proc(
	buffer: []byte,
	write_pos: u32,
	ctx: ^$T,
	process_msg: proc(ctx: ^T, msg_data: []byte),
) -> (
	new_write_pos: u32,
	err: Recv_Frame_Error,
) {
	read_pos: u32 = 0
	data := buffer[:write_pos]

	for read_pos + 4 <= write_pos {
		msg_size := endian.unchecked_get_u32le(data[read_pos:])

		if msg_size == 0 {
			return 0, .Zero_Size
		}
		if msg_size > MAX_MESSAGE_SIZE {
			return 0, .Too_Large
		}
		if read_pos + 4 + msg_size > write_pos {
			break
		}

		process_msg(ctx, data[read_pos + 4:read_pos + 4 + msg_size])
		read_pos += 4 + msg_size
	}

	remaining := write_pos - read_pos
	if remaining > 0 && read_pos > 0 {
		runtime.mem_copy(&buffer[0], &buffer[read_pos], int(remaining))
	}
	return remaining, .None
}

Ctrl_Writer :: struct {
	buf: []byte,
	pos: int,
}

Ctrl_Reader :: struct {
	data: []byte,
	pos:  int,
	ok:   bool,
}

ctrl_put_u8 :: #force_inline proc(w: ^Ctrl_Writer, v: u8) {
	w.buf[w.pos] = v
	w.pos += 1
}

ctrl_put_u16 :: #force_inline proc(w: ^Ctrl_Writer, v: u16) {
	endian.put_u16(w.buf[w.pos:], .Little, v)
	w.pos += 2
}

ctrl_put_u32 :: #force_inline proc(w: ^Ctrl_Writer, v: u32) {
	endian.put_u32(w.buf[w.pos:], .Little, v)
	w.pos += 4
}

ctrl_put_u64 :: #force_inline proc(w: ^Ctrl_Writer, v: u64) {
	endian.put_u64(w.buf[w.pos:], .Little, v)
	w.pos += 8
}

ctrl_put_bytes :: #force_inline proc(w: ^Ctrl_Writer, data: []byte) {
	copy(w.buf[w.pos:], data)
	w.pos += len(data)
}

ctrl_put_str :: #force_inline proc(w: ^Ctrl_Writer, s: string) {
	bytes := transmute([]byte)s
	endian.put_u16(w.buf[w.pos:], .Little, u16(len(bytes)))
	w.pos += 2
	copy(w.buf[w.pos:], bytes)
	w.pos += len(bytes)
}

ctrl_get_u8 :: #force_inline proc(r: ^Ctrl_Reader) -> u8 {
	if r.pos + 1 > len(r.data) {
		r.ok = false
		return 0
	}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

ctrl_get_u16 :: #force_inline proc(r: ^Ctrl_Reader) -> u16 {
	if r.pos + 2 > len(r.data) {
		r.ok = false
		return 0
	}
	v := endian.unchecked_get_u16le(r.data[r.pos:])
	r.pos += 2
	return v
}

ctrl_get_u32 :: #force_inline proc(r: ^Ctrl_Reader) -> u32 {
	if r.pos + 4 > len(r.data) {
		r.ok = false
		return 0
	}
	v := endian.unchecked_get_u32le(r.data[r.pos:])
	r.pos += 4
	return v
}

ctrl_get_u64 :: #force_inline proc(r: ^Ctrl_Reader) -> u64 {
	if r.pos + 8 > len(r.data) {
		r.ok = false
		return 0
	}
	v := endian.unchecked_get_u64le(r.data[r.pos:])
	r.pos += 8
	return v
}

ctrl_get_bytes :: #force_inline proc(r: ^Ctrl_Reader, n: int) -> []byte {
	if r.pos + n > len(r.data) {
		r.ok = false
		return nil
	}
	v := r.data[r.pos:r.pos + n]
	r.pos += n
	return v
}

ctrl_get_str :: #force_inline proc(r: ^Ctrl_Reader) -> string {
	if r.pos + 2 > len(r.data) {
		r.ok = false
		return ""
	}
	n := int(endian.unchecked_get_u16le(r.data[r.pos:]))
	r.pos += 2
	if r.pos + n > len(r.data) {
		r.ok = false
		return ""
	}
	v := string(r.data[r.pos:r.pos + n])
	r.pos += n
	return v
}

wrap_control_message :: proc(ctrl_data: []byte, allocator := context.allocator) -> []byte {
	buf := make([]byte, NETWORK_HEADER_SIZE + len(ctrl_data), allocator)
	write_network_header(buf, {.CONTROL}, 0, Handle{}, Handle{})
	copy(buf[NETWORK_HEADER_SIZE:], ctrl_data)
	return buf
}

frame_control_message :: proc(ctrl_data: []byte, buf: []byte) -> int {
	message_size := NETWORK_HEADER_SIZE + len(ctrl_data)
	total_size := 4 + message_size
	endian.put_u32(buf[0:4], .Little, u32(message_size))
	write_network_header(buf[4:], {.CONTROL}, 0, Handle{}, Handle{})
	copy(buf[4 + NETWORK_HEADER_SIZE:], ctrl_data)
	return total_size
}
