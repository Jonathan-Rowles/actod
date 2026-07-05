package actod

import "base:intrinsics"
import "core:encoding/endian"
import "core:testing"

@(test)
test_parse_network_header :: proc(t: ^testing.T) {
	// [flags:u16][type_hash:u64][from:Handle(8)][to:Handle(8)][to_name?][payload]
	type_name := "test.Message"
	type_hash := fnv1a_hash(type_name)
	payload := []byte{1, 2, 3, 4}

	from_handle := Handle {
		idx = 10,
		gen = 20,
	}
	to_handle := Handle {
		idx = 30,
		gen = 40,
	}

	header_size := 2 + 8 + 8 + 8
	total_size := header_size + len(payload)

	buffer := make([]byte, total_size)
	defer delete(buffer)

	flags := Network_Message_Flags{.POD_PAYLOAD}
	endian.put_u16(buffer[0:2], .Little, transmute(u16)flags)
	endian.put_u64(buffer[2:10], .Little, type_hash)
	(cast(^Handle)&buffer[10])^ = from_handle
	(cast(^Handle)&buffer[18])^ = to_handle
	copy(buffer[26:], payload)

	header, ok := parse_network_header(buffer)
	testing.expect(t, ok, "Should parse header successfully")
	testing.expect(t, .POD_PAYLOAD in header.flags, "POD_PAYLOAD flag should be set")
	testing.expect(t, .BY_NAME not_in header.flags, "BY_NAME flag should not be set")
	testing.expect(t, header.from_handle == from_handle, "From handle mismatch")
	testing.expect(t, header.to_handle == to_handle, "To handle mismatch")
	testing.expect(t, header.type_hash == type_hash, "Type hash mismatch")
	testing.expect(t, len(header.payload) == len(payload), "Payload length mismatch")
	testing.expect(t, header.to_name == "", "To name should be empty")
}

@(test)
test_parse_network_header_with_name :: proc(t: ^testing.T) {
	type_name := "test.Message"
	type_hash := fnv1a_hash(type_name)
	actor_name := "my_actor"
	actor_name_bytes := transmute([]byte)actor_name
	payload := []byte{5, 6, 7, 8}

	from_handle := Handle {
		idx = 1,
		gen = 2,
	}
	to_handle := Handle {
		idx = u32(len(actor_name)),
		gen = 0,
	}

	header_size := 2 + 8 + 8 + 8
	total_size := header_size + len(actor_name_bytes) + len(payload)

	buffer := make([]byte, total_size)
	defer delete(buffer)

	flags := Network_Message_Flags{.POD_PAYLOAD, .BY_NAME}
	endian.put_u16(buffer[0:2], .Little, transmute(u16)flags)
	endian.put_u64(buffer[2:10], .Little, type_hash)
	(cast(^Handle)&buffer[10])^ = from_handle
	(cast(^Handle)&buffer[18])^ = to_handle

	offset := 26
	copy(buffer[offset:], actor_name_bytes)
	offset += len(actor_name_bytes)
	copy(buffer[offset:], payload)

	header, ok := parse_network_header(buffer)
	testing.expect(t, ok, "Should parse header successfully")
	testing.expect(t, .BY_NAME in header.flags, "BY_NAME flag should be set")
	testing.expect(t, header.type_hash == type_hash, "Type hash mismatch")
	testing.expect(t, header.to_name == actor_name, "Actor name mismatch")
	testing.expect(t, len(header.payload) == len(payload), "Payload length mismatch")
}

@(test)
test_parse_network_header_control_message :: proc(t: ^testing.T) {
	ctrl_payload := []byte{CTRL_MSG_HELLO, 0, 1, 0, 4, 't', 'e', 's', 't'}

	header_size := 2 + 8 + 8 + 8
	total_size := header_size + len(ctrl_payload)

	buffer := make([]byte, total_size)
	defer delete(buffer)

	flags := Network_Message_Flags{.CONTROL}
	endian.put_u16(buffer[0:2], .Little, transmute(u16)flags)
	endian.put_u64(buffer[2:10], .Little, 0)
	(cast(^Handle)&buffer[10])^ = Handle{}
	(cast(^Handle)&buffer[18])^ = Handle{}
	copy(buffer[26:], ctrl_payload)

	header, ok := parse_network_header(buffer)
	testing.expect(t, ok, "Should parse control message header")
	testing.expect(t, .CONTROL in header.flags, "CONTROL flag should be set")
	testing.expect(t, header.type_hash == 0, "Type hash should be 0 for control")
	testing.expect(t, len(header.payload) == len(ctrl_payload), "Control payload length mismatch")
}

