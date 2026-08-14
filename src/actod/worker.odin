package actod

import "../pkgs/coro"
import "../pkgs/threads_act"
import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"

WORKER_SPIN_TRIES :: 128

Pooled_Actor_Handle :: struct #align (CACHE_LINE_SIZE) {
	co:               ^coro.Coro,
	actor_ctx:        ^Actor_Context,
	file_logger:      ^Actor_File_Logger,
	actor_ptr:        rawptr,
	mailbox:          ^ACTOR_MAILBOX,
	system_mailbox:   ^MPSC_Queue(Message, SYSTEM_MAILBOX_SIZE),
	home_worker:      ^Worker,
	coro_slot:        u32,
	wants_reschedule: bool,
	transport_parked: bool,
	_pad0:            [2]byte,
	in_ready_queue:   bool,
	_pad1:            [CACHE_LINE_SIZE - 1]byte,
	main_fn:          proc(_: rawptr),
	resume_fn:        proc(_: rawptr),
	allocator:        mem.Allocator,
	logger:           log.Logger,
	msg_ctx:          rawptr,
	next_ready:       ^Pooled_Actor_Handle,
	coro_stack:       uint,
	started_once:     bool,
	parked_cold:      bool,
	terminated:       bool,
}

#assert(offset_of(Pooled_Actor_Handle, in_ready_queue) % CACHE_LINE_SIZE == 0)

Worker :: struct #align (CACHE_LINE_SIZE) {
	id:          int,
	thread:      ^thread.Thread,
	runnext:     ^Pooled_Actor_Handle,
	running:     bool,
	_pad0:       [CACHE_LINE_SIZE - size_of(int) - size_of(rawptr) - size_of(rawptr) - size_of(bool)]byte,
	wake_sema:   sync.Atomic_Sema,
	parked:      bool,
	_pad1:       [CACHE_LINE_SIZE - size_of(sync.Atomic_Sema) - size_of(bool)]byte,
	ready_head:  ^Pooled_Actor_Handle,
	ready_local: ^Pooled_Actor_Handle,
}

@(private)
ready_push :: proc(w: ^Worker, handle: ^Pooled_Actor_Handle) {
	for {
		head := sync.atomic_load_explicit(&w.ready_head, .Relaxed)
		handle.next_ready = head
		if _, swapped := sync.atomic_compare_exchange_weak_explicit(
			&w.ready_head,
			head,
			handle,
			.Release,
			.Relaxed,
		); swapped {
			return
		}
	}
}

@(private)
ready_pop :: proc(w: ^Worker) -> ^Pooled_Actor_Handle {
	if w.ready_local == nil {
		batch := sync.atomic_exchange_explicit(&w.ready_head, nil, .Acquire)
		if batch == nil {
			return nil
		}
		reversed: ^Pooled_Actor_Handle
		for node := batch; node != nil; {
			next := node.next_ready
			node.next_ready = reversed
			reversed = node
			node = next
		}
		w.ready_local = reversed
	}

	handle := w.ready_local
	w.ready_local = handle.next_ready
	handle.next_ready = nil
	return handle
}

@(private)
ready_is_empty :: #force_inline proc(w: ^Worker) -> bool {
	return w.ready_local == nil && sync.atomic_load_explicit(&w.ready_head, .Acquire) == nil
}

Worker_Pool :: struct {
	workers:      []Worker,
	worker_count: int,
	next_worker:  int,
	sim_cursor:   int,
	initialized:  bool,
}


@(thread_local)
current_worker: ^Worker

init_worker_pool :: proc(count: int) {
	if count <= 0 do return

	NODE.worker_pool.workers = make([]Worker, count, get_system_allocator())
	NODE.worker_pool.worker_count = count

	for i in 0 ..< count {
		w := &NODE.worker_pool.workers[i]
		w.id = i
		w.ready_head = nil
		w.ready_local = nil
		sync.atomic_store(&w.running, true)

		if !NODE.config.sim_mode {
			w.thread = threads_act.create_thread_with_stack_size(w, proc(data: rawptr) {
					worker_loop(cast(^Worker)data)
				}, 128 * 1024)
			threads_act.set_thread_affinity(w.thread, i)
		}
	}

	NODE.worker_pool.initialized = true
}

shutdown_worker_pool :: proc() {
	if !NODE.worker_pool.initialized do return

	for i in 0 ..< NODE.worker_pool.worker_count {
		sync.atomic_store(&NODE.worker_pool.workers[i].running, false)
		sync.atomic_sema_post(&NODE.worker_pool.workers[i].wake_sema)
	}

	for i in 0 ..< NODE.worker_pool.worker_count {
		w := &NODE.worker_pool.workers[i]
		if w.thread != nil {
			thread.join(w.thread)
			thread.destroy(w.thread)
			w.thread = nil
		}
	}

	delete(NODE.worker_pool.workers, actor_system_allocator)
	NODE.worker_pool = {}
}

