package actod

import "core:encoding/endian"
import "core:net"
import "core:sync"
import "core:testing"

@(test)
test_node_registry :: proc(t: ^testing.T) {
	if NODE.node_name_to_id == nil {
		NODE.node_name_to_id = make(map[string]Node_ID)
	}

	defer {
		keys := make([dynamic]string, 0, len(NODE.node_name_to_id))
		for name, id in NODE.node_name_to_id {
			append(&keys, name)
			if NODE.node_registry[id].node_name != "" {
				delete(NODE.node_registry[id].node_name, get_system_allocator())
				NODE.node_registry[id] = {}
			}
		}
		for key in keys {
			delete_key(&NODE.node_name_to_id, key)
		}
		delete(keys)
		delete(NODE.node_name_to_id)
		NODE.node_name_to_id = nil
	}

	test_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = 9001,
	}

	current_node_id = 1
	sync.atomic_store(&global_next_node_id, 2)

	node_id, ok := register_node("remote_node", test_addr, .TCP_Custom_Protocol)
	testing.expect(t, ok, "Failed to register node")
	testing.expect(t, node_id > 1, "Invalid node ID")

	info, info_ok := get_node_info(node_id)
	testing.expect(t, info_ok, "Failed to get node info")
	testing.expect(t, info.node_name == "remote_node", "Node name mismatch")
	testing.expect(t, info.address == test_addr, "Address mismatch")
	testing.expect(t, info.transport == .TCP_Custom_Protocol, "Transport mismatch")

	node_id2, ok2 := register_node("remote_node", test_addr, .TCP_Custom_Protocol)
	testing.expect(t, !ok2, "Should not allow duplicate node registration")
	testing.expect(t, node_id2 == node_id, "Should return existing node ID")

	found_id, found := NODE.node_name_to_id["remote_node"]
	testing.expect(t, found, "Failed to find node by name")
	testing.expect(t, found_id == node_id, "Node ID mismatch in lookup")

	unregister_node(node_id)
}

@(test)
test_pid_packing_unpacking :: proc(t: ^testing.T) {
	handle := Handle {
		idx        = 123,
		gen        = 456,
		actor_type = Actor_Type(7),
	}
	node_id: Node_ID = 789

	pid := pack_pid(handle, node_id)

	unpacked_handle, unpacked_node_id := unpack_pid(pid)

	testing.expect(t, unpacked_handle.idx == handle.idx, "Handle idx mismatch")
	testing.expect(t, unpacked_handle.gen == handle.gen, "Handle gen mismatch")
	testing.expect(
		t,
		unpacked_handle.actor_type == handle.actor_type,
		"Handle actor_type mismatch",
	)
	testing.expect(t, unpacked_node_id == node_id, "Node ID mismatch")

	local_pid := pack_pid(handle, current_node_id)
	remote_pid := pack_pid(handle, 999)

	testing.expect(t, is_local_pid(local_pid), "Local PID not recognized")
	testing.expect(t, !is_local_pid(remote_pid), "Remote PID incorrectly identified as local")
}

@(test)
test_pid_actor_type_roundtrip :: proc(t: ^testing.T) {
	h0 := Handle {
		idx = 1,
		gen = 1,
	}
	pid0 := pack_pid(h0)
	testing.expect(t, get_pid_actor_type(pid0) == ACTOR_TYPE_UNTYPED, "Untyped should be 0")

	for type_val in 0 ..< u16(MAX_ACTOR_TYPES) {
		h := Handle {
			idx        = 42,
			gen        = 100,
			actor_type = Actor_Type(type_val),
		}
		pid := pack_pid(h, 5)
		unpacked, node := unpack_pid(pid)

		testing.expect(t, unpacked.actor_type == Actor_Type(type_val), "Actor type mismatch")
		testing.expect(
			t,
			get_pid_actor_type(pid) == Actor_Type(type_val),
			"get_pid_actor_type mismatch",
		)
		testing.expect(t, unpacked.idx == 42, "idx corrupted by actor_type")
		testing.expect(t, unpacked.gen == 100, "gen corrupted by actor_type")
		testing.expect(t, node == 5, "node_id corrupted by actor_type")
	}
}

@(test)
test_pid_index_boundary :: proc(t: ^testing.T) {
	max_idx: u32 = 0xFFFFFF
	h := Handle {
		idx        = max_idx,
		gen        = 1,
		actor_type = Actor_Type(255),
	}
	pid := pack_pid(h, 1)
	unpacked, _ := unpack_pid(pid)

	testing.expect(t, unpacked.idx == max_idx, "24-bit max index failed roundtrip")

	h_overflow := Handle {
		idx = 0x1000000,
		gen = 1,
	}
	pid_overflow := pack_pid(h_overflow, 1)
	unpacked_overflow, _ := unpack_pid(pid_overflow)
	testing.expect(t, unpacked_overflow.idx == 0, "Index overflow not masked to 24 bits")
}

