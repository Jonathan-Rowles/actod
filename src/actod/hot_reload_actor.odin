package actod

import "../pkgs/coro"
import "../pkgs/hot_reload"
import "../pkgs/threads_act"
import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

@(private)
create_message_any :: proc(msg: ^Message, pool: ^Pool, content: any) -> bool {
	info, has_info := get_type_info(content.id)
	size := type_info_of(content.id).size

	if !has_info || info.flags == {} {
		if size <= INLINE_MESSAGE_SIZE {
			msg.inline_type = content.id
			msg.content = nil
			intrinsics.mem_copy_non_overlapping(&msg.inline_data, content.data, size)
		} else {
			aligned_size := mem.align_forward_int(TYPE_HEADER_SIZE + size, CACHE_LINE_SIZE)
			buffer := message_alloc(pool, aligned_size)
			if buffer == nil {
				return false
			}
			header := cast(^Type_Header)buffer
			header.type_id = content.id
			header.size = aligned_size
			data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
			intrinsics.mem_copy_non_overlapping(data_ptr, content.data, size)
			msg.content = buffer
			msg.inline_type = nil
		}
		return true
	}

	variable_size := calculate_variable_data_size(content.data, info)
	total_message_size := size + variable_size

	if total_message_size <= INLINE_MESSAGE_SIZE {
		msg.inline_type = content.id
		msg.content = INLINE_NEEDS_FIXUP
		intrinsics.mem_copy_non_overlapping(&msg.inline_data[0], content.data, size)
		copy_variable_data(&msg.inline_data[0], &msg.inline_data[0], content.data, info, size)
	} else {
		aligned_size := mem.align_forward_int(
			TYPE_HEADER_SIZE + size + variable_size,
			CACHE_LINE_SIZE,
		)
		buffer := message_alloc(pool, aligned_size)
		if buffer == nil {
			return false
		}
		header := cast(^Type_Header)buffer
		header.type_id = content.id
		header.size = aligned_size
		data_ptr := rawptr(uintptr(buffer) + TYPE_HEADER_SIZE)
		intrinsics.mem_copy_non_overlapping(data_ptr, content.data, size)
		copy_variable_data(buffer, data_ptr, content.data, info, TYPE_HEADER_SIZE + size)
		msg.content = buffer
		msg.inline_type = nil
	}
	return true
}

@(private)
send_any :: proc(to: PID, content: any, actor: ^Actor(int)) -> Send_Error {
	if sync.atomic_load_explicit(&NODE.shutting_down, .Relaxed) {
		return .SYSTEM_SHUTTING_DOWN
	}

	current_state := sync.atomic_load(&actor.state)
	if current_state != .RUNNING && current_state != .IDLE && current_state != .INIT {
		return .ACTOR_NOT_FOUND
	}

	msg: Message
	msg.from = get_self_pid()

	if current_state == .STOPPING {
		return .ACTOR_NOT_FOUND
	}

	if !create_message_any(&msg, &actor.pool, content) {
		log.errorf("pool full - failed to allocate message for %s", get_actor_name(to))
		return .POOL_FULL
	}

	result := push_to_mailbox(actor, msg, to, get_send_priority())
	if result != .OK {
		free_message(&actor.pool, msg.content)
	}
	return result
}

@(private)
send_message_any :: proc(to: PID, content: any) -> Send_Error {
	if to == 0 {
		return .ACTOR_NOT_FOUND
	}
	if sync.atomic_load_explicit(&NODE.shutting_down, .Relaxed) {
		return .SYSTEM_SHUTTING_DOWN
	}
	actor_ptr := get_relaxed(&global_registry, to)
	if actor_ptr == nil {
		return .ACTOR_NOT_FOUND
	}
	return send_any(to, content, cast(^Actor(int))actor_ptr)
}

@(private)
broadcast_any :: proc(content: any) {
	self_pid := get_self_pid()
	actor_type := get_pid_actor_type(self_pid)

	if actor_type == ACTOR_TYPE_UNTYPED {
		log.warn("broadcast() called from untyped actor")
		return
	}

	list := &type_subscribers[actor_type]
	n := sync.atomic_load_explicit(&list.local_count, .Acquire)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&list.subscribers[i], .Acquire))
		if pid != 0 && pid != self_pid {
			send_message_any(pid, content)
		}
	}
}

@(private)
publish_any :: proc(topic: ^Topic, content: any) {
	if topic == nil {
		return
	}
	self_pid := get_self_pid()
	n := sync.atomic_load_explicit(&topic.count, .Acquire)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[i], .Acquire))
		if pid != 0 && pid != self_pid {
			send_message_any(pid, content)
		}
	}
}

Raw_Spawn_Behaviour :: struct {
	handle_message:           rawptr,
	init_proc:                rawptr,
	terminate_proc:           rawptr,
	actor_type:               Actor_Type,
	on_child_started:         rawptr,
	on_child_terminated:      rawptr,
	on_child_restarted:       rawptr,
	on_max_restarts_exceeded: rawptr,
}

