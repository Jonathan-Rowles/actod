package actod

import "base:intrinsics"
import "core:encoding/endian"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

SEQ_FRAME_SIZE :: 20
SEQ_MAX_THREADS :: 16

SEQ_MAX_RECORDED_VIOLATIONS :: 8

Seq_Violation :: struct {
	producer:     int,
	expected:     u64,
	got:          u64,
	submit_idx:   u32,
	slot_idx:     u32,
	slot_length:  u32,
	frame_offset: u32,
	frames_seen:  int,
	seal_before:  u64,
	seal_after:   u64,
	sum_changed:  bool,
}

seq_slot_checksum :: proc(data: []byte, length: u32) -> u64 {
	sum: u64 = 1469598103934665603
	for i in 0 ..< length {
		sum = (sum ~ u64(data[i])) * 1099511628211
	}
	return sum
}

Seq_Drainer_Context :: struct {
	ring:             ^Connection_Ring,
	stop:             bool,
	starve_pause:     time.Duration,
	read_dwell:       time.Duration,
	frames_seen:      int,
	order_violations: int,
	malformed:        int,
	next_seq:         [SEQ_MAX_THREADS]u64,
	submit_idx:       u32,
	slot_idx:         u32,
	seal_before:      u64,
	seal_after:       u64,
	sum_changed:      bool,
	mutated_ready:    int,
	violations:       [SEQ_MAX_RECORDED_VIOLATIONS]Seq_Violation,
	recorded:         int,
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
					if ctx.recorded < SEQ_MAX_RECORDED_VIOLATIONS {
						ctx.violations[ctx.recorded] = Seq_Violation {
							producer     = producer,
							expected     = ctx.next_seq[producer],
							got          = seq,
							submit_idx   = ctx.submit_idx,
							slot_idx     = ctx.slot_idx,
							slot_length  = length,
							frame_offset = offset,
							frames_seen  = ctx.frames_seen,
							seal_before  = ctx.seal_before,
							seal_after   = ctx.seal_after,
							sum_changed  = ctx.sum_changed,
						}
						ctx.recorded += 1
					}
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
		ctx.submit_idx = ring.send_submit_idx
		ctx.slot_idx = slot_idx
		length := slot.length
		data := slot_data(ring, slot_idx)
		ctx.seal_before = sync.atomic_load(&slot.seal_id)
		if ctx.read_dwell > 0 do time.sleep(ctx.read_dwell)
		sum_before := seq_slot_checksum(data, length)
		ctx.sum_changed = false
		seq_validate_slot(ctx, data, length)
		ctx.seal_after = sync.atomic_load(&slot.seal_id)
		if seq_slot_checksum(data, length) != sum_before {
			ctx.sum_changed = true
			ctx.mutated_ready += 1
		}
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
		if ctx.starve_pause > 0 {
			time.sleep(ctx.starve_pause)
		} else {
			for _ in 0 ..< 500 {
				intrinsics.cpu_relax()
			}
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

run_seq_stress :: proc(
	t: ^testing.T,
	writer: proc(data: rawptr),
	starve_pause: time.Duration = 0,
	read_dwell: time.Duration = 0,
) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 50_000

	drainer_ctx := Seq_Drainer_Context {
		ring         = ring,
		starve_pause = starve_pause,
		read_dwell   = read_dwell,
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
		threads[i] = thread.create_and_start_with_data(&ctxs[i], writer)
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

	for i in 0 ..< drainer_ctx.recorded {
		v := drainer_ctx.violations[i]
		log.errorf(
			"seq violation %d: producer=%d expected=%d got=%d delta=%d submit_idx=%d slot_idx=%d slot_length=%d frame_offset=%d frames_seen=%d seal_before=%d seal_after=%d sum_changed=%v",
			i,
			v.producer,
			v.expected,
			v.got,
			i64(v.got) - i64(v.expected),
			v.submit_idx,
			v.slot_idx,
			v.slot_length,
			v.frame_offset,
			v.frames_seen,
			v.seal_before,
			v.seal_after,
			v.sum_changed,
		)
	}
	testing.expect_value(t, drainer_ctx.order_violations, 0)
	testing.expect_value(t, drainer_ctx.malformed, 0)
	testing.expect_value(t, drainer_ctx.frames_seen, total_sent)
	for i in 0 ..< num_threads {
		testing.expect_value(t, drainer_ctx.next_seq[i], u64(ctxs[i].sent))
	}
}

@(test)
test_stress_per_producer_order :: proc(t: ^testing.T) {
	run_seq_stress(t, seq_writer_proc)
}

@(test)
test_stress_per_producer_order_starved_drainer :: proc(t: ^testing.T) {
	run_seq_stress(
		t,
		seq_writer_proc,
		starve_pause = 3 * time.Millisecond,
		read_dwell = 500 * time.Microsecond,
	)
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
				if dst, _, staged := staging_reserve(ctx.ring, u32(len(frame)), 0); staged {
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
	run_seq_stress(t, seq_staged_writer_proc)
}

seq_fill_ring :: proc(ring: ^Connection_Ring, producer: u8, frames: int) -> int {
	msg: [SEQ_FRAME_SIZE]byte
	endian.put_u32(msg[0:4], .Little, SEQ_FRAME_SIZE - 4)
	msg[4] = producer

	appended := 0
	for seq in 0 ..< frames {
		endian.put_u64(msg[8:16], .Little, u64(seq))
		if !batch_append_message(ring, msg[:]) do break
		appended += 1
	}
	return appended
}

@(test)
test_migrate_preserves_buffered_frames :: proc(t: ^testing.T) {
	loser := make_test_ring(16, 4096)
	survivor := make_test_ring(16, 4096)
	testing.expect(t, loser != nil, "Loser ring should be created")
	testing.expect(t, survivor != nil, "Survivor ring should be created")
	defer destroy_connection_ring(loser)
	defer destroy_connection_ring(survivor)

	FRAMES :: 1000
	testing.expect_value(t, seq_fill_ring(loser, 0, FRAMES), FRAMES)

	migrated := ring_migrate_slots(loser, survivor)
	testing.expect(t, migrated > 0, "Migration should move at least one slot")

	batch_flush(survivor)

	survivor_ctx := Seq_Drainer_Context {
		ring = survivor,
	}
	seq_drain_ready(&survivor_ctx)

	testing.expect_value(t, survivor_ctx.malformed, 0)
	testing.expect_value(t, survivor_ctx.order_violations, 0)
	testing.expect_value(t, survivor_ctx.frames_seen, FRAMES)
	testing.expect_value(t, survivor_ctx.next_seq[0], u64(FRAMES))

	loser_ctx := Seq_Drainer_Context {
		ring = loser,
	}
	seq_drain_ready(&loser_ctx)
	testing.expect_value(t, loser_ctx.frames_seen, 0)
}

@(test)
test_migrate_then_reset_drops_nothing :: proc(t: ^testing.T) {
	secondary := make_test_ring(16, 4096)
	primary := make_test_ring(16, 4096)
	testing.expect(t, secondary != nil, "Secondary ring should be created")
	testing.expect(t, primary != nil, "Primary ring should be created")
	defer destroy_connection_ring(secondary)
	defer destroy_connection_ring(primary)

	PRIMARY_FRAMES :: 400
	SECONDARY_FRAMES :: 600
	testing.expect_value(t, seq_fill_ring(primary, 0, PRIMARY_FRAMES), PRIMARY_FRAMES)
	testing.expect_value(t, seq_fill_ring(secondary, 1, SECONDARY_FRAMES), SECONDARY_FRAMES)

	_ = ring_migrate_slots(secondary, primary)
	testing.expect_value(t, ring_reset(secondary), 0)

	batch_flush(primary)

	primary_ctx := Seq_Drainer_Context {
		ring = primary,
	}
	seq_drain_ready(&primary_ctx)

	testing.expect_value(t, primary_ctx.malformed, 0)
	testing.expect_value(t, primary_ctx.order_violations, 0)
	testing.expect_value(t, primary_ctx.frames_seen, PRIMARY_FRAMES + SECONDARY_FRAMES)
	testing.expect_value(t, primary_ctx.next_seq[0], u64(PRIMARY_FRAMES))
	testing.expect_value(t, primary_ctx.next_seq[1], u64(SECONDARY_FRAMES))
}
