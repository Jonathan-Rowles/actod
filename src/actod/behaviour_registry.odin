package actod

import "base:runtime"
import "core:log"

MAX_SPAWN_FUNCS :: 256

g_spawn_registry: Name_Registry(SPAWN, MAX_SPAWN_FUNCS)

register_spawn_func :: proc(name: string, spawn_func: SPAWN, loc := #caller_location) -> bool {
	context.logger = diagnostic_logger(context.logger)
	idx, registered := registry_register(&g_spawn_registry, name, spawn_func, loc)
	if registered {
		return true
	}

	if idx < 0 {
		log.errorf(
			"register_spawn_func('%s') failed: the spawn function registry is full (cap %d), raise MAX_SPAWN_FUNCS",
			name,
			MAX_SPAWN_FUNCS,
			location = loc,
		)
		return false
	}

	existing, found := registry_get_by_index(&g_spawn_registry, idx, loc)
	if found && existing^ == spawn_func {
		return true
	}

	log.errorf(
		"register_spawn_func('%s') failed: that name is already registered to a different spawn function, the first registration is kept. Give each spawn function a unique name.",
		name,
		location = loc,
	)
	return false
}

get_spawn_func :: proc(name: string, loc := #caller_location) -> (SPAWN, bool) {
	func_ptr, found := registry_get_by_name(&g_spawn_registry, name, loc)
	if found {
		return func_ptr^, true
	}
	return nil, false
}

get_spawn_func_by_hash :: proc(hash: u64, loc := #caller_location) -> (SPAWN, bool) {
	func_ptr, found := registry_get_by_hash(&g_spawn_registry, hash, loc)
	if found {
		return func_ptr^, true
	}
	return nil, false
}

get_spawn_func_hash :: proc(name: string) -> u64 {
	return fnv1a_hash(name)
}

has_spawn_func :: proc(name: string, loc := #caller_location) -> bool {
	return registry_has(&g_spawn_registry, name, loc)
}

spawn_by_name :: proc(
	spawn_func_name: string,
	actor_name: string,
	parent_pid: PID = 0,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	context.logger = diagnostic_logger(context.logger)
	spawn_func, found := get_spawn_func(spawn_func_name, loc)
	if !found {
		log.errorf(
			"spawn_by_name('%s', '%s') failed: no spawn function named '%s' is registered. Call register_spawn_func(\"%s\", your_spawn_proc) from an @(init) proc before spawning.",
			spawn_func_name,
			actor_name,
			spawn_func_name,
			spawn_func_name,
			location = loc,
		)
		return 0, false
	}
	return spawn_func(actor_name, parent_pid)
}

get_spawn_func_name_by_hash :: proc(hash: u64, loc := #caller_location) -> (string, bool) {
	return registry_get_name_by_hash(&g_spawn_registry, hash, loc)
}

get_registered_spawn_funcs :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> []string {
	count := registry_count(&g_spawn_registry)
	result := make([]string, count, allocator)
	for i in 0 ..< count {
		name, found := registry_get_name(&g_spawn_registry, i, loc)
		if !found {
			log.errorf(
				"get_registered_spawn_funcs: entry %d of %d disappeared while listing, the registry was modified concurrently",
				i,
				count,
				location = loc,
			)
			continue
		}
		result[i] = name
	}
	return result
}


@(fini)
cleanup_spawn_registry :: proc "contextless" () {
	context = runtime.default_context()
	registry_destroy(&g_spawn_registry)
}