spawn_from_raw :: proc(
	name: string,
	data_ptr: rawptr,
	data_size: int,
	behaviour: Raw_Spawn_Behaviour,
	opts: Actor_Config,
	parent_pid: PID,
) -> (
	PID,
	bool,
) {
	if !NODE.started {
		log.panic("Must call actor.INIT_NODE() first.")
	}

	if behaviour.handle_message == nil {
		log.panic("Actor_Behaviour.handle_message must not be nil")
	}

	actor := new(Actor(int), actor_system_allocator)

	if actor.state != .ZERO {
		log.panic("reusing non zero memory")
	}

	arena_err := vmem.arena_init_static(&actor.arena)
	ensure(arena_err == nil)
	actor.allocator = vmem.arena_allocator(&actor.arena)
	context.allocator = actor.allocator

	actor.name = strings.clone(name, context.allocator)

	if data_size > 0 {
		ptr, alloc_err := mem.alloc(data_size, align_of(int), actor.allocator)
		if alloc_err != nil {
			log.errorf("Failed to allocate actor data for %s", name)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
		actor.data = cast(^int)ptr
		intrinsics.mem_copy_non_overlapping(ptr, data_ptr, data_size)
	} else {
		ptr, alloc_err := mem.alloc(1, align_of(int), actor.allocator)
		if alloc_err != nil {
			log.errorf("Failed to allocate actor data for %s", name)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
		actor.data = cast(^int)ptr
	}

	actor.handle_message = auto_cast behaviour.handle_message
	actor.behaviour.handle_message = auto_cast behaviour.handle_message
	actor.behaviour.init = auto_cast behaviour.init_proc
	actor.behaviour.terminate = auto_cast behaviour.terminate_proc
	actor.behaviour.actor_type = behaviour.actor_type
	actor.behaviour.on_child_started = auto_cast behaviour.on_child_started
	actor.behaviour.on_child_terminated = auto_cast behaviour.on_child_terminated
	actor.behaviour.on_child_restarted = auto_cast behaviour.on_child_restarted
	actor.behaviour.on_max_restarts_exceeded = auto_cast behaviour.on_max_restarts_exceeded

	actor.opts = opts
	if opts.children != nil {
		actor.opts.children = make([dynamic]SPAWN, 0, len(opts.children), actor.allocator)
		for child in opts.children {
			append(&actor.opts.children, child)
		}
	}
	if actor.opts.message_batch <= 0 {
		log.panicf(
			"Actor '%s' has message_batch=0 — use make_actor_config() instead of raw Actor_Config{{}}",
			name,
		)
	}

	if parent_pid > 0 {
		_, ok := get(&global_registry, parent_pid)
		if !ok do panic("provided parent pid does not exist")
		actor.parent = parent_pid
	}

	init_mpsc(&actor.system_mailbox)
	for i in 0 ..< MAILBOX_PRIORITY_COUNT {
		init_mpsc(&actor.mailbox[i])
	}

	pid, ok := add(&global_registry, rawptr(actor), name, behaviour.actor_type)
	if !ok {
		vmem.arena_destroy(&actor.arena)
		free(actor, actor_system_allocator)
		return 0, false
	}

	actor.pid = pid
	actor.state = .INIT
	actor.termination_reason = .NORMAL
	actor.child_restarts = make(map[PID]Restart_Info, actor.allocator)

	broadcast_actor_spawned(pid, name, behaviour.actor_type, parent_pid)

	started: bool = false
	actor.started = &started

	if !opts.use_dedicated_os_thread && !opts.blocking && worker_pool.initialized {
		actor.local_buf = new([LOCAL_MAILBOX_SIZE]Message, actor.allocator)
		handle := new(Pooled_Actor_Handle, actor.allocator)
		handle.actor_ptr = actor
		handle.mailbox = &actor.mailbox
		handle.system_mailbox = &actor.system_mailbox
		handle.main_fn = proc(ptr: rawptr) {
			actor_loop(cast(^Actor(int))ptr)
		}

		coro_stack := uint(actor.opts.coro_stack_size)
		if coro_stack < coro.MIN_STACK_SIZE {
			coro_stack = coro.MIN_STACK_SIZE
		}
		desc := coro.desc_init(coro_entry, coro_stack, actor.allocator)
		desc.user_data = handle
		co, co_res := coro.create(&desc)
		if co_res != .Success {
			log.errorf("Failed to create coroutine for actor %s: %v", name, co_res)
			remove(&global_registry, pid)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
		handle.co = co
		actor.pool_handle = handle

		idx: int
		if actor.opts.home_worker >= 0 {
			if actor.opts.home_worker >= worker_pool.worker_count {
				log.panicf(
					"Actor '%s' home_worker=%d exceeds worker_count=%d",
					name,
					actor.opts.home_worker,
					worker_pool.worker_count,
				)
			}
			idx = actor.opts.home_worker
		} else {
			idx = sync.atomic_add(&worker_pool.next_worker, 1) % worker_pool.worker_count
			if current_worker != nil &&
			   &worker_pool.workers[idx] == current_worker &&
			   worker_pool.worker_count > 1 {
				idx = sync.atomic_add(&worker_pool.next_worker, 1) % worker_pool.worker_count
			}
		}
		handle.home_worker = &worker_pool.workers[idx]
		sync.atomic_store(&handle.in_ready_queue, true)
		mpsc_push(&handle.home_worker.ready_queue, rawptr(handle))
		sync.atomic_sema_post(&handle.home_worker.wake_sema)
	} else {
		actor.thread = threads_act.create_thread_with_stack_size(actor, proc(actor_ptr: rawptr) {
				actor_loop(cast(^Actor(int))actor_ptr)
			}, uint(actor.opts.stack_size_dedicated_os_thread))
		if actor.thread == nil {
			log.errorf("Failed to create thread for actor %s (PID %d)", name, pid)
			remove(&global_registry, pid)
			vmem.arena_destroy(&actor.arena)
			free(actor, actor_system_allocator)
			return 0, false
		}
	}

	co := coro.running()
	if co != nil {
		for !sync.atomic_load_explicit(&started, .Acquire) {
			co_handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			co_handle.wants_reschedule = true
			coro.yield(co)
		}
	} else {
		for !sync.atomic_load_explicit(&started, .Acquire) {
			intrinsics.cpu_relax()
		}
	}

	return actor.pid, true
}

spawn_child_from_raw :: proc(
	name: string,
	data_ptr: rawptr,
	data_size: int,
	behaviour: Raw_Spawn_Behaviour,
	opts: Actor_Config,
) -> (
	PID,
	bool,
) {
	self_pid := get_self_pid()
	if self_pid == 0 do panic("Call from inside actor context")
	return spawn_from_raw(name, data_ptr, data_size, behaviour, opts, self_pid)
}

hot_module_table: map[u32]^hot_reload.Hot_Module
hot_module_table_mu: sync.RW_Mutex

swap_behaviour :: proc(actor: ^Actor($T), generation: u32) {
	sync.rw_mutex_shared_lock(&hot_module_table_mu)
	module := hot_module_table[generation]
	sync.rw_mutex_shared_unlock(&hot_module_table_mu)
	if module == nil {
		log.errorf("hot reload: no module found for generation %d", generation)
		return
	}

	for sym in module.symbols {
		if sym.ptr == nil do continue
		switch sym.name {
		case "handle_message":
			actor.handle_message = auto_cast sym.ptr
			actor.behaviour.handle_message = auto_cast sym.ptr
		case "init":
			actor.behaviour.init = auto_cast sym.ptr
		case "terminate":
			actor.behaviour.terminate = auto_cast sym.ptr
		case "on_child_started":
			actor.behaviour.on_child_started = auto_cast sym.ptr
		case "on_child_terminated":
			actor.behaviour.on_child_terminated = auto_cast sym.ptr
		case "on_child_restarted":
			actor.behaviour.on_child_restarted = auto_cast sym.ptr
		case "on_max_restarts_exceeded":
			actor.behaviour.on_max_restarts_exceeded = auto_cast sym.ptr
		}
	}

	log.debugf("hot reload: swapped behaviour for actor %v (generation %d)", actor.pid, generation)
}

send_reload_behaviour :: proc(target: PID, generation: u32) -> Send_Error {
	return send_message(target, Reload_Behaviour{generation = generation})
}


MAX_BEHAVIOUR_FIELDS :: 8
MAX_STATE_FIELDS :: 16

Register_Hot_Actor :: struct {
	actor_name:            [64]u8,
	actor_name_len:        int,
	pid:                   PID,
	field_names:           [MAX_BEHAVIOUR_FIELDS][64]u8,
	field_name_lens:       [MAX_BEHAVIOUR_FIELDS]int,
	field_count:           int,
	state_type_name:       [64]u8,
	state_type_len:        int,
	state_size:            int,
	state_field_names:     [MAX_STATE_FIELDS][64]u8,
	state_field_lens:      [MAX_STATE_FIELDS]int,
	state_field_types:     [MAX_STATE_FIELDS][64]u8,
	state_field_type_lens: [MAX_STATE_FIELDS]int,
	state_field_count:     int,
	package_name:          [64]u8,
	package_name_len:      int,
}

File_Changed :: struct {
	package_path:     [128]u8,
	package_path_len: int,
}

@(init)
init_hot_reload_messages :: proc "contextless" () {
	register_message_type(Register_Hot_Actor)
	register_message_type(File_Changed)
}

Actor_Type_Meta :: struct {
	behaviour_field_names: [dynamic]string,
	state_type_name:       string,
	state_size:            int,
	state_field_names:     [dynamic]string,
	state_field_types:     [dynamic]string,
	package_path:          string,
	package_name:          string,
	actor_pids:            [dynamic]PID,
}

Hot_Reload_Actor_Data :: struct {
	modules:        map[string]^hot_reload.Hot_Module, // actor_name -> current module
	prev_modules:   map[string][dynamic]^hot_reload.Hot_Module, // actor_name -> recent modules kept alive
	actor_meta:     map[string]Actor_Type_Meta, // actor_name -> meta
	package_actors: map[string][dynamic]string, // package_path -> actor_names sharing this package
	watch_path:     string,
	watcher:        ^hot_reload.File_Watcher,
	generation:     u32,
}

HOT_RELOAD_PID: PID

@(private)
spawn_hot_reload_child :: proc(_name: string, parent_pid: PID) -> (PID, bool) {
	pid, ok := start_hot_reload_actor(parent_pid)
	if !ok {
		log.panic("hot reload actor failed to start")
	}
	return pid, ok
}

start_hot_reload_actor :: proc(parent_pid: PID = 0) -> (PID, bool) {
	pid, ok := spawn(
		"hot_reload",
		Hot_Reload_Actor_Data{},
		Actor_Behaviour(Hot_Reload_Actor_Data) {
			handle_message = hot_reload_handle_message,
			init = hot_reload_init,
			terminate = hot_reload_terminate,
		},
		make_actor_config(
			restart_policy = .PERMANENT,
			use_dedicated_os_thread = true,
			page_size = mem.Kilobyte * 64,
		),
		parent_pid = parent_pid,
	)
	if ok {
		HOT_RELOAD_PID = pid
	}
	return pid, ok
}

stop_hot_reload_actor :: proc() {
	if HOT_RELOAD_PID != 0 {
		terminate_actor(HOT_RELOAD_PID)
		wait_for_pids([]PID{HOT_RELOAD_PID})
		HOT_RELOAD_PID = 0
	}
}

@(private)
hot_reload_init :: proc(data: ^Hot_Reload_Actor_Data) {
	watch_path: string
	if SYSTEM_CONFIG.hot_reload_watch_path != "" {
		watch_path = SYSTEM_CONFIG.hot_reload_watch_path
	} else {
		found: bool
		watch_path, found = hot_reload.discover_actors_dir(".")
		if !found {
			abs_cwd, abs_err := filepath.abs(".", context.temp_allocator)
			if abs_err != nil {
				log.warn("hot reload: could not resolve working directory, file watching disabled")
				return
			}
			watch_path = abs_cwd
		}
	}

	if abs_watch, abs_err := filepath.abs(watch_path, context.temp_allocator); abs_err == nil {
		watch_path = abs_watch
	}
	data.watch_path = watch_path
	log.infof("hot reload: watching '%s' for changes", watch_path)

	watcher_callback :: proc(event: hot_reload.Watch_Event, user_data: rawptr) {
		path_buf: [128]u8
		path_len := min(len(event.actor_name), 128)
		copy(path_buf[:path_len], transmute([]u8)event.actor_name[:path_len])

		msg := File_Changed {
			package_path_len = path_len,
		}
		msg.package_path = path_buf

		send_message(HOT_RELOAD_PID, msg)
	}

	w, ok := hot_reload.create_watcher(watcher_callback, nil)
	if !ok {
		log.error("hot reload: failed to create file watcher")
		return
	}
	data.watcher = w
	hot_reload.start_watcher(w)

}


@(private)
populate_hot_api :: proc(lib: dynlib.Library) {
	api_sym, found := dynlib.symbol_address(lib, "hot_api")
	if !found || api_sym == nil {
		log.warn(
			"hot reload: shared library does not export hot_api — skipping API table population",
		)
		return
	}
	(cast(^^Hot_API)api_sym)^ = &g_hot_api
}

@(private)
hot_reload_terminate :: proc(data: ^Hot_Reload_Actor_Data) {
	if data.watcher != nil {
		hot_reload.destroy_watcher(data.watcher)
		data.watcher = nil
	}

	for _, mod in data.modules {
		so_path := strings.clone(mod.path, context.temp_allocator)
		hot_reload.unload_module(mod)
		os.remove(so_path)
	}
	delete(data.modules)

	for _, mods in &data.prev_modules {
		for mod in mods {
			so_path := strings.clone(mod.path, context.temp_allocator)
			hot_reload.unload_module(mod)
			os.remove(so_path)
		}
		delete(mods)
	}
	delete(data.prev_modules)

	for _, meta in &data.actor_meta {
		delete(meta.behaviour_field_names)
		delete(meta.state_field_names)
		delete(meta.state_field_types)
		delete(meta.actor_pids)
	}
	delete(data.actor_meta)

	for pkg_path, actors in &data.package_actors {
		tmp_path := join_path({pkg_path, "tmp"})
		if tmp_path != "" && os.is_dir(tmp_path) {
			os.remove_all(tmp_path)
		}
		delete(actors)
	}
	delete(data.package_actors)
}

@(private)
hot_reload_handle_message :: proc(data: ^Hot_Reload_Actor_Data, from: PID, msg: any) {
	switch v in msg {
	case Register_Hot_Actor:
		handle_register(data, v)
	case File_Changed:
		path_buf := v.package_path
		handle_file_changed(data, string(path_buf[:v.package_path_len]))
	}
}

@(private)
copy_fixed_string :: proc(buf: [64]u8, length: int) -> string {
	if length <= 0 do return ""
	result := make([]u8, length)
	for i in 0 ..< length {
		result[i] = buf[i]
	}
	return string(result)
}

@(private)
find_package_dir :: proc(root: string, pkg_name: string) -> string {
	if filepath.base(root) == pkg_name && os.is_dir(root) do return strings.clone(root)

	direct := join_path({root, pkg_name})
	if os.is_dir(direct) do return strings.clone(direct)

	fd, err := os.open(root)
	if err != nil do return ""
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.temp_allocator)
	if read_err != nil do return ""

	for entry in entries {
		if entry.type != .Directory do continue
		name := entry.name
		if name == "tmp" do continue
		if len(name) > 0 && name[0] == '.' do continue

		child_path := join_path({root, name})
		if child_path == "" do continue

		result := find_package_dir(child_path, pkg_name)
		if result != "" do return result
	}

	return ""
}

@(private)
handle_register :: proc(data: ^Hot_Reload_Actor_Data, reg: Register_Hot_Actor) {
	name_buf := reg.actor_name
	actor_name := strings.clone(string(name_buf[:reg.actor_name_len]))

	if actor_name in data.actor_meta {
		meta := &data.actor_meta[actor_name]
		append(&meta.actor_pids, reg.pid)
		log.infof("hot reload: registered additional PID %v for '%s'", reg.pid, actor_name)
		delete(actor_name)
		return
	}

	pkg_buf := reg.package_name
	pkg_name := string(pkg_buf[:reg.package_name_len])

	meta: Actor_Type_Meta
	meta.state_type_name = copy_fixed_string(reg.state_type_name, reg.state_type_len)
	meta.state_size = reg.state_size
	meta.package_name = copy_fixed_string(reg.package_name, reg.package_name_len)

	for i in 0 ..< reg.field_count {
		append(
			&meta.behaviour_field_names,
			copy_fixed_string(reg.field_names[i], reg.field_name_lens[i]),
		)
	}

	for i in 0 ..< reg.state_field_count {
		append(
			&meta.state_field_names,
			copy_fixed_string(reg.state_field_names[i], reg.state_field_lens[i]),
		)
		append(
			&meta.state_field_types,
			copy_fixed_string(reg.state_field_types[i], reg.state_field_type_lens[i]),
		)
	}

	append(&meta.actor_pids, reg.pid)

	if data.watch_path != "" && pkg_name != "" {
		pkg_path := find_package_dir(data.watch_path, pkg_name)
		if pkg_path != "" {
			meta.package_path = pkg_path

			tmp_path := join_path({pkg_path, "tmp"})
			if tmp_path != "" && !os.is_dir(tmp_path) {
				os.make_directory(tmp_path)
			}

			if pkg_path not_in data.package_actors {
				if data.watcher != nil {
					if !hot_reload.add_watch(data.watcher, pkg_path, pkg_path) {
						log.warnf(
							"hot reload: failed to add watch for '%s' (max watches exceeded?)",
							pkg_path,
						)
					}
				}
			}
			if pkg_path not_in data.package_actors {
				data.package_actors[strings.clone(pkg_path)] = {}
			}
			append(&data.package_actors[pkg_path], strings.clone(actor_name))

			log.infof("hot reload: watching '%s' for actor '%s'", pkg_path, actor_name)
		} else {
			log.warnf(
				"hot reload: no package directory '%s' found under '%s' for actor '%s'. " +
				"Hot reload requires each actor to be in its own package directory (e.g. '%s/%s/%s.odin')",
				pkg_name,
				data.watch_path,
				actor_name,
				data.watch_path,
				pkg_name,
				actor_name,
			)
		}
	}

	data.actor_meta[actor_name] = meta
}

@(private)
regenerate_exports :: proc(
	data: ^Hot_Reload_Actor_Data,
	pkg_path: string,
	pkg_name: string,
	output_dir: string = "",
) {
	actor_names := data.package_actors[pkg_path]

	seen_types: map[string]bool
	defer delete(seen_types)

	exports: [dynamic]hot_reload.Actor_Export
	defer delete(exports)

	existing_procs := hot_reload.discover_package_procs(pkg_path, context.temp_allocator)

	proc_exists :: proc(name: string, existing: []string) -> bool {
		for p in existing {
			if p == name do return true
		}
		return false
	}

	for name in actor_names {
		meta, exists := data.actor_meta[name]
		if !exists do continue
		if meta.state_type_name in seen_types do continue
		seen_types[meta.state_type_name] = true

		mappings := hot_reload.discover_proc_names(
			pkg_path,
			meta.state_type_name,
			meta.behaviour_field_names[:],
			context.temp_allocator,
		)

		procs: [dynamic]hot_reload.Export_Proc
		procs.allocator = context.temp_allocator

		for field_name in meta.behaviour_field_names {
			proc_name := field_name
			for m in mappings {
				if m.field_name == field_name {
					proc_name = m.proc_name
					break
				}
			}

			if !proc_exists(proc_name, existing_procs) do continue

			append(&procs, hot_reload.Export_Proc{field_name = field_name, proc_name = proc_name})
		}

		if len(procs) == 0 {
			log.warnf(
				"hot reload: no exportable procs found for '%s' (anonymous procs can't be hot-reloaded — use named procs)",
				meta.state_type_name,
			)
		}

		append(
			&exports,
			hot_reload.Actor_Export{state_type_name = meta.state_type_name, procs = procs[:]},
		)
	}

	dir := output_dir if output_dir != "" else pkg_path
	exports_path := join_path({dir, "hot_exports.odin"})
	log.debugf(
		"hot reload: writing exports to '%s' (%d actors)",
		exports_path,
		len(exports),
	)
	hot_reload.generate_exports_file(exports_path, pkg_name, exports[:])
}

@(private)
Build_Dep :: struct {
	real_path:  string,
	build_name: string,
}

@(private)
prepare_build_dir :: proc(
	pkg_path: string,
	pkg_name: string,
) -> (
	build_pkg_path: string,
	ok: bool,
) {
	build_root := join_path({pkg_path, "tmp", "build"})

	os.make_directory(join_path({pkg_path, "tmp"}))
	os.make_directory(build_root)
	os.make_directory(join_path({build_root, "_hot_actod"}))

	types_content: string = hot_reload.TYPES_SHIM
	if err := os.write_entire_file(
		join_path({build_root, "_hot_actod", "types.odin"}),
		transmute([]u8)types_content,
	); err != nil {
		log.errorf("hot reload: failed to write types shim: %v", err)
		return "", false
	}

	actod_content: string = hot_reload.ACTOD_SHIM
	if err := os.write_entire_file(
		join_path({build_root, "_hot_actod", "actod.odin"}),
		transmute([]u8)actod_content,
	); err != nil {
		log.errorf("hot reload: failed to write actod shim: %v", err)
		return "", false
	}

	deps: [dynamic]Build_Dep
	deps.allocator = context.temp_allocator
	dep_map: map[string]string // clean(real_path) -> build_name
	dep_map.allocator = context.temp_allocator
	used_names: map[string]bool
	used_names.allocator = context.temp_allocator

	norm_pkg := clean_path(pkg_path)
	dep_map[norm_pkg] = strings.clone(pkg_name, context.temp_allocator)
	used_names[strings.clone(pkg_name, context.temp_allocator)] = true
	used_names["_hot_actod"] = true
	append(&deps, Build_Dep{real_path = norm_pkg, build_name = pkg_name})

	idx := 0
	for idx < len(deps) {
		dep := deps[idx]
		idx += 1

		import_paths := scan_relative_imports(dep.real_path)
		for import_path in import_paths {
			resolved := clean_path(join_path({dep.real_path, import_path}))
			if !os.is_dir(resolved) do continue
			if resolved in dep_map do continue

			base := filepath.base(resolved)
			name := strings.clone(base, context.temp_allocator)
			counter := 2
			for used_names[name] {
				name = fmt.aprintf("%s_%d", base, counter, allocator = context.temp_allocator)
				counter += 1
			}

			dep_map[resolved] = name
			used_names[name] = true
			append(&deps, Build_Dep{real_path = resolved, build_name = name})
		}
	}

	for dep in deps {
		dst_dir := join_path({build_root, dep.build_name})
		os.make_directory(dst_dir)

		if !copy_package_with_rewrites(dep.real_path, dst_dir, dep.build_name, dep_map) {
			return "", false
		}
	}

	return join_path({build_root, pkg_name}), true
}

@(private)
copy_package_with_rewrites :: proc(
	src_dir: string,
	dst_dir: string,
	build_name: string,
	dep_map: map[string]string,
) -> bool {
	fd, open_err := os.open(src_dir)
	if open_err != nil {
		log.errorf("hot reload: failed to open '%s': %v", src_dir, open_err)
		return false
	}
	entries, read_err := os.read_dir(fd, -1, context.temp_allocator)
	os.close(fd)
	if read_err != nil {
		log.errorf("hot reload: failed to read '%s': %v", src_dir, read_err)
		return false
	}

	norm_src := clean_path(src_dir)

	for entry in entries {
		if entry.type == .Directory do continue
		if !strings.has_suffix(entry.name, ".odin") do continue
		if entry.name == "hot_exports.odin" do continue

		src_path := join_path({src_dir, entry.name})
		src_data, src_err := os.read_entire_file(src_path, context.temp_allocator)
		if src_err != nil {
			log.errorf("hot reload: failed to read '%s': %v", src_path, src_err)
			return false
		}

		rewritten := rewrite_imports_in_source(string(src_data), norm_src, build_name, dep_map)
		rewritten = strip_init_procs(rewritten)
		dst_path := join_path({dst_dir, entry.name})
		if err := os.write_entire_file(dst_path, transmute([]u8)rewritten); err != nil {
			log.errorf("hot reload: failed to write '%s': %v", dst_path, err)
			return false
		}
	}

	return true
}

@(private)
scan_relative_imports :: proc(dir_path: string) -> []string {
	result: [dynamic]string
	result.allocator = context.temp_allocator

	fd, err := os.open(dir_path)
	if err != nil do return nil
	entries, read_err := os.read_dir(fd, -1, context.temp_allocator)
	os.close(fd)
	if read_err != nil do return nil

	for entry in entries {
		if entry.type == .Directory do continue
		if !strings.has_suffix(entry.name, ".odin") do continue

		src_path := join_path({dir_path, entry.name})
		data, file_err := os.read_entire_file(src_path, context.temp_allocator)
		if file_err != nil do continue

		source := string(data)
		rest := source
		for len(rest) > 0 {
			nl := strings.index_byte(rest, '\n')
			line: string
			if nl >= 0 {
				line = rest[:nl]
				rest = rest[nl + 1:]
			} else {
				line = rest
				rest = ""
			}

			import_path := extract_import_path(line)
			if import_path == "" do continue
			if is_core_or_base_import(import_path) do continue
			if is_actod_import_path(import_path) do continue

			already := false
			for existing in result {
				if existing == import_path {
					already = true
					break
				}
			}
			if !already do append(&result, import_path)
		}
	}

	return result[:]
}

@(private)
extract_import_path :: proc(line: string) -> string {
	trimmed := strings.trim_left(line, " \t")
	if !strings.has_prefix(trimmed, "import") do return ""

	after_import := trimmed[len("import"):]
	if len(after_import) == 0 || (after_import[0] != ' ' && after_import[0] != '\t') {
		return ""
	}

	quote_start := strings.index_byte(line, '"')
	if quote_start < 0 do return ""
	quote_end := strings.index_byte(line[quote_start + 1:], '"')
	if quote_end < 0 do return ""
	quote_end += quote_start + 1

	return line[quote_start + 1:quote_end]
}

@(private)
rewrite_imports_in_source :: proc(
	source: string,
	original_dir: string,
	build_name: string,
	dep_map: map[string]string,
) -> string {
	b := strings.builder_make(context.temp_allocator)
	pkg_rewritten := false

	rest := source
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line: string
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			line = rest
			rest = ""
		}

		output_line := line
		if !pkg_rewritten {
			trimmed := strings.trim_left(line, " \t")
			if strings.has_prefix(trimmed, "package ") {
				output_line = fmt.tprintf("package %s", build_name)
				pkg_rewritten = true
			}
		}

		if output_line == line {
			output_line = rewrite_import_line(line, original_dir, dep_map)
		}

		strings.write_string(&b, output_line)
		if nl >= 0 {
			strings.write_byte(&b, '\n')
		}
	}

	return strings.to_string(b)
}