@(test)
test_parse_network_header_invalid :: proc(t: ^testing.T) {
	small_buffer := make([]byte, 10)
	defer delete(small_buffer)

	_, ok := parse_network_header(small_buffer)
	testing.expect(t, !ok, "Should fail with buffer too small")

	truncated := make([]byte, 20)
	defer delete(truncated)
	endian.put_u16(truncated[2:4], .Little, 100)

	_, ok2 := parse_network_header(truncated)
	testing.expect(t, !ok2, "Should fail with truncated type_name")
}

@(test)
test_control_message_handshake_format :: proc(t: ^testing.T) {
	node_name := "TestNode"
	version: u32 = WIRE_PROTOCOL_VERSION
	flags: u8 = HELLO_FLAG_ENCRYPTED | HELLO_FLAG_POOL_JOIN
	listen_port: u16 = 4242
	udp_port: u16 = 4243
	nonce: u64 = 0x123456789ABCDEF0
	join_token: u64 = 0x0FEDCBA987654321

	payload := make([]byte, 1 + 4 + 1 + 2 + 2 + (2 + len(node_name)) + 8 + 8)
	defer delete(payload)

	w := Ctrl_Writer {
		buf = payload,
	}
	ctrl_put_u8(&w, CTRL_MSG_HELLO)
	ctrl_put_u32(&w, version)
	ctrl_put_u8(&w, flags)
	ctrl_put_u16(&w, listen_port)
	ctrl_put_u16(&w, udp_port)
	ctrl_put_str(&w, node_name)
	ctrl_put_u64(&w, nonce)
	ctrl_put_u64(&w, join_token)

	info, ok := parse_hello(payload[:w.pos])
	testing.expect(t, ok, "parse_hello should succeed")
	testing.expect(t, info.version == version, "Version mismatch")
	testing.expect(t, info.node_name == node_name, "Node name mismatch")
	testing.expect(t, info.listen_port == listen_port, "Listen port mismatch")
	testing.expect(t, info.udp_port == udp_port, "UDP port mismatch")
	testing.expect(t, info.nonce == nonce, "Nonce mismatch")
	testing.expect(t, info.join_token == join_token, "Join token mismatch")
	testing.expect(t, info.encrypted, "Encrypted flag mismatch")
	testing.expect(t, info.pool_join, "Pool-join flag mismatch")
}

@(test)
test_control_message_heartbeat_format :: proc(t: ^testing.T) {
	// [type:u8][timestamp:i64][seq_num:u64]
	timestamp: u64 = 0xFEDCBA9876543210
	seq_num: u64 = 12345

	payload := make([]byte, 1 + 8 + 8)
	defer delete(payload)

	payload[0] = CTRL_MSG_HEARTBEAT
	endian.put_u64(payload[1:], .Little, timestamp)
	endian.put_u64(payload[9:], .Little, seq_num)

	testing.expect(t, payload[0] == CTRL_MSG_HEARTBEAT, "Message type should be heartbeat")

	parsed_timestamp := endian.unchecked_get_u64le(payload[1:])
	testing.expect(t, parsed_timestamp == timestamp, "Timestamp mismatch")

	parsed_seq_num := endian.unchecked_get_u64le(payload[9:])
	testing.expect(t, parsed_seq_num == seq_num, "Sequence number mismatch")
}