@(test)
test_pid_generation_boundary :: proc(t: ^testing.T) {
	max_gen: u16 = 0xFFFF
	h := Handle {
		idx        = 1,
		gen        = max_gen,
		actor_type = Actor_Type(128),
	}
	pid := pack_pid(h, 1)
	unpacked, _ := unpack_pid(pid)

	testing.expect(t, unpacked.gen == max_gen, "16-bit max gen failed roundtrip")
}

@(test)
test_get_node_by_name :: proc(t: ^testing.T) {
	if NODE.node_name_to_id == nil {
		NODE.node_name_to_id = make(map[string]Node_ID)
	}
	defer {
		keys := make([dynamic]string, 0, len(NODE.node_name_to_id))
		for name, id in NODE.node_name_to_id {
			append(&keys, name)
			if NODE.node_registry[id].node_name != "" {
				delete(NODE.node_registry[id].node_name, get_system_allocator())
				NODE.node_registry[id] = {}
			}
		}
		for key in keys {
			delete_key(&NODE.node_name_to_id, key)
		}
		delete(keys)
		delete(NODE.node_name_to_id)
		NODE.node_name_to_id = nil
	}

	test_addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = 9002,
	}

	current_node_id = 1
	sync.atomic_store(&global_next_node_id, 2)

	node_id, ok := register_node("test_remote", test_addr, .TCP_Custom_Protocol)
	testing.expect(t, ok, "Failed to register node")

	found_id, found := get_node_by_name("test_remote")
	testing.expect(t, found, "Failed to find node by name")
	testing.expect(t, found_id == node_id, "Node ID mismatch")

	_, not_found := get_node_by_name("non_existent")
	testing.expect(t, !not_found, "Should not find non-existent node")

	node_name, name_ok := get_node_name(node_id)
	testing.expect(t, name_ok, "get_node_name should succeed for registered node")
	testing.expect(t, node_name == "test_remote", "get_node_name should return correct name")

	_, bad_name_ok := get_node_name(Node_ID(999))
	testing.expect(t, !bad_name_ok, "get_node_name should fail for unknown node")

	unregister_node(node_id)
}

@(test)
test_pid_remapping_preserves_handle :: proc(t: ^testing.T) {
	original_handle := Handle {
		idx        = 42,
		gen        = 7,
		actor_type = Actor_Type(3),
	}
	source_pid := pack_pid(original_handle, Node_ID(1))

	h, _ := unpack_pid(source_pid)
	remapped_pid := pack_pid(h, Node_ID(5))

	remapped_h, remapped_node := unpack_pid(remapped_pid)
	testing.expect(t, remapped_h.idx == original_handle.idx, "idx should be preserved after remap")
	testing.expect(t, remapped_h.gen == original_handle.gen, "gen should be preserved after remap")
	testing.expect(
		t,
		remapped_h.actor_type == original_handle.actor_type,
		"actor_type should be preserved after remap",
	)
	testing.expect(t, remapped_node == Node_ID(5), "node_id should be remapped to 5")
	testing.expect(t, remapped_node != Node_ID(1), "node_id should no longer be 1")
}

@(test)
test_ipv4_to_u32_roundtrip :: proc(t: ^testing.T) {
	test_cases := [?]net.IP4_Address {
		{127, 0, 0, 1},
		{0, 0, 0, 0},
		{255, 255, 255, 255},
		{192, 168, 1, 1},
		{10, 0, 0, 1},
	}

	for tc in test_cases {
		ip_u32 := ipv4_to_u32(tc)
		result := u32_to_ipv4(ip_u32)
		testing.expectf(t, result == tc, "IPv4 roundtrip failed for %v: got %v", tc, result)
	}
}

@(test)
test_ipv4_to_u32_known_values :: proc(t: ^testing.T) {
	loopback := ipv4_to_u32(net.IP4_Address{127, 0, 0, 1})
	testing.expect(t, loopback == 0x7F000001, "127.0.0.1 should be 0x7F000001")

	any_addr := ipv4_to_u32(net.IP4_Address{0, 0, 0, 0})
	testing.expect(t, any_addr == 0x00000000, "0.0.0.0 should be 0")

	private := ipv4_to_u32(net.IP4_Address{192, 168, 1, 1})
	testing.expect(t, private == 0xC0A80101, "192.168.1.1 should be 0xC0A80101")

	ipv6_result := ipv4_to_u32(net.IP6_Address{})
	testing.expect(t, ipv6_result == 0, "IPv6 address should return 0")
}

@(test)
test_build_endpoint_from_broadcast :: proc(t: ^testing.T) {
	msg := Actor_Spawned_Broadcast {
		pid              = 0,
		source_node_name = "test_node",
		source_port      = 9001,
		source_ip        = 0xC0A80101,
	}

	endpoint := build_endpoint_from_broadcast(msg)
	testing.expect(t, endpoint.port == 9001, "Port should be 9001")

	ip4, is_ip4 := endpoint.address.(net.IP4_Address)
	testing.expect(t, is_ip4, "Address should be IPv4")
	testing.expect(t, ip4 == net.IP4_Address{192, 168, 1, 1}, "IP should be 192.168.1.1")
}