@(private)
rewrite_import_line :: proc(
	line: string,
	original_dir: string,
	dep_map: map[string]string,
) -> string {
	import_path := extract_import_path(line)
	if import_path == "" do return line
	if is_core_or_base_import(import_path) do return line

	quote_start := strings.index_byte(line, '"')
	quote_end := strings.index_byte(line[quote_start + 1:], '"') + quote_start + 1

	new_path: string
	if is_actod_import_path(import_path) {
		new_path = "../_hot_actod"
	} else {
		resolved := clean_path(join_path({original_dir, import_path}))
		build_name, found := dep_map[resolved]
		if !found do return line
		new_path = fmt.tprintf("../%s", build_name)
	}

	orig_basename := filepath.base(import_path)
	new_basename := filepath.base(new_path)
	prefix := line[:quote_start]
	if orig_basename != new_basename && !has_explicit_alias(prefix) {
		trimmed_prefix := strings.trim_right(prefix, " \t")
		return strings.concatenate(
			{trimmed_prefix, " ", orig_basename, " \"", new_path, line[quote_end:]},
			context.temp_allocator,
		)
	}

	return strings.concatenate(
		{line[:quote_start + 1], new_path, line[quote_end:]},
		context.temp_allocator,
	)
}

@(private)
has_explicit_alias :: proc(prefix: string) -> bool {
	trimmed := strings.trim_right(prefix, " \t")
	if !strings.has_prefix(strings.trim_left(trimmed, " \t"), "import") do return false
	after := strings.trim_left(trimmed, " \t")
	after = strings.trim_prefix(after, "import")
	after = strings.trim(after, " \t")
	return len(after) > 0
}