@(test)
test_network_message_flags :: proc(t: ^testing.T) {
	{
		flags := Network_Message_Flags{.POD_PAYLOAD}
		raw := transmute(u16)flags
		back := transmute(Network_Message_Flags)raw
		testing.expect(t, .POD_PAYLOAD in back, "POD_PAYLOAD should survive transmute")
		testing.expect(t, .BY_NAME not_in back, "BY_NAME should not be set")
		testing.expect(t, .CONTROL not_in back, "CONTROL should not be set")
	}

	{
		flags := Network_Message_Flags{.POD_PAYLOAD, .BY_NAME}
		raw := transmute(u16)flags
		back := transmute(Network_Message_Flags)raw
		testing.expect(t, .POD_PAYLOAD in back, "POD_PAYLOAD should be set")
		testing.expect(t, .BY_NAME in back, "BY_NAME should be set")
	}

	{
		flags := Network_Message_Flags{.CONTROL}
		raw := transmute(u16)flags
		back := transmute(Network_Message_Flags)raw
		testing.expect(t, .CONTROL in back, "CONTROL should be set")
		testing.expect(t, .POD_PAYLOAD not_in back, "POD_PAYLOAD should not be set")
	}

	{
		flags := Network_Message_Flags{.LIFECYCLE_EVENT}
		raw := transmute(u16)flags
		back := transmute(Network_Message_Flags)raw
		testing.expect(t, .LIFECYCLE_EVENT in back, "LIFECYCLE_EVENT should be set")
		testing.expect(t, .CONTROL not_in back, "CONTROL should not be set")
		testing.expect(t, .POD_PAYLOAD not_in back, "POD_PAYLOAD should not be set")
	}

	{
		flags := Network_Message_Flags{.LIFECYCLE_EVENT, .POD_PAYLOAD}
		raw := transmute(u16)flags
		back := transmute(Network_Message_Flags)raw
		testing.expect(t, .LIFECYCLE_EVENT in back, "LIFECYCLE_EVENT should be set with POD")
		testing.expect(t, .POD_PAYLOAD in back, "POD_PAYLOAD should be set with LIFECYCLE_EVENT")
	}
}

@(test)
test_lifecycle_event_header_roundtrip :: proc(t: ^testing.T) {
	spawned_info := get_validated_message_info_ptr(Actor_Spawned_Broadcast)

	from_handle := Handle {
		idx = 5,
		gen = 1,
	}
	flags := Network_Message_Flags{.LIFECYCLE_EVENT, .POD_PAYLOAD}

	buffer := make([]byte, NETWORK_HEADER_SIZE + 64)
	defer delete(buffer)

	write_network_header(buffer, flags, spawned_info.type_hash, from_handle, Handle{})

	header, ok := parse_network_header(buffer)
	testing.expect(t, ok, "Should parse lifecycle event header")
	testing.expect(
		t,
		.LIFECYCLE_EVENT in header.flags,
		"LIFECYCLE_EVENT flag should survive roundtrip",
	)
	testing.expect(
		t,
		header.type_hash == spawned_info.type_hash,
		"Type hash should match Actor_Spawned_Broadcast",
	)
}

@(test)
test_spawned_broadcast_wire_format_roundtrip :: proc(t: ^testing.T) {
	test_pid := pack_pid(Handle{idx = 10, gen = 2, actor_type = Actor_Type(3)}, 5)
	parent_pid := pack_pid(Handle{idx = 1, gen = 1}, 5)

	original := Actor_Spawned_Broadcast {
		pid              = test_pid,
		name             = "test_actor",
		actor_type       = Actor_Type(3),
		parent_pid       = parent_pid,
		ttl              = DEFAULT_BROADCAST_TTL,
		source_node_name = "node_A",
		source_port      = 9001,
		source_ip        = 0x7F000001, // 127.0.0.1
	}

	buf: [512]byte
	msg_len := build_wire_format_into_buffer(
		buf[:],
		original,
		Handle{},
		Handle{},
		{.LIFECYCLE_EVENT},
		"",
	)
	testing.expect(t, msg_len > 0, "Should build wire format successfully")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")
	testing.expect(t, .LIFECYCLE_EVENT in header.flags, "LIFECYCLE_EVENT flag should be set")

	payload := header.payload
	testing.expect(
		t,
		len(payload) >= size_of(Actor_Spawned_Broadcast),
		"Payload should be large enough",
	)

	deserialized: Actor_Spawned_Broadcast
	intrinsics.mem_copy_non_overlapping(
		&deserialized,
		raw_data(payload),
		size_of(Actor_Spawned_Broadcast),
	)

	str_offset := size_of(Actor_Spawned_Broadcast)

	name_len := len(deserialized.name)
	if name_len > 0 {
		deserialized.name = string(payload[str_offset:str_offset + name_len])
		str_offset += name_len
	}

	source_name_len := len(deserialized.source_node_name)
	if source_name_len > 0 {
		deserialized.source_node_name = string(payload[str_offset:str_offset + source_name_len])
	}

	testing.expect(t, deserialized.pid == original.pid, "PID should match")
	testing.expect(t, deserialized.name == original.name, "Name should match")
	testing.expect(t, deserialized.actor_type == original.actor_type, "Actor type should match")
	testing.expect(t, deserialized.parent_pid == original.parent_pid, "Parent PID should match")
	testing.expect(t, deserialized.ttl == original.ttl, "TTL should match")
	testing.expect(
		t,
		deserialized.source_node_name == original.source_node_name,
		"Source node name should match",
	)
	testing.expect(t, deserialized.source_port == original.source_port, "Source port should match")
	testing.expect(t, deserialized.source_ip == original.source_ip, "Source IP should match")
}

