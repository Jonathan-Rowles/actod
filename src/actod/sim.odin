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
	if g_sim_trace_ready {
		builtin.clear(&g_sim_trace)
	}
}

sim_trace_events :: proc() -> []Sim_Trace_Event {
	if !g_sim_trace_ready {
		return nil
	}
	return g_sim_trace[:]
}

sim_trace_record :: #force_inline proc(kind: Sim_Trace_Kind, a: u64, b: u64) {
	if !g_sim_trace_enabled {
		return
	}
	append(&g_sim_trace, Sim_Trace_Event{kind = kind, a = a, b = b})
}

@(private = "file")
sim_rng: u64

sim_seed :: proc(seed: u64) {
	sim_rng = seed
}

@(private = "file")
sim_rand :: proc() -> u64 {
	sim_rng = sim_rng * 6364136223846793005 + 1442695040888963407
	return sim_rng >> 33
}

@(private = "file")
sim_worker_has_work :: proc(w: ^Worker) -> bool {
	return w.runnext != nil || mpsc_size(&w.ready_queue) > 0
}

@(private = "file")
sim_resume_next :: proc(w: ^Worker) {
	current_worker = w
	handle: ^Pooled_Actor_Handle
	if w.runnext != nil {
		handle = w.runnext
		w.runnext = nil
	} else {
		raw: rawptr
		if !mpsc_pop(&w.ready_queue, &raw) {
			return
		}
		handle = cast(^Pooled_Actor_Handle)raw
	}
	sim_trace_record(.Actor_Resume, u64(w.id), u64((cast(^Actor(int))handle.actor_ptr).pid))
	worker_resume_handle(w, handle)
}

sim_create_node :: proc() -> ^Node_State {
	node := new(Node_State, get_system_allocator())
	node.reclaim.epoch = 1
	node.node_id = 1
	node.next_node_id = 2
	node.config = DEFAULT_SYSTEM_CONFIG
	return node
}

sim_bind_node :: proc(node: ^Node_State) -> ^Node_State {
	previous := NODE
	NODE = node
	return previous
}

sim_destroy_node :: proc(node: ^Node_State) {
	free(node, get_system_allocator())
}

sim_pump :: proc() -> bool {
	if !NODE.config.sim_mode || !NODE.worker_pool.initialized {
		return false
	}

	previous_worker := current_worker
	defer current_worker = previous_worker

	fired := fire_due_timers() > 0
	io_progress := sim_service_transport()

	pool := &NODE.worker_pool

	if sim_rng != 0 {
		ready_count := 0
		for i in 0 ..< pool.worker_count {
			if sim_worker_has_work(&pool.workers[i]) {
				ready_count += 1
			}
		}
		if ready_count == 0 {
			return fired || io_progress
		}
		pick := int(sim_rand() % u64(ready_count))
		for i in 0 ..< pool.worker_count {
			w := &pool.workers[i]
			if !sim_worker_has_work(w) {
				continue
			}
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