@(private)
is_core_or_base_import :: proc(path: string) -> bool {
	return strings.has_prefix(path, "core:") || strings.has_prefix(path, "base:")
}

@(private)
strip_init_procs :: proc(source: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	lines := strings.split_lines(source, context.temp_allocator)

	skip_until_closing_brace := false
	brace_depth := 0
	skip_next_decl := false

	for line in lines {
		trimmed := strings.trim_space(line)

		if skip_until_closing_brace {
			for c in line {
				if c == '{' do brace_depth += 1
				if c == '}' {
					brace_depth -= 1
					if brace_depth <= 0 {
						skip_until_closing_brace = false
						break
					}
				}
			}
			continue
		}

		if trimmed == "@(init)" {
			skip_next_decl = true
			continue
		}

		if skip_next_decl {
			skip_next_decl = false
			for c in line {
				if c == '{' do brace_depth += 1
			}
			if brace_depth > 0 {
				skip_until_closing_brace = true
			}
			continue
		}

		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}

	return strings.to_string(sb)
}

@(private)
is_actod_import_path :: proc(path: string) -> bool {
	if path == "actod" do return true
	if strings.has_suffix(path, "/actod") do return true
	if strings.has_suffix(path, "\\actod") do return true
	if strings.has_prefix(path, "act:") do return true
	// A relative path of only ".." segments (e.g. "../../..") points to the actod root.
	// Paths with named segments (e.g. "../../messages") are sibling packages, not actod.
	clean := clean_path(path)
	base := filepath.base(clean)
	if base == ".." do return true
	return false
}

