package actod

import "base:runtime"
import "core:log"

MAX_SPAWN_FUNCS :: 256

g_spawn_registry: Name_Registry(SPAWN, MAX_SPAWN_FUNCS)

register_spawn_func :: proc(name: string, spawn_func: SPAWN) -> bool {
	idx, _ := registry_register(&g_spawn_registry, name, spawn_func)
	return idx >= 0
}

get_spawn_func :: proc(name: string) -> (SPAWN, bool) {
	func_ptr, found := registry_get_by_name(&g_spawn_registry, name)
	if found {
		return func_ptr^, true
	}
	return nil, false
}

get_spawn_func_by_hash :: proc(hash: u64) -> (SPAWN, bool) {
	func_ptr, found := registry_get_by_hash(&g_spawn_registry, hash)
	if found {
		return func_ptr^, true
	}
	return nil, false
}

get_spawn_func_hash :: proc(name: string) -> u64 {
	return fnv1a_hash(name)
}

has_spawn_func :: proc(name: string) -> bool {
	return registry_has(&g_spawn_registry, name)
}

spawn_by_name :: proc(
	spawn_func_name: string,
	actor_name: string,
	parent_pid: PID = 0,
) -> (
	PID,
	bool,
) {
	spawn_func, found := get_spawn_func(spawn_func_name)
	if !found {
		log.errorf("Unknown spawn function: '%s'", spawn_func_name)
		return 0, false
	}
	return spawn_func(actor_name, parent_pid)
}

get_spawn_func_name_by_hash :: proc(hash: u64) -> (string, bool) {
	return registry_get_name_by_hash(&g_spawn_registry, hash)
}

get_registered_spawn_funcs :: proc(allocator := context.allocator) -> []string {
	count := registry_count(&g_spawn_registry)
	result := make([]string, count, allocator)
	for i in 0 ..< count {
		result[i], _ = registry_get_name(&g_spawn_registry, i)
	}
	return result
}


@(fini)
cleanup_spawn_registry :: proc "contextless" () {
	context = runtime.default_context()
	registry_destroy(&g_spawn_registry)
}
