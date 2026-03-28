package actod

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:strings"
import "core:sync"

PID :: distinct u64

Actor_Ref :: union {
	PID,
	string,
}

Actor_Type :: distinct u8
ACTOR_TYPE_UNTYPED :: Actor_Type(0)
MAX_ACTOR_TYPES :: 256

Handle :: struct {
	idx:        u32,
	gen:        u16,
	actor_type: Actor_Type,
	_pad:       u8,
}

// Node ID for distributed actors
// Node ID 0 is reserved for "no specific node" (like PID 0 for "no specific sender")
// Node ID 1 is reserved for the local node
// Remote node IDs start at 2
Node_ID :: distinct u16
current_node_id: Node_ID = 1

// Global node ID counter - starts at 2 (0 is reserved, 1 is local node)
global_next_node_id: Node_ID = 2

// PID Layout: [node_id:16][type:8][generation:16][index:24]
pack_pid :: proc(h: Handle, node_id: Node_ID = current_node_id) -> PID {
	return PID(
		(u64(node_id) << 48) |
		(u64(h.actor_type) << 40) |
		((u64(h.gen) & 0xFFFF) << 24) |
		(u64(h.idx) & 0xFFFFFF),
	)
}

unpack_pid :: proc(pid: PID) -> (handle: Handle, node_id: Node_ID) {
	node_id = Node_ID(pid >> 48)
	handle.actor_type = Actor_Type((pid >> 40) & 0xFF)
	handle.gen = u16((pid >> 24) & 0xFFFF)
	handle.idx = u32(pid & 0xFFFFFF)
	return
}

get_pid_actor_type :: #force_inline proc(pid: PID) -> Actor_Type {
	return Actor_Type((pid >> 40) & 0xFF)
}

is_local_pid :: #force_inline proc(pid: PID) -> bool {
	return Node_ID(pid >> 48) == current_node_id
}

get_node_id :: #force_inline proc(pid: PID) -> Node_ID {
	return Node_ID(pid >> 48)
}

@(init)
pid_formatter_init :: proc "contextless" () {
	context = runtime.default_context()
	if fmt._user_formatters == nil {
		fmt.set_user_formatters(new(map[typeid]fmt.User_Formatter))
	}
	fmt.register_user_formatter(typeid_of(PID), pid_formatter)
}

pid_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	pid := (cast(^PID)arg.data)^
	h, node := unpack_pid(pid)

	// Format as "idx:gen" or "node:idx:gen" for remote
	if node == current_node_id {
		fmt.fmt_int(fi, u64(h.idx), false, 32, 'v')
		io.write_byte(fi.writer, ':')
		fmt.fmt_int(fi, u64(h.gen), false, 32, 'v')
	} else {
		fmt.fmt_int(fi, u64(node), false, 16, 'v')
		io.write_byte(fi.writer, ':')
		fmt.fmt_int(fi, u64(h.idx), false, 32, 'v')
		io.write_byte(fi.writer, ':')
		fmt.fmt_int(fi, u64(h.gen), false, 32, 'v')
	}
	return true
}

resolve_actor_ref :: proc(ref: Actor_Ref) -> (PID, bool) {
	switch r in ref {
	case PID:
		return r, r != 0
	case string:
		return get_actor_pid(r)
	}
	return 0, false
}

Actor_Type_Value :: struct {
	local_id: Actor_Type,
}

g_actor_type_registry: Name_Registry(Actor_Type_Value, MAX_ACTOR_TYPES)

@(fini)
cleanup_actor_type_registry :: proc "contextless" () {
	context = runtime.default_context()
	registry_destroy(&g_actor_type_registry)
}

register_actor_type :: proc(name: string) -> (Actor_Type, bool) {
	registry_ensure_init(&g_actor_type_registry)

	name_hash := fnv1a_hash(name)
	if idx, exists := g_actor_type_registry.hash_to_idx[name_hash]; exists {
		return g_actor_type_registry.entries[idx].value.local_id, true
	}

	sync.lock(&g_actor_type_registry.mtx)
	defer sync.unlock(&g_actor_type_registry.mtx)

	if idx, exists := g_actor_type_registry.hash_to_idx[name_hash]; exists {
		return g_actor_type_registry.entries[idx].value.local_id, true
	}

	if g_actor_type_registry.count >= MAX_ACTOR_TYPES - 1 {
		return 0, false
	}

	idx := g_actor_type_registry.count
	local_id := Actor_Type(idx + 1)

	g_actor_type_registry.entries[idx] = Registry_Entry(Actor_Type_Value) {
		name = strings.clone(name, g_actor_type_registry.allocator),
		name_hash = name_hash,
		value = Actor_Type_Value{local_id = local_id},
	}
	g_actor_type_registry.hash_to_idx[name_hash] = idx
	g_actor_type_registry.count += 1

	return local_id, true
}

get_actor_type_name :: proc(actor_type: Actor_Type) -> (string, bool) {
	registry_ensure_init(&g_actor_type_registry)

	for i in 0 ..< registry_count(&g_actor_type_registry) {
		if g_actor_type_registry.entries[i].value.local_id == actor_type {
			return g_actor_type_registry.entries[i].name, true
		}
	}
	return "", false
}

get_actor_type_by_name :: proc(name: string) -> (Actor_Type, bool) {
	value, found := registry_get_by_name(&g_actor_type_registry, name)
	if found {
		return value.local_id, true
	}
	return 0, false
}

get_actor_type_hash :: proc(actor_type: Actor_Type) -> (u64, bool) {
	registry_ensure_init(&g_actor_type_registry)

	for i in 0 ..< registry_count(&g_actor_type_registry) {
		if g_actor_type_registry.entries[i].value.local_id == actor_type {
			return g_actor_type_registry.entries[i].name_hash, true
		}
	}
	return 0, false
}

get_actor_type_by_hash :: proc(hash: u64) -> (Actor_Type, bool) {
	value, found := registry_get_by_hash(&g_actor_type_registry, hash)
	if found {
		return value.local_id, true
	}
	return 0, false
}