wake_pooled_actor :: proc(handle: ^Pooled_Actor_Handle) {
	if handle.home_worker != current_worker {
		sync.atomic_thread_fence(.Seq_Cst)
	}
	if sync.atomic_load_explicit(&handle.in_ready_queue, .Relaxed) do return
	_, ok := sync.atomic_compare_exchange_strong(&handle.in_ready_queue, false, true)
	if ok {
		w := handle.home_worker
		if w == current_worker {
			if w.runnext != nil {
				ready_push(w, w.runnext)
			}
			w.runnext = handle
		} else {
			ready_push(w, handle)

			sync.atomic_thread_fence(.Seq_Cst)
			if sync.atomic_load_explicit(&w.parked, .Relaxed) {
				sync.atomic_sema_post(&w.wake_sema)
			}
		}
	}
}

@(private)
coro_entry :: proc(co: ^coro.Coro) {
	handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
	if handle.started_once {
		handle.resume_fn(handle.actor_ptr)
		return
	}
	handle.started_once = true
	handle.main_fn(handle.actor_ptr)
}

@(private)
handle_acquire_coro :: proc(handle: ^Pooled_Actor_Handle) -> bool {
	desc := coro.desc_init(coro_entry, handle.coro_stack)
	desc.user_data = handle
	co, res := coro_acquire(&desc, &handle.coro_slot, handle.coro_stack)
	if res != .Success {
		return false
	}
	handle.co = co
	return true
}

@(private)
worker_resume_handle :: proc(worker: ^Worker, handle: ^Pooled_Actor_Handle) {
	current_actor_context = handle.actor_ctx
	current_actor_file_logger = handle.file_logger

	if handle.co == nil && !handle_acquire_coro(handle) {
		log.errorf("could not reacquire a coroutine stack to wake a parked actor")
		sync.atomic_store_explicit(&handle.in_ready_queue, false, .Release)
		current_actor_context = nil
		current_actor_file_logger = nil
		return
	}

	reclaim_pin()

	coro.resume_top_level(handle.co)

	current_actor_context = nil
	current_actor_file_logger = nil

	if handle.parked_cold {
		handle.parked_cold = false
		coro_release(handle.co, &handle.coro_slot, false)
		handle.co = nil
	} else if coro.status(handle.co) == .Dead {
		if tls_reclaim_depth > 0 {
			reclaim_unpin()
		}
		sync.atomic_store_explicit(&handle.terminated, true, .Release)
		return
	}

	if handle.transport_parked {
		sync.atomic_store_explicit(&handle.in_ready_queue, false, .Release)
	} else if handle.wants_reschedule || has_pending_messages(handle) {
		handle.wants_reschedule = false
		ready_push(worker, handle)
	} else {
		sync.atomic_store_explicit(&handle.in_ready_queue, false, .Release)
		sync.atomic_thread_fence(.Seq_Cst)
		reschedule := has_pending_messages(handle)
		if !reschedule {
			if worker.runnext == nil && ready_is_empty(worker) {
				for _ in 0 ..< 8 {
					intrinsics.cpu_relax()
				}
			}
			reschedule = has_pending_messages(handle)
		}
		if reschedule {
			_, ok := sync.atomic_compare_exchange_strong(&handle.in_ready_queue, false, true)
			if ok {
				ready_push(worker, handle)
			}
		}
	}

	if tls_reclaim_depth > 0 {
		reclaim_unpin()
	}
}

@(private)
worker_loop :: proc(worker: ^Worker) {
	current_worker = worker

	for sync.atomic_load(&worker.running) {
		if worker.runnext != nil {
			handle := worker.runnext
			worker.runnext = nil
			worker_resume_handle(worker, handle)
			worker_flush_staging()
			continue
		}

		if handle := ready_pop(worker); handle != nil {
			worker_resume_handle(worker, handle)
			worker_flush_staging()
			continue
		}

		for _ in 0 ..< WORKER_SPIN_TRIES {
			intrinsics.cpu_relax()
			if worker.runnext != nil do break
			if handle := ready_pop(worker); handle != nil {
				worker_resume_handle(worker, handle)
				worker_flush_staging()
				break
			}
		}

		if worker.runnext != nil do continue

		reclaim_scan()

		when ACTOD_NET_STAGING {
			if !staging_flush_before_park() do continue
		}

		sync.atomic_store_explicit(&worker.parked, true, .Relaxed)
		sync.atomic_thread_fence(.Seq_Cst)
		if worker.runnext == nil && ready_is_empty(worker) {
			sync.atomic_sema_wait(&worker.wake_sema)
		}
		sync.atomic_store_explicit(&worker.parked, false, .Relaxed)
	}

	when ACTOD_NET_STAGING {
		_ = staging_flush_before_park()
	}
}

@(private)
worker_flush_staging :: #force_inline proc() {
	when ACTOD_NET_STAGING {
		if staging_has_pending() {
			_ = staging_flush_all()
		}
	}
}

@(private)
has_pending_messages :: #force_inline proc(handle: ^Pooled_Actor_Handle) -> bool {
	actor := cast(^Actor(int))handle.actor_ptr
	if actor.local_read != actor.local_write do return true
	if sync.atomic_load_explicit(&actor.stopped_head, .Relaxed) != nil do return true
	if !mpsc_is_empty(handle.mailbox) do return true
	return !mpsc_is_empty(handle.system_mailbox)
}