@(private)
join_path :: proc(elems: []string) -> string {
	result, _ := filepath.join(elems, context.temp_allocator)
	return result
}

@(private)
clean_path :: proc(path: string) -> string {
	result, err := filepath.clean(path, context.temp_allocator)
	return result if err == nil else path
}

@(private)
handle_file_changed :: proc(data: ^Hot_Reload_Actor_Data, pkg_path: string) {
	actor_names, pkg_exists := data.package_actors[pkg_path]
	if !pkg_exists || len(actor_names) == 0 {
		log.warnf("hot reload: file changed in unregistered package '%s'", pkg_path)
		return
	}

	first_meta := data.actor_meta[actor_names[0]]
	pkg_name := first_meta.package_name

	log.infof("hot reload: reloading '%s'", pkg_name)

	for name in actor_names {
		meta, exists := &data.actor_meta[name]
		if !exists do continue

		state_exp := hot_reload.State_Expectation {
			name        = meta.state_type_name,
			field_names = meta.state_field_names[:],
			field_types = meta.state_field_types[:],
			size        = meta.state_size,
		}

		proc_exps: [dynamic]hot_reload.Proc_Expectation
		defer delete(proc_exps)
		for field_name in meta.behaviour_field_names {
			append(
				&proc_exps,
				hot_reload.Proc_Expectation {
					name = field_name,
					required = field_name == "handle_message",
				},
			)
		}

		validation := hot_reload.validate_package(pkg_path, state_exp, proc_exps[:])
		if !validation.ok {
			for err in validation.errors {
				log.errorf("%s", hot_reload.format_validation_error(err, name))
			}
			hot_reload.destroy_validation_result(validation)
			return
		}
		delete(validation.errors)
	}

	build_pkg_path, build_ok := prepare_build_dir(pkg_path, pkg_name)
	if !build_ok {
		log.errorf("hot reload: failed to prepare build dir for '%s'", pkg_path)
		return
	}

	regenerate_exports(data, pkg_path, pkg_name, output_dir = build_pkg_path)

	data.generation += 1
	gen := data.generation

	so_path := join_path(
		{pkg_path, "tmp", fmt.tprintf("%s_gen%d%s", pkg_name, gen, hot_reload.SHARED_LIB_EXT)},
	)
	log.debugf("hot reload: compiling '%s' -> '%s'", build_pkg_path, so_path)
	compile_result := hot_reload.compile_module(build_pkg_path, so_path)
	if !compile_result.ok {
		log.errorf("hot reload: compile failed for '%s': %s", pkg_path, compile_result.error_msg)
		return
	}

	for name in actor_names {
		meta, exists := &data.actor_meta[name]
		if !exists do continue

		data.generation += 1
		actor_gen := data.generation

		specs: [dynamic]hot_reload.Symbol_Spec
		specs.allocator = context.temp_allocator
		for field_name in meta.behaviour_field_names {
			append(&specs, hot_reload.Symbol_Spec{name = field_name, required = false})
		}

		mod, load_err := hot_reload.load_module(
			so_path,
			specs[:],
			meta.state_size,
			actor_gen,
			state_type_prefix = meta.state_type_name,
		)
		if load_err.kind != .None {
			log.errorf(
				"hot reload: load failed for '%s': %s",
				name,
				hot_reload.load_error_message(load_err),
			)
			continue
		}

		populate_hot_api(mod.lib)
		sync.rw_mutex_lock(&hot_module_table_mu)
		hot_module_table[actor_gen] = mod
		sync.rw_mutex_unlock(&hot_module_table_mu)

		if cur_mod, has_cur := data.modules[name]; has_cur {
			if name not_in data.prev_modules {
				data.prev_modules[name] = {}
			}
			prev := &data.prev_modules[name]
			append(prev, cur_mod)
			for len(prev) > 3 {
				old_mod := prev[0]
				old_so := strings.clone(old_mod.path, context.temp_allocator)
				ordered_remove(prev, 0)
				hot_reload.unload_module(old_mod)
				os.remove(old_so)
			}
		}
		data.modules[name] = mod

		live_pids: [dynamic]PID
		for pid in meta.actor_pids {
			if _, active := get(&global_registry, pid); active {
				err := send_reload_behaviour(pid, actor_gen)
				if err == .OK {
					append(&live_pids, pid)
				}
			}
		}

		if len(live_pids) != len(meta.actor_pids) {
			delete(meta.actor_pids)
			meta.actor_pids = live_pids
		} else {
			delete(live_pids)
		}

		log.infof(
			"hot reload: reloaded '%s' (generation %d, %d actors)",
			name,
			actor_gen,
			len(meta.actor_pids),
		)
	}
}

