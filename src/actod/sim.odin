package actod

import "base:builtin"

Sim_Trace_Kind :: enum u8 {
	Node_Step,
	Actor_Resume,
	Timer_Fire,
	Wire_Deliver,
}

Sim_Trace_Event :: struct {
	kind: Sim_Trace_Kind,
	a:    u64,
	b:    u64,
}

@(private = "file")
g_sim_trace_enabled: bool
@(private = "file")
g_sim_trace_ready: bool
@(private = "file")
g_sim_trace: [dynamic]Sim_Trace_Event

sim_trace_enable :: proc(enabled: bool) {
	if enabled && !g_sim_trace_ready {
		g_sim_trace_ready = true
		g_sim_trace = make([dynamic]Sim_Trace_Event, get_system_allocator())
	}
	g_sim_trace_enabled = enabled
}

sim_trace_reset :: proc() {
	if g_sim_trace_ready do builtin.clear(&g_sim_trace)
}

sim_trace_events :: proc() -> []Sim_Trace_Event {
	if !g_sim_trace_ready do return nil
	return g_sim_trace[:]
}

sim_trace_record :: #force_inline proc(kind: Sim_Trace_Kind, a: u64, b: u64) {
	if !g_sim_trace_enabled do return
	append(&g_sim_trace, Sim_Trace_Event{kind = kind, a = a, b = b})
}

@(private = "file")
sim_rng: u64

sim_seed :: proc(seed: u64) {
	sim_rng = seed
}

lcg_next :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^ >> 33
}

@(private = "file")
sim_rand :: proc() -> u64 {
	return lcg_next(&sim_rng)
}

@(private = "file")
sim_worker_has_work :: proc(w: ^Worker) -> bool {
	return w.runnext != nil || !ready_is_empty(w)
}

@(private = "file")
sim_resume_next :: proc(w: ^Worker) {
	current_worker = w
	handle: ^Pooled_Actor_Handle
	if w.runnext != nil {
		handle = w.runnext
		w.runnext = nil
	} else {
		handle = ready_pop(w)
		if handle == nil do return
	}
	sim_trace_record(.Actor_Resume, u64(w.id), u64((cast(^Actor(int))handle.actor_ptr).pid))
	worker_resume_handle(w, handle)
	worker_flush_staging()
}

sim_create_node :: proc() -> ^Node_State {
	node := new(Node_State, get_system_allocator())
	node.reclaim.epoch = 1
	node.node_id = 1
	node.next_node_id = 2
	node_own_config_strings(node, DEFAULT_SYSTEM_CONFIG)
	return node
}

sim_bind_node :: proc(node: ^Node_State) -> ^Node_State {
	previous := NODE
	NODE = node
	return previous
}

sim_destroy_node :: proc(node: ^Node_State) {
	delete(node.name, get_system_allocator())
	delete(node.config.network.auth_password, get_system_allocator())
	delete(node.config.network.bind_address, get_system_allocator())
	free(node, get_system_allocator())
}

sim_pump :: proc() -> bool {
	if !NODE.config.sim_mode || !NODE.worker_pool.initialized do return false

	previous_worker := current_worker
	defer current_worker = previous_worker

	fired := fire_due_timers() > 0
	io_progress := sim_service_transport()

	pool := &NODE.worker_pool

	if sim_rng != 0 {
		ready_count := 0
		for i in 0 ..< pool.worker_count {
			if sim_worker_has_work(&pool.workers[i]) do ready_count += 1
		}
		if ready_count == 0 do return fired || io_progress
		pick := int(sim_rand() % u64(ready_count))
		for i in 0 ..< pool.worker_count {
			w := &pool.workers[i]
			if !sim_worker_has_work(w) do continue
			if pick == 0 {
				sim_resume_next(w)
				return true
			}
			pick -= 1
		}
		return fired || io_progress
	}

	for offset in 0 ..< pool.worker_count {
		i := (pool.sim_cursor + offset) % pool.worker_count
		w := &pool.workers[i]
		if sim_worker_has_work(w) {
			pool.sim_cursor = (i + 1) % pool.worker_count
			sim_resume_next(w)
			return true
		}
	}

	return fired || io_progress
}

sim_run_until_idle :: proc(max_steps: int = 1_000_000) -> int {
	steps := 0
	for steps < max_steps && sim_pump() {
		steps += 1
	}
	return steps
}