@(test)
test_build_endpoint_zero_port :: proc(t: ^testing.T) {
	msg := Actor_Spawned_Broadcast {
		pid              = 0,
		source_node_name = "test_node",
		source_port      = 0,
		source_ip        = 0x7F000001,
	}

	endpoint := build_endpoint_from_broadcast(msg)
	testing.expect(t, endpoint.port == 0, "Zero port should return empty endpoint")
	testing.expect(t, endpoint.address == nil, "Zero port should return nil address")
}

@(test)
test_register_node_deduplication :: proc(t: ^testing.T) {
	if NODE.node_name_to_id == nil {
		NODE.node_name_to_id = make(map[string]Node_ID)
	}
	defer {
		keys := make([dynamic]string, 0, len(NODE.node_name_to_id))
		for name, id in NODE.node_name_to_id {
			append(&keys, name)
			if NODE.node_registry[id].node_name != "" {
				delete(NODE.node_registry[id].node_name, get_system_allocator())
				NODE.node_registry[id] = {}
			}
		}
		for key in keys {
			delete_key(&NODE.node_name_to_id, key)
		}
		delete(keys)
		delete(NODE.node_name_to_id)
		NODE.node_name_to_id = nil
	}

	current_node_id = 1
	sync.atomic_store(&global_next_node_id, 2)

	addr := net.Endpoint {
		address = net.IP4_Address{10, 0, 0, 1},
		port    = 9001,
	}

	id1, ok1 := register_node("dedup_node", addr, .TCP_Custom_Protocol)
	testing.expect(t, ok1, "First registration should succeed")
	testing.expect(t, id1 >= 2, "Should get valid node ID")

	id2, ok2 := register_node("dedup_node", addr, .TCP_Custom_Protocol)
	testing.expect(t, !ok2, "Second registration should return false (not new)")
	testing.expect(t, id2 == id1, "Should return same ID for duplicate name")

	next := sync.atomic_load(&global_next_node_id)
	testing.expect(t, next == id1 + 1, "Should not have consumed extra node ID")

	unregister_node(id1)
}

@(test)
test_node_directory_serialization :: proc(t: ^testing.T) {
	node1_name := "node_alpha"
	node2_name := "node_beta"

	total_size := 1 + 2
	total_size += 2 + len(node1_name) + 4 + 2
	total_size += 2 + len(node2_name) + 4 + 2

	buf := make([]byte, total_size)
	defer delete(buf)

	offset := 0
	buf[offset] = CTRL_MSG_NODE_DIRECTORY
	offset += 1
	endian.put_u16(buf[offset:], .Little, 2)
	offset += 2

	endian.put_u16(buf[offset:], .Little, u16(len(node1_name)))
	offset += 2
	copy(buf[offset:], transmute([]byte)node1_name)
	offset += len(node1_name)
	endian.put_u32(buf[offset:], .Little, 0x0A000001)
	offset += 4
	endian.put_u16(buf[offset:], .Little, 9001)
	offset += 2

	endian.put_u16(buf[offset:], .Little, u16(len(node2_name)))
	offset += 2
	copy(buf[offset:], transmute([]byte)node2_name)
	offset += len(node2_name)
	endian.put_u32(buf[offset:], .Little, 0x0A000002)
	offset += 4
	endian.put_u16(buf[offset:], .Little, 9002)
	offset += 2

	testing.expect(t, offset == total_size, "Buffer should be fully written")

	if NODE.node_name_to_id == nil {
		NODE.node_name_to_id = make(map[string]Node_ID)
	}
	defer {
		keys := make([dynamic]string, 0, len(NODE.node_name_to_id))
		for name, id in NODE.node_name_to_id {
			append(&keys, name)
			if NODE.node_registry[id].node_name != "" {
				delete(NODE.node_registry[id].node_name, get_system_allocator())
				NODE.node_registry[id] = {}
			}
		}
		for key in keys {
			delete_key(&NODE.node_name_to_id, key)
		}
		delete(keys)
		delete(NODE.node_name_to_id)
		NODE.node_name_to_id = nil
	}

	NODE.name = "local_node"
	current_node_id = 1
	sync.atomic_store(&global_next_node_id, 2)

	handle_node_directory(buf)

	id1, found1 := get_node_by_name("node_alpha")
	testing.expect(t, found1, "node_alpha should be registered")
	info1, _ := get_node_info(id1)
	testing.expect(t, info1.address.port == 9001, "node_alpha port should be 9001")

	id2, found2 := get_node_by_name("node_beta")
	testing.expect(t, found2, "node_beta should be registered")
	info2, _ := get_node_info(id2)
	testing.expect(t, info2.address.port == 9002, "node_beta port should be 9002")

	testing.expect(t, id1 != id2, "Node IDs should be different")

	unregister_node(id1)
	unregister_node(id2)
}
