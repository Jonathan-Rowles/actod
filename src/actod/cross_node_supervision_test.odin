package actod

import "base:intrinsics"
import "core:testing"
import "core:time"

@(test)
test_is_local_pid_local :: proc(t: ^testing.T) {
	saved := current_node_id
	defer {current_node_id = saved}
	current_node_id = 1

	handle := Handle {
		idx        = 5,
		gen        = 1,
		actor_type = 0,
	}
	pid := pack_pid(handle, Node_ID(1))

	testing.expect(t, is_local_pid(pid), "PID with current node_id should be local")
	testing.expect_value(t, get_node_id(pid), Node_ID(1))
}

@(test)
test_is_local_pid_remote :: proc(t: ^testing.T) {
	saved := current_node_id
	defer {current_node_id = saved}
	current_node_id = 1

	handle := Handle {
		idx        = 5,
		gen        = 1,
		actor_type = 0,
	}
	pid := pack_pid(handle, Node_ID(3))

	testing.expect(t, !is_local_pid(pid), "PID with different node_id should be remote")
	testing.expect_value(t, get_node_id(pid), Node_ID(3))
}

@(test)
test_restart_info_local_defaults :: proc(t: ^testing.T) {
	info := Restart_Info {
		count         = 0,
		first_restart = time.now(),
		last_restart  = time.now(),
		child_index   = 2,
	}

	testing.expect_value(t, info.spawn_func_name_hash, u64(0))
	testing.expect_value(t, info.node_id, Node_ID(0))
}

@(test)
test_restart_info_remote_fields :: proc(t: ^testing.T) {
	hash := fnv1a_hash("my_spawn_func")
	info := Restart_Info {
		count                = 1,
		first_restart        = time.now(),
		last_restart         = time.now(),
		child_index          = 0,
		spawn_func_name_hash = hash,
		node_id              = Node_ID(3),
	}

	testing.expect_value(t, info.spawn_func_name_hash, hash)
	testing.expect_value(t, info.node_id, Node_ID(3))
	testing.expect(t, info.spawn_func_name_hash != 0, "Hash should be non-zero")
}

@(test)
test_remote_spawn_request_wire_format :: proc(t: ^testing.T) {
	request := Remote_Spawn_Request {
		request_id           = 42,
		parent_pid           = PID(100),
		spawn_func_name_hash = fnv1a_hash("test_spawn"),
		actor_name           = "worker-1",
	}

	buf: [1024]byte
	from_handle := Handle {
		idx = 1,
		gen = 1,
	}
	msg_len := build_wire_format_into_buffer(
		buf[:],
		request,
		Handle{},
		from_handle,
		{.LIFECYCLE_EVENT},
		"",
	)

	testing.expect(t, msg_len > 0, "Wire format build should succeed")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header successfully")
	testing.expect(t, .LIFECYCLE_EVENT in header.flags, "LIFECYCLE_EVENT flag should be set")

	testing.expect(
		t,
		len(header.payload) >= size_of(Remote_Spawn_Request),
		"Payload should contain at least the struct size",
	)

	parsed: Remote_Spawn_Request
	intrinsics.mem_copy_non_overlapping(
		&parsed,
		raw_data(header.payload),
		size_of(Remote_Spawn_Request),
	)
	testing.expect_value(t, parsed.request_id, u64(42))
	testing.expect_value(t, parsed.parent_pid, PID(100))
	testing.expect_value(t, parsed.spawn_func_name_hash, fnv1a_hash("test_spawn"))

	name_len := len(parsed.actor_name)
	if name_len > 0 {
		name_start := size_of(Remote_Spawn_Request)
		parsed.actor_name = string(header.payload[name_start:name_start + name_len])
	}
	testing.expect(t, parsed.actor_name == "worker-1", "Actor name should round-trip correctly")
}

@(test)
test_remote_spawn_response_wire_format :: proc(t: ^testing.T) {
	response := Remote_Spawn_Response {
		request_id = 42,
		success    = true,
		pid        = PID(12345),
		error_msg  = "",
	}

	buf: [1024]byte
	from_handle := Handle {
		idx = 1,
		gen = 1,
	}
	msg_len := build_wire_format_into_buffer(
		buf[:],
		response,
		Handle{},
		from_handle,
		{.LIFECYCLE_EVENT},
		"",
	)

	testing.expect(t, msg_len > 0, "Wire format build should succeed")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")

	parsed: Remote_Spawn_Response
	intrinsics.mem_copy_non_overlapping(
		&parsed,
		raw_data(header.payload),
		size_of(Remote_Spawn_Response),
	)
	testing.expect_value(t, parsed.request_id, u64(42))
	testing.expect_value(t, parsed.success, true)
	testing.expect_value(t, parsed.pid, PID(12345))
}