@(test)
test_terminated_broadcast_wire_format_roundtrip :: proc(t: ^testing.T) {
	test_pid := pack_pid(Handle{idx = 20, gen = 3, actor_type = Actor_Type(1)}, 7)

	original := Actor_Terminated_Broadcast {
		pid              = test_pid,
		name             = "dying_actor",
		reason           = .ABNORMAL,
		ttl              = 2,
		source_node_name = "node_B",
	}

	buf: [512]byte
	msg_len := build_wire_format_into_buffer(
		buf[:],
		original,
		Handle{},
		Handle{},
		{.LIFECYCLE_EVENT},
		"",
	)
	testing.expect(t, msg_len > 0, "Should build wire format successfully")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")
	testing.expect(t, .LIFECYCLE_EVENT in header.flags, "LIFECYCLE_EVENT flag should be set")

	payload := header.payload
	testing.expect(
		t,
		len(payload) >= size_of(Actor_Terminated_Broadcast),
		"Payload should be large enough",
	)

	deserialized: Actor_Terminated_Broadcast
	intrinsics.mem_copy_non_overlapping(
		&deserialized,
		raw_data(payload),
		size_of(Actor_Terminated_Broadcast),
	)

	str_offset := size_of(Actor_Terminated_Broadcast)

	name_len := len(deserialized.name)
	if name_len > 0 {
		deserialized.name = string(payload[str_offset:str_offset + name_len])
		str_offset += name_len
	}

	source_name_len := len(deserialized.source_node_name)
	if source_name_len > 0 {
		deserialized.source_node_name = string(payload[str_offset:str_offset + source_name_len])
	}

	testing.expect(t, deserialized.pid == original.pid, "PID should match")
	testing.expect(t, deserialized.name == original.name, "Name should match")
	testing.expect(t, deserialized.reason == original.reason, "Reason should match")
	testing.expect(t, deserialized.ttl == original.ttl, "TTL should match")
	testing.expect(
		t,
		deserialized.source_node_name == original.source_node_name,
		"Source node name should match",
	)
}

@(test)
test_spawned_broadcast_empty_name :: proc(t: ^testing.T) {
	test_pid := pack_pid(Handle{idx = 5, gen = 1}, 2)

	original := Actor_Spawned_Broadcast {
		pid              = test_pid,
		name             = "",
		actor_type       = ACTOR_TYPE_UNTYPED,
		parent_pid       = 0,
		ttl              = 1,
		source_node_name = "node_X",
		source_port      = 8080,
		source_ip        = 0xC0A80101, // 192.168.1.1
	}

	buf: [512]byte
	msg_len := build_wire_format_into_buffer(
		buf[:],
		original,
		Handle{},
		Handle{},
		{.LIFECYCLE_EVENT},
		"",
	)
	testing.expect(t, msg_len > 0, "Should build wire format for empty name")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")

	payload := header.payload
	deserialized: Actor_Spawned_Broadcast
	intrinsics.mem_copy_non_overlapping(
		&deserialized,
		raw_data(payload),
		size_of(Actor_Spawned_Broadcast),
	)

	str_offset := size_of(Actor_Spawned_Broadcast)

	name_len := len(deserialized.name)
	if name_len > 0 {
		deserialized.name = string(payload[str_offset:str_offset + name_len])
		str_offset += name_len
	} else {
		deserialized.name = ""
	}

	source_name_len := len(deserialized.source_node_name)
	if source_name_len > 0 {
		deserialized.source_node_name = string(payload[str_offset:str_offset + source_name_len])
	}

	testing.expect(t, deserialized.pid == original.pid, "PID should match")
	testing.expect(t, deserialized.name == "", "Name should be empty")
	testing.expect(t, deserialized.ttl == 1, "TTL should match")
	testing.expect(
		t,
		deserialized.source_node_name == "node_X",
		"Source node name should survive empty name",
	)
	testing.expect(t, deserialized.source_port == 8080, "Source port should match")
	testing.expect(t, deserialized.source_ip == 0xC0A80101, "Source IP should match")
}