register_for_hot_reload :: proc($T: typeid, pid: PID, name: string) {
	if !SYSTEM_CONFIG.hot_reload_dev || is_system_actod_pid(pid) || name == get_local_node_name() do return

	msg: Register_Hot_Actor
	msg.pid = pid

	name_len := min(len(name), 64)
	for j in 0 ..< name_len {
		msg.actor_name[j] = name[j]
	}
	msg.actor_name_len = name_len

	behaviour_ti := type_info_of(Actor_Behaviour(T))
	if named, ok := behaviour_ti.variant.(runtime.Type_Info_Named); ok {
		if st, sok := named.base.variant.(runtime.Type_Info_Struct); sok {
			field_idx := 0
			for field_name in st.names[:st.field_count] {
				if field_name == "actor_type" do continue
				if field_idx >= MAX_BEHAVIOUR_FIELDS do break

				slen := min(len(field_name), 64)
				for j in 0 ..< slen {
					msg.field_names[field_idx][j] = field_name[j]
				}
				msg.field_name_lens[field_idx] = slen
				field_idx += 1
			}
			msg.field_count = field_idx
		}
	}

	state_ti := type_info_of(T)
	if named, ok := state_ti.variant.(runtime.Type_Info_Named); ok {
		sname := named.name
		slen := min(len(sname), 64)
		for j in 0 ..< slen {
			msg.state_type_name[j] = sname[j]
		}
		msg.state_type_len = slen

		pkg := named.pkg
		plen := min(len(pkg), 64)
		for j in 0 ..< plen {
			msg.package_name[j] = pkg[j]
		}
		msg.package_name_len = plen

		if st, sok := named.base.variant.(runtime.Type_Info_Struct); sok {
			field_count := min(int(st.field_count), MAX_STATE_FIELDS)
			for idx in 0 ..< field_count {
				fname := st.names[idx]
				flen := min(len(fname), 64)
				for j in 0 ..< flen {
					msg.state_field_names[idx][j] = fname[j]
				}
				msg.state_field_lens[idx] = flen

				type_str := type_info_to_string(st.types[idx])
				tlen := min(len(type_str), 64)
				for j in 0 ..< tlen {
					msg.state_field_types[idx][j] = type_str[j]
				}
				msg.state_field_type_lens[idx] = tlen
			}
			msg.state_field_count = field_count
		}
	}

	msg.state_size = size_of(T)

	send_message(HOT_RELOAD_PID, msg)
}

