package actod

import "base:intrinsics"
import "core:encoding/endian"
import "core:sync"
import "core:testing"
import "core:thread"

SEQ_FRAME_SIZE :: 20
SEQ_MAX_THREADS :: 16

Seq_Drainer_Context :: struct {
	ring:             ^Connection_Ring,
	stop:             bool,
	frames_seen:      int,
	order_violations: int,
	malformed:        int,
	next_seq:         [SEQ_MAX_THREADS]u64,
}

seq_validate_slot :: proc(ctx: ^Seq_Drainer_Context, data: []byte, length: u32) {
	offset: u32 = 0
	for offset + 4 <= length {
		body := endian.unchecked_get_u32le(data[offset:])
		if body == 0 || offset + 4 + body > length {
			ctx.malformed += 1
			return
		}
		payload := data[offset + 4:offset + 4 + body]
		if len(payload) >= 12 {
			producer := int(payload[0])
			seq := endian.unchecked_get_u64le(payload[4:])
			if producer < SEQ_MAX_THREADS {
				if seq != ctx.next_seq[producer] {
					ctx.order_violations += 1
				}
				ctx.next_seq[producer] = seq + 1
			}
			ctx.frames_seen += 1
		} else {
			ctx.malformed += 1
		}
		offset += 4 + body
	}
	if offset != length {
		ctx.malformed += 1
	}
}

seq_drain_ready :: proc(ctx: ^Seq_Drainer_Context) -> int {
	ring := ctx.ring
	recycled := 0
	write_idx := sync.atomic_load(&ring.send_write_idx)
	for ring.send_submit_idx < write_idx {
		slot_idx := ring.send_submit_idx & ring.send_mask
		slot := &ring.send_slots[slot_idx]
		if sync.atomic_load(&slot.state) != .READY {
			break
		}
		seq_validate_slot(ctx, slot_data(ring, slot_idx), slot.length)
		slot.length = 0
		sync.atomic_store(&slot.state, .FREE)
		ring.send_submit_idx += 1
		recycled += 1
	}
	if recycled > 0 {
		sync.atomic_add(&ring.send_complete_idx, u32(recycled))
	}
	return recycled
}

seq_drainer_proc :: proc(data: rawptr) {
	ctx := cast(^Seq_Drainer_Context)data
	for !sync.atomic_load(&ctx.stop) {
		if sync.atomic_exchange(&ctx.ring.batch_pending, 0) != 0 {
			batch_flush(ctx.ring)
		}
		seq_drain_ready(ctx)
		for _ in 0 ..< 500 {
			intrinsics.cpu_relax()
		}
	}
	batch_flush(ctx.ring)
	seq_drain_ready(ctx)
}

Seq_Writer_Context :: struct {
	ring:      ^Connection_Ring,
	msg_count: int,
	thread_id: u8,
	sent:      int,
	failures:  int,
}

seq_writer_proc :: proc(data: rawptr) {
	ctx := cast(^Seq_Writer_Context)data
	msg: [SEQ_FRAME_SIZE]byte
	endian.put_u32(msg[0:4], .Little, SEQ_FRAME_SIZE - 4)
	msg[4] = ctx.thread_id

	for seq in 0 ..< ctx.msg_count {
		endian.put_u64(msg[8:16], .Little, u64(seq))
		retries := 0
		delivered := false
		for !batch_append_message(ctx.ring, msg[:]) {
			retries += 1
			if retries > 1_000_000 {
				break
			}
			if retries % 64 == 0 {
				thread.yield()
			} else {
				intrinsics.cpu_relax()
			}
		}
		delivered = retries <= 1_000_000
		if delivered {
			ctx.sent += 1
		} else {
			ctx.failures += 1
		}
	}
}

@(test)
test_stress_per_producer_order :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 50_000

	drainer_ctx := Seq_Drainer_Context {
		ring = ring,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, seq_drainer_proc)

	ctxs: [num_threads]Seq_Writer_Context
	threads: [num_threads]^thread.Thread
	for i in 0 ..< num_threads {
		ctxs[i] = Seq_Writer_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			thread_id = u8(i),
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], seq_writer_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		testing.expect_value(t, ctxs[i].failures, 0)
	}

	testing.expect_value(t, drainer_ctx.order_violations, 0)
	testing.expect_value(t, drainer_ctx.malformed, 0)
	testing.expect_value(t, drainer_ctx.frames_seen, total_sent)
	for i in 0 ..< num_threads {
		testing.expect_value(t, drainer_ctx.next_seq[i], u64(ctxs[i].sent))
	}
}

seq_staged_writer_proc :: proc(data: rawptr) {
	ctx := cast(^Seq_Writer_Context)data
	fake_worker: Worker
	fake_worker.id = int(ctx.thread_id)
	current_worker = &fake_worker
	defer {
		for !staging_flush_all() {
			intrinsics.cpu_relax()
		}
		current_worker = nil
	}

	small: [SEQ_FRAME_SIZE]byte
	endian.put_u32(small[0:4], .Little, SEQ_FRAME_SIZE - 4)
	small[4] = ctx.thread_id

	LARGE_FRAME_SIZE :: STAGE_FRAME_MAX + 64
	large: [LARGE_FRAME_SIZE]byte
	endian.put_u32(large[0:4], .Little, LARGE_FRAME_SIZE - 4)
	large[4] = ctx.thread_id

	for seq in 0 ..< ctx.msg_count {
		use_large := seq % 97 == 0
		frame := use_large ? large[:] : small[:]
		endian.put_u64(frame[8:16], .Little, u64(seq))

		retries := 0
		ok := false
		for retries <= 1_000_000 {
			if use_large {
				if staging_flush_ring(ctx.ring) && batch_append_message(ctx.ring, frame) {
					ok = true
					break
				}
			} else {
				if dst, staged := staging_reserve(ctx.ring, u32(len(frame))); staged {
					copy(dst, frame)
					ok = true
					break
				}
			}
			retries += 1
			if retries % 64 == 0 {
				thread.yield()
			} else {
				intrinsics.cpu_relax()
			}
		}
		if ok {
			ctx.sent += 1
		} else {
			ctx.failures += 1
		}

		if seq % 233 == 0 {
			for !staging_flush_all() {
				intrinsics.cpu_relax()
			}
		}
	}
}

@(test)
test_stress_staged_per_producer_order :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 50_000

	drainer_ctx := Seq_Drainer_Context {
		ring = ring,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, seq_drainer_proc)

	ctxs: [num_threads]Seq_Writer_Context
	threads: [num_threads]^thread.Thread
	for i in 0 ..< num_threads {
		ctxs[i] = Seq_Writer_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			thread_id = u8(i),
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], seq_staged_writer_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		testing.expect_value(t, ctxs[i].failures, 0)
	}

	testing.expect_value(t, drainer_ctx.order_violations, 0)
	testing.expect_value(t, drainer_ctx.malformed, 0)
	testing.expect_value(t, drainer_ctx.frames_seen, total_sent)
	for i in 0 ..< num_threads {
		testing.expect_value(t, drainer_ctx.next_seq[i], u64(ctxs[i].sent))
	}
}