@(test)
test_broadcast_type_hash_lookup :: proc(t: ^testing.T) {
	spawned_info := get_validated_message_info_ptr(Actor_Spawned_Broadcast)
	terminated_info := get_validated_message_info_ptr(Actor_Terminated_Broadcast)

	testing.expect(t, spawned_info.type_hash != 0, "Spawned broadcast hash should be non-zero")
	testing.expect(
		t,
		terminated_info.type_hash != 0,
		"Terminated broadcast hash should be non-zero",
	)
	testing.expect(
		t,
		spawned_info.type_hash != terminated_info.type_hash,
		"Hashes should be distinct",
	)

	found_spawned, ok1 := get_type_info_by_hash(spawned_info.type_hash)
	testing.expect(t, ok1, "Should find spawned broadcast by hash")
	testing.expect(
		t,
		found_spawned.type_id == Actor_Spawned_Broadcast,
		"Type ID should match for spawned",
	)

	found_terminated, ok2 := get_type_info_by_hash(terminated_info.type_hash)
	testing.expect(t, ok2, "Should find terminated broadcast by hash")
	testing.expect(
		t,
		found_terminated.type_id == Actor_Terminated_Broadcast,
		"Type ID should match for terminated",
	)
}

@(test)
test_wire_format_byte_slice_roundtrip :: proc(t: ^testing.T) {
	register_test_types()

	blob := []byte{0xca, 0xfe, 0xba, 0xbe, 0x01, 0x02}
	original := Test_Bytes_Message {
		id      = 77,
		payload = blob,
	}

	exact_size := wire_format_exact_size(original, 0)
	buf: [512]byte
	msg_len := build_wire_format_into_buffer(
		buf[:],
		original,
		Handle{},
		Handle{},
		{.LIFECYCLE_EVENT},
		"",
	)
	testing.expect(t, msg_len > 0, "Should build wire format successfully")
	testing.expect_value(t, msg_len, exact_size)

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")

	payload := header.payload
	testing.expect(
		t,
		len(payload) == size_of(Test_Bytes_Message) + len(blob),
		"Payload should carry struct plus byte slice data",
	)

	info, _ := get_type_info_ptr(typeid_of(Test_Bytes_Message))
	value := (cast(^Test_Bytes_Message)raw_data(payload))^
	storage: [256]byte
	copied := copy_variable_data_from_payload(&storage[0], &value, payload, info, 0)
	testing.expect(t, copied, "Receive-side copy should succeed")

	testing.expect_value(t, value.id, u64(77))
	testing.expect(t, len(value.payload) == len(blob), "Byte slice length should match")
	testing.expect(
		t,
		uintptr(raw_data(value.payload)) >= uintptr(&storage[0]) &&
		uintptr(raw_data(value.payload)) < uintptr(&storage[0]) + size_of(storage),
		"Byte slice should be re-based into receive storage",
	)
	for b, i in blob {
		testing.expect_value(t, value.payload[i], b)
	}
}

@(test)
test_wire_format_union_byte_slice_roundtrip :: proc(t: ^testing.T) {
	register_test_types()

	blob := []byte{10, 20, 30, 40}
	original := Test_Mixed_Bytes_Union(Test_Bytes_Variant{data = blob, tag = 5})

	exact_size := wire_format_exact_size(original, 0)
	buf: [512]byte
	msg_len := build_wire_format_into_buffer(
		buf[:],
		original,
		Handle{},
		Handle{},
		{.LIFECYCLE_EVENT},
		"",
	)
	testing.expect(t, msg_len > 0, "Should build wire format successfully")
	testing.expect_value(t, msg_len, exact_size)

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")
	payload := header.payload

	info, _ := get_type_info_ptr(typeid_of(Test_Mixed_Bytes_Union))
	value := (cast(^Test_Mixed_Bytes_Union)raw_data(payload))^
	storage: [256]byte
	copied := copy_variable_data_from_payload(&storage[0], &value, payload, info, 0)
	testing.expect(t, copied, "Receive-side copy should succeed")

	variant, is_bytes := value.(Test_Bytes_Variant)
	testing.expect(t, is_bytes, "Active variant should survive")
	testing.expect_value(t, variant.tag, u32(5))
	testing.expect(t, len(variant.data) == 4, "Variant byte slice length should match")
	for b, i in blob {
		testing.expect_value(t, variant.data[i], b)
	}
}
