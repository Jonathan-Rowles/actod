package actod

import "../pkgs/coro"
import "../pkgs/threads_act"
import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"

WORKER_READY_QUEUE_SIZE :: 512
WORKER_SPIN_TRIES :: 128

Pooled_Actor_Handle :: struct #align (CACHE_LINE_SIZE) {
	co:               ^coro.Coro,
	actor_ctx:        ^Actor_Context,
	file_logger:      ^Actor_File_Logger,
	actor_ptr:        rawptr,
	mailbox:          ^ACTOR_MAILBOX,
	system_mailbox:   ^MPSC_Queue(Message, SYSTEM_MAILBOX_SIZE),
	home_worker:      ^Worker,
	wants_reschedule: bool,
	_pad0:            [7]byte,
	in_ready_queue:   bool,
	_pad1:            [CACHE_LINE_SIZE - 1]byte,
	main_fn:          proc(_: rawptr),
	allocator:        mem.Allocator,
	logger:           log.Logger,
	msg_ctx:          rawptr,
}

Worker :: struct #align (CACHE_LINE_SIZE) {
	id:          int,
	thread:      ^thread.Thread,
	wake_sema:   sync.Atomic_Sema,
	runnext:     ^Pooled_Actor_Handle, // only accessed by this worker's thread
	ready_queue: MPSC_Queue(rawptr, WORKER_READY_QUEUE_SIZE),
	running:     bool,
}

Worker_Pool :: struct {
	workers:      []Worker,
	worker_count: int,
	next_worker:  int,
	initialized:  bool,
}

worker_pool: Worker_Pool

@(thread_local)
current_worker: ^Worker

init_worker_pool :: proc(count: int) {
	if count <= 0 do return

	worker_pool.workers = make([]Worker, count, actor_system_allocator)
	worker_pool.worker_count = count

	for i in 0 ..< count {
		w := &worker_pool.workers[i]
		w.id = i
		init_mpsc(&w.ready_queue)
		sync.atomic_store(&w.running, true)

		w.thread = threads_act.create_thread_with_stack_size(w, proc(data: rawptr) {
				worker_loop(cast(^Worker)data)
			}, 128 * 1024)
		threads_act.set_thread_affinity(w.thread, i)
	}

	worker_pool.initialized = true
}

shutdown_worker_pool :: proc() {
	if !worker_pool.initialized do return

	for i in 0 ..< worker_pool.worker_count {
		sync.atomic_store(&worker_pool.workers[i].running, false)
		sync.atomic_sema_post(&worker_pool.workers[i].wake_sema)
	}

	for i in 0 ..< worker_pool.worker_count {
		w := &worker_pool.workers[i]
		if w.thread != nil {
			thread.join(w.thread)
			thread.destroy(w.thread)
			w.thread = nil
		}
	}

	delete(worker_pool.workers, actor_system_allocator)
	worker_pool = {}
}

wake_pooled_actor :: proc(handle: ^Pooled_Actor_Handle) {
	if sync.atomic_load_explicit(&handle.in_ready_queue, .Relaxed) do return
	_, ok := sync.atomic_compare_exchange_strong(&handle.in_ready_queue, false, true)
	if ok {
		w := handle.home_worker
		if w == current_worker {
			if w.runnext != nil {
				mpsc_push(&w.ready_queue, rawptr(w.runnext))
			}
			w.runnext = handle
		} else {
			mpsc_push(&w.ready_queue, rawptr(handle))
			sync.atomic_sema_post(&w.wake_sema)
		}
	}
}

@(private)
coro_entry :: proc(co: ^coro.Coro) {
	handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
	handle.main_fn(handle.actor_ptr)
}

@(private)
worker_resume_handle :: proc(worker: ^Worker, handle: ^Pooled_Actor_Handle) {
	current_actor_context = handle.actor_ctx
	current_actor_file_logger = handle.file_logger

	coro.resume_top_level(handle.co)

	if coro.status(handle.co) == .Dead {
	} else if handle.wants_reschedule || has_pending_messages(handle) {
		handle.wants_reschedule = false
		mpsc_push(&worker.ready_queue, rawptr(handle))
	} else {
		sync.atomic_store_explicit(&handle.in_ready_queue, false, .Release)
		sync.atomic_thread_fence(.Acq_Rel)
		reschedule := has_pending_messages(handle)
		if !reschedule {
			for _ in 0 ..< 8 {
				intrinsics.cpu_relax()
			}
			reschedule = has_pending_messages(handle)
		}
		if reschedule {
			_, ok := sync.atomic_compare_exchange_strong(&handle.in_ready_queue, false, true)
			if ok {
				mpsc_push(&worker.ready_queue, rawptr(handle))
			}
		}
	}
}

@(private)
worker_loop :: proc(worker: ^Worker) {
	current_worker = worker
	raw: rawptr

	for sync.atomic_load(&worker.running) {
		if worker.runnext != nil {
			handle := worker.runnext
			worker.runnext = nil
			worker_resume_handle(worker, handle)
			continue
		}

		if mpsc_pop(&worker.ready_queue, &raw) {
			worker_resume_handle(worker, cast(^Pooled_Actor_Handle)raw)
			continue
		}

		for _ in 0 ..< WORKER_SPIN_TRIES {
			intrinsics.cpu_relax()
			if worker.runnext != nil do break
			if mpsc_pop(&worker.ready_queue, &raw) {
				worker_resume_handle(worker, cast(^Pooled_Actor_Handle)raw)
				break
			}
		}

		if worker.runnext == nil {
			sync.atomic_sema_wait(&worker.wake_sema)
		}
	}
}

@(private)
has_pending_messages :: #force_inline proc(handle: ^Pooled_Actor_Handle) -> bool {
	actor := cast(^Actor(int))handle.actor_ptr
	if actor.local_read != actor.local_write do return true
	for i in 0 ..< MAILBOX_PRIORITY_COUNT {
		if mpsc_size(&handle.mailbox[i]) > 0 do return true
	}
	return mpsc_size(handle.system_mailbox) > 0
}