@(private)
type_info_to_string :: proc(ti: ^runtime.Type_Info) -> string {
	if ti == nil do return "?"

	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return v.name
	case runtime.Type_Info_Integer:
		signed := v.signed
		switch ti.size {
		case 1:
			return "u8" if !signed else "i8"
		case 2:
			return "u16" if !signed else "i16"
		case 4:
			return "u32" if !signed else "i32"
		case 8:
			return "u64" if !signed else "i64"
		}
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			return "f32"
		case 8:
			return "f64"
		}
	case runtime.Type_Info_Boolean:
		return "bool"
	case runtime.Type_Info_String:
		return "string"
	case runtime.Type_Info_Pointer:
		return fmt.tprintf("^%s", type_info_to_string(v.elem))
	case runtime.Type_Info_Array:
		return fmt.tprintf("[%d]%s", v.count, type_info_to_string(v.elem))
	case runtime.Type_Info_Slice:
		return fmt.tprintf("[]%s", type_info_to_string(v.elem))
	case runtime.Type_Info_Dynamic_Array:
		return fmt.tprintf("[dynamic]%s", type_info_to_string(v.elem))
	case runtime.Type_Info_Map:
		return fmt.tprintf("map[%s]%s", type_info_to_string(v.key), type_info_to_string(v.value))
	}

	return "?"
}