@(test)
test_remote_spawn_response_with_error :: proc(t: ^testing.T) {
	response := Remote_Spawn_Response {
		request_id = 99,
		success    = false,
		pid        = 0,
		error_msg  = "Unknown spawn function",
	}

	buf: [1024]byte
	from_handle := Handle {
		idx = 1,
		gen = 1,
	}
	msg_len := build_wire_format_into_buffer(
		buf[:],
		response,
		Handle{},
		from_handle,
		{.LIFECYCLE_EVENT},
		"",
	)

	testing.expect(t, msg_len > 0, "Wire format build should succeed")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")

	parsed: Remote_Spawn_Response
	intrinsics.mem_copy_non_overlapping(
		&parsed,
		raw_data(header.payload),
		size_of(Remote_Spawn_Response),
	)
	testing.expect_value(t, parsed.request_id, u64(99))
	testing.expect_value(t, parsed.success, false)

	error_len := len(parsed.error_msg)
	if error_len > 0 {
		str_start := size_of(Remote_Spawn_Response)
		parsed.error_msg = string(header.payload[str_start:str_start + error_len])
	}
	testing.expect(
		t,
		parsed.error_msg == "Unknown spawn function",
		"Error message should round-trip",
	)
}

@(test)
test_spawn_func_name_by_hash_roundtrip :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	hash := get_spawn_func_hash("test_spawn_a")
	name, found := get_spawn_func_name_by_hash(hash)
	testing.expect(t, found, "Should find name by hash")
	testing.expect(t, name == "test_spawn_a", "Name should match")
}

@(test)
test_spawn_func_name_by_hash_unknown :: proc(t: ^testing.T) {
	_, found := get_spawn_func_name_by_hash(0xDEADBEEF)
	testing.expect(t, !found, "Should not find unknown hash")
}

@(test)
test_pending_spawn_slots_initially_free :: proc(t: ^testing.T) {
	for i in 0 ..< MAX_PENDING_SPAWNS {
		testing.expect_value(t, g_pending_spawn_ids[i], u64(0))
	}
}

@(test)
test_actor_stopped_message_fields :: proc(t: ^testing.T) {
	msg := Actor_Stopped {
		child_pid   = PID(42),
		reason      = .ABNORMAL,
		child_name  = "my-child",
		child_index = 3,
	}

	testing.expect_value(t, msg.child_pid, PID(42))
	testing.expect_value(t, msg.reason, Termination_Reason.ABNORMAL)
	testing.expect(t, msg.child_name == "my-child", "child_name should match")
	testing.expect_value(t, msg.child_index, 3)
}

@(test)
test_actor_stopped_wire_format :: proc(t: ^testing.T) {
	msg := Actor_Stopped {
		child_pid   = PID(42),
		reason      = .ABNORMAL,
		child_name  = "test-child",
		child_index = 1,
	}

	buf: [1024]byte
	from_handle := Handle {
		idx = 1,
		gen = 1,
	}
	to_handle := Handle {
		idx = 2,
		gen = 1,
	}
	msg_len := build_wire_format_into_buffer(buf[:], msg, to_handle, from_handle, {}, "")

	testing.expect(t, msg_len > 0, "Wire format build should succeed for Actor_Stopped")

	header, ok := parse_network_header(buf[4:msg_len])
	testing.expect(t, ok, "Should parse header")

	parsed: Actor_Stopped
	intrinsics.mem_copy_non_overlapping(&parsed, raw_data(header.payload), size_of(Actor_Stopped))
	testing.expect_value(t, parsed.child_pid, PID(42))
	testing.expect_value(t, parsed.reason, Termination_Reason.ABNORMAL)
	testing.expect_value(t, parsed.child_index, 1)

	name_len := len(parsed.child_name)
	if name_len > 0 {
		str_start := size_of(Actor_Stopped)
		parsed.child_name = string(header.payload[str_start:str_start + name_len])
	}
	testing.expect(t, parsed.child_name == "test-child", "child_name should round-trip")
}
