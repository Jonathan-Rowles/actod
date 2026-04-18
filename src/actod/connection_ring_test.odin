package actod

import "../pkgs/threads_act"
import "base:intrinsics"
import "core:encoding/endian"
import "core:sync"
import "core:testing"
import "core:thread"

make_test_msg :: proc(total_size: int, fill_byte: u8 = 0) -> []byte {
	msg := make([]byte, total_size)
	if total_size >= 4 {
		endian.put_u32(msg[0:4], .Little, u32(total_size - 4))
	}
	for i in 4 ..< total_size {
		msg[i] = fill_byte
	}
	return msg
}

count_messages_in_data :: proc(data: []byte) -> int {
	count := 0
	offset := 0
	for offset + 4 <= len(data) {
		msg_size := int(endian.unchecked_get_u32le(data[offset:offset + 4]))
		if msg_size == 0 {
			break
		}
		if offset + 4 + msg_size > len(data) {
			break
		}
		offset += 4 + msg_size
		count += 1
	}
	return count
}

make_test_ring :: proc(slot_count: u32, slot_size: u32) -> ^Connection_Ring {
	config := Connection_Ring_Config {
		send_slot_count  = slot_count,
		send_slot_size   = slot_size,
		recv_buffer_size = 1024,
	}
	ring := create_connection_ring(config)
	if ring != nil {
		ring.state = .Ready
	}
	return ring
}


Drainer_Context :: struct {
	ring:     ^Connection_Ring,
	stop:     bool, // atomic
	flushed:  int,
	recycled: int,
}

drainer_drain_ready :: proc(ring: ^Connection_Ring) -> int {
	recycled := 0
	write_idx := sync.atomic_load(&ring.send_write_idx)
	for ring.send_submit_idx < write_idx {
		slot_idx := ring.send_submit_idx & ring.send_mask
		slot := &ring.send_slots[slot_idx]
		if sync.atomic_load(&slot.state) != .READY {
			break
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

drainer_thread_proc :: proc(data: rawptr) {
	ctx := cast(^Drainer_Context)data
	ring := ctx.ring
	flushed := 0
	recycled := 0

	for !sync.atomic_load(&ctx.stop) {
		if sync.atomic_exchange(&ring.batch_pending, 0) != 0 {
			batch_flush(ring)
			flushed += 1
		}
		recycled += drainer_drain_ready(ring)
		for _ in 0 ..< 1000 {
			intrinsics.cpu_relax()
		}
	}

	batch_flush(ring)
	flushed += 1
	recycled += drainer_drain_ready(ring)

	ctx.flushed = flushed
	ctx.recycled = recycled
}


Writer_Context :: struct {
	ring:      ^Connection_Ring,
	msg_count: int,
	msg_size:  int,
	thread_id: u8,
	sent:      int,
	failures:  int,
}

writer_thread_proc :: proc(data: rawptr) {
	ctx := cast(^Writer_Context)data
	msg := make([]byte, ctx.msg_size)
	defer delete(msg)
	endian.put_u32(msg[0:4], .Little, u32(ctx.msg_size - 4))
	for i in 4 ..< ctx.msg_size {
		msg[i] = ctx.thread_id
	}
	sent := 0
	failures := 0
	for _ in 0 ..< ctx.msg_count {
		retries := 0
		for !batch_append_message(ctx.ring, msg) {
			retries += 1
			if retries > 1_000_000 {
				failures += 1
				break
			}
			if retries % 64 == 0 {
				thread.yield()
			} else {
				intrinsics.cpu_relax()
			}
		}
		if retries <= 1_000_000 {
			sent += 1
		}
	}
	ctx.sent = sent
	ctx.failures = failures
}


Test_Empty :: struct {}
Test_Inline :: struct {
	data: [32]byte,
}
Test_Medium :: struct {
	data: [256]byte,
}
Test_Large :: struct {
	data: [1024]byte,
}
Test_XLarge :: struct {
	data: [4096]byte,
}

@(init)
register_ring_test_types :: proc "contextless" () {
	register_message_type(Test_Empty)
	register_message_type(Test_Inline)
	register_message_type(Test_Medium)
	register_message_type(Test_Large)
	register_message_type(Test_XLarge)
}

Send_Ring_Context :: struct {
	ring:      ^Connection_Ring,
	msg_count: int,
	msg_type:  int, // 0=empty, 1=inline, 2=medium, 3=large
	sent:      int,
	failures:  int,
}

send_ring_thread_proc :: proc(data: rawptr) {
	ctx := cast(^Send_Ring_Context)data
	sent := 0
	failures := 0
	for _ in 0 ..< ctx.msg_count {
		err: Send_Error
		retries := 0
		for {
			switch ctx.msg_type {
			case 0:
				err = send_to_connection_ring(ctx.ring, PID(0), Test_Empty{})
			case 1:
				err = send_to_connection_ring(ctx.ring, PID(0), Test_Inline{})
			case 2:
				err = send_to_connection_ring(ctx.ring, PID(0), Test_Medium{})
			case 3:
				err = send_to_connection_ring(ctx.ring, PID(0), Test_Large{})
			}
			if err == .OK {
				sent += 1
				break
			}
			retries += 1
			if retries > 1_000_000 {
				failures += 1
				break
			}
			if retries % 64 == 0 {
				thread.yield()
			} else {
				intrinsics.cpu_relax()
			}
		}
	}
	ctx.sent = sent
	ctx.failures = failures
}

@(test)
test_create_destroy_connection_ring :: proc(t: ^testing.T) {
	config := Connection_Ring_Config {
		send_slot_count  = 8,
		send_slot_size   = 1024,
		recv_buffer_size = 4096,
		tcp_nodelay      = true,
	}

	ring := create_connection_ring(config)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	testing.expect(t, ring.send_slot_count == 8, "Slot count mismatch")
	testing.expect(t, ring.send_slot_size == 1024, "Slot size mismatch")
	testing.expect(t, ring.send_mask == 7, "Mask should be count-1")
	testing.expect(t, ring.recv_buffer_size == 4096, "Recv buffer size mismatch")
	testing.expect(t, ring.state == .Not_Initialized, "Initial state should be Not_Initialized")
	testing.expect(t, len(ring.send_slots) == 8, "Send slots length mismatch")
	testing.expect(t, len(ring.recv_buffer) == 4096, "Recv buffer length mismatch")

	for i in 0 ..< 8 {
		testing.expect(t, ring.send_slots[i].state == .FREE, "Slot should start FREE")
	}

	testing.expect(t, len(ring.send_data_buffer) == 8 * 1024, "Send data buffer size mismatch")
}

@(test)
test_connection_ring_config_validation :: proc(t: ^testing.T) {
	valid_counts := []u32{1, 2, 4, 8, 16, 32, 64}
	for count in valid_counts {
		config := Connection_Ring_Config {
			send_slot_count  = count,
			send_slot_size   = 1024,
			recv_buffer_size = 4096,
		}
		ring := create_connection_ring(config)
		if ring != nil {
			testing.expect(t, ring.send_slot_count == count, "Slot count should match")
			destroy_connection_ring(ring)
		}
	}
}

@(test)
test_acquire_slot :: proc(t: ^testing.T) {
	config := Connection_Ring_Config {
		send_slot_count  = 4,
		send_slot_size   = 256,
		recv_buffer_size = 1024,
	}

	ring := create_connection_ring(config)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	ring.state = .Ready

	slot1, idx1, ok1 := acquire_slot(ring)
	testing.expect(t, ok1, "Should acquire first slot")
	testing.expect(t, slot1 != nil, "Slot pointer should not be nil")
	testing.expect(t, idx1 == 0, "First slot index should be 0")
	testing.expect(t, slot1.state == .WRITING, "Slot should be in WRITING state")

	slot1.length = 100
	sync.atomic_store_explicit(&slot1.state, .READY, .Release)

	slot2, idx2, ok2 := acquire_slot(ring)
	testing.expect(t, ok2, "Should acquire second slot")
	testing.expect(t, idx2 == 1, "Second slot index should be 1")

	sync.atomic_store_explicit(&slot1.state, .FREE, .Release)
	sync.atomic_add(&ring.send_complete_idx, 1)

	slot2.length = 50
	sync.atomic_store_explicit(&slot2.state, .READY, .Release)
}

@(test)
test_validate_batch_messages_valid :: proc(t: ^testing.T) {
	valid_single := make([]byte, 20)
	defer delete(valid_single)
	endian.put_u32(valid_single[0:4], .Little, 16)

	testing.expect(
		t,
		validate_batch_messages(valid_single, 0, 20),
		"Valid single message should pass",
	)

	valid_two := make([]byte, 24)
	defer delete(valid_two)
	endian.put_u32(valid_two[0:4], .Little, 8)
	endian.put_u32(valid_two[12:16], .Little, 4)

	testing.expect(
		t,
		validate_batch_messages(valid_two[:20], 0, 20),
		"Valid two messages should pass",
	)

	valid_three := make([]byte, 36)
	defer delete(valid_three)
	endian.put_u32(valid_three[0:4], .Little, 8)
	endian.put_u32(valid_three[12:16], .Little, 4)
	endian.put_u32(valid_three[20:24], .Little, 8)

	testing.expect(
		t,
		validate_batch_messages(valid_three[:32], 0, 32),
		"Valid three messages should pass",
	)
}

@(test)
test_batch_append_message :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 16 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	msg1 := make([]byte, 20)
	defer delete(msg1)
	endian.put_u32(msg1[0:4], .Little, 16)

	ok1 := batch_append_message(ring, msg1)
	testing.expect(t, ok1, "First message should append")
	testing.expect(t, ring.batch_slot_idx >= 0, "Should have active batch slot")
	testing.expect(t, ring.batch_write_pos == 20, "Write pos should be 20")

	msg2 := make([]byte, 12)
	defer delete(msg2)
	endian.put_u32(msg2[0:4], .Little, 8)

	ok2 := batch_append_message(ring, msg2)
	testing.expect(t, ok2, "Second message should append")
	testing.expect(t, ring.batch_write_pos == 32, "Write pos should be 32")

	batch_flush(ring)
	testing.expect(t, ring.batch_slot_idx == -1, "Batch slot should be cleared")
	testing.expect(t, ring.batch_write_pos == 0, "Write pos should be reset")
}

@(test)
test_batch_append_empty_message :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 256)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	empty := []byte{}
	ok := batch_append_message(ring, empty)
	testing.expect(t, ok, "Empty message should return true")
	testing.expect(t, ring.batch_slot_idx == -1, "Should not acquire slot for empty message")
}


@(test)
test_batch_small_messages_pack :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 16 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	for _ in 0 ..< 10 {
		msg := make_test_msg(20)
		defer delete(msg)
		ok := batch_append_message(ring, msg)
		testing.expect(t, ok, "Should append small message")
	}

	testing.expect(t, ring.batch_slot_idx >= 0, "Batch should still be open")
	testing.expect(t, ring.batch_write_pos == 200, "Write pos should be 10 * 20")

	batch_flush(ring)

	slot := &ring.send_slots[0]
	testing.expect(t, sync.atomic_load(&slot.state) == .READY, "Slot should be READY")
	testing.expect(t, slot.length == 200, "Slot length should be 200")

	data := slot_data(ring, 0)
	testing.expect(t, validate_batch_messages(data[:200], 0, 200), "Messages should validate")
	testing.expect(t, count_messages_in_data(data[:200]) == 10, "Should count 10 messages")
}

@(test)
test_batch_large_message_auto_seals :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 4096)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	msg := make_test_msg(3200)
	defer delete(msg)
	ok := batch_append_message(ring, msg)
	testing.expect(t, ok, "Should append large message")

	testing.expect(t, ring.batch_slot_idx == -1, "Batch should be auto-sealed")

	slot := &ring.send_slots[0]
	testing.expect(t, sync.atomic_load(&slot.state) == .READY, "Slot should be READY")
	testing.expect(t, slot.length == 3200, "Slot length should be 3200")
}

@(test)
test_batch_spills_to_next_slot :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 4096)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	msg1 := make_test_msg(2500)
	defer delete(msg1)
	ok1 := batch_append_message(ring, msg1)
	testing.expect(t, ok1, "First message should append")
	testing.expect(t, ring.batch_slot_idx >= 0, "Batch should be open")

	msg2 := make_test_msg(2000)
	defer delete(msg2)
	ok2 := batch_append_message(ring, msg2)
	testing.expect(t, ok2, "Second message should append")

	slot0 := &ring.send_slots[0]
	testing.expect(t, sync.atomic_load(&slot0.state) == .READY, "Slot 0 should be READY")
	testing.expect(t, slot0.length == 2500, "Slot 0 length should be 2500")

	testing.expect(t, ring.batch_write_pos == 2000, "Slot 1 write pos should be 2000")

	batch_flush(ring)

	slot1 := &ring.send_slots[1]
	testing.expect(t, sync.atomic_load(&slot1.state) == .READY, "Slot 1 should be READY")
	testing.expect(t, slot1.length == 2000, "Slot 1 length should be 2000")
}


@(test)
test_partial_flush_two_messages :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 16 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	msg := make_test_msg(20)
	defer delete(msg)

	batch_append_message(ring, msg)
	batch_append_message(ring, msg)

	testing.expect(t, ring.batch_slot_idx >= 0, "Batch should be open (not auto-sealed)")
	testing.expect(t, ring.batch_write_pos == 40, "Write pos should be 40")
	testing.expect(t, sync.atomic_load(&ring.batch_pending) == 1, "batch_pending should be set")

	batch_flush(ring)

	testing.expect(t, ring.batch_slot_idx == -1, "Batch should be sealed")
	testing.expect(t, ring.batch_write_pos == 0, "Write pos should be reset")

	slot := &ring.send_slots[0]
	testing.expect(t, sync.atomic_load(&slot.state) == .READY, "Slot should be READY")
	testing.expect(t, slot.length == 40, "Slot length should be 40")

	data := slot_data(ring, 0)
	testing.expect(t, count_messages_in_data(data[:40]) == 2, "Should have exactly 2 messages")
	testing.expect(t, validate_batch_messages(data[:40], 0, 40), "Messages should validate")
}

@(test)
test_batch_pending_set_on_fast_path :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 16 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	testing.expect(
		t,
		sync.atomic_load(&ring.batch_pending) == 0,
		"batch_pending should start at 0",
	)

	msg := make_test_msg(20)
	defer delete(msg)

	batch_append_message(ring, msg)
	testing.expect(
		t,
		sync.atomic_load(&ring.batch_pending) == 1,
		"batch_pending should be 1 after first msg",
	)

	sync.atomic_exchange(&ring.batch_pending, 0)

	batch_append_message(ring, msg)
	testing.expect(
		t,
		sync.atomic_load(&ring.batch_pending) == 1,
		"batch_pending should be 1 again after second msg on fast path",
	)

	batch_flush(ring)
}


@(test)
test_sealed_by_nearly_full :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 4096)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	dst, sid, ok := batch_reserve(ring, 3200)
	testing.expect(t, ok, "Reserve should succeed")
	testing.expect(t, len(dst) == 3200, "Dst should be 3200 bytes")

	slot := &ring.send_slots[sid]
	testing.expect(
		t,
		sync.atomic_load(&slot.state) == .SEALED,
		"Slot should be SEALED (active writer prevents READY)",
	)
	testing.expect(t, sync.atomic_load(&slot.active_writers) == 1, "Should have 1 active writer")
	testing.expect(t, ring.batch_slot_idx == -1, "Batch should be cleared by seal")

	endian.put_u32(dst[0:4], .Little, u32(3200 - 4))

	batch_commit(ring, sid)

	testing.expect(
		t,
		sync.atomic_load(&slot.state) == .READY,
		"Commit should promote SEALED to READY",
	)
	testing.expect(t, sync.atomic_load(&slot.active_writers) == 0, "No active writers remain")
	testing.expect(
		t,
		sync.atomic_load(&ring.batch_pending) == 1,
		"batch_pending should be set on READY transition",
	)
}

@(test)
test_sealed_multiple_writers_last_promotes :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 4096)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	dst1, sid1, ok1 := batch_reserve(ring, 1500)
	testing.expect(t, ok1, "Reserve 1 should succeed")
	endian.put_u32(dst1[0:4], .Little, u32(1500 - 4))

	dst2, sid2, ok2 := batch_reserve(ring, 1500)
	testing.expect(t, ok2, "Reserve 2 should succeed")
	testing.expect(t, sid2 == sid1, "Should be same slot")
	endian.put_u32(dst2[0:4], .Little, u32(1500 - 4))

	dst3, sid3, ok3 := batch_reserve(ring, 1000)
	testing.expect(t, ok3, "Reserve 3 should succeed")
	testing.expect(t, sid3 == sid1, "Should be same slot")
	endian.put_u32(dst3[0:4], .Little, u32(1000 - 4))

	slot := &ring.send_slots[sid1]
	testing.expect(t, sync.atomic_load(&slot.state) == .SEALED, "Should be SEALED")
	testing.expect(t, sync.atomic_load(&slot.active_writers) == 3, "Should have 3 writers")

	batch_commit(ring, sid1)
	testing.expect(t, sync.atomic_load(&slot.state) == .SEALED, "Still SEALED after 1st commit")

	batch_commit(ring, sid2)
	testing.expect(t, sync.atomic_load(&slot.state) == .SEALED, "Still SEALED after 2nd commit")

	batch_commit(ring, sid3)
	testing.expect(t, sync.atomic_load(&slot.state) == .READY, "READY after 3rd (last) commit")
	testing.expect(t, sync.atomic_load(&slot.active_writers) == 0, "No writers remain")
}

@(test)
test_lazy_seal_skips_active_writers :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 16 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	dst, sid, ok := batch_reserve(ring, 100)
	testing.expect(t, ok, "Reserve should succeed")
	endian.put_u32(dst[0:4], .Little, u32(100 - 4))

	saved_batch_idx := ring.batch_slot_idx
	testing.expect(t, saved_batch_idx >= 0, "Batch should be open")

	batch_flush(ring)

	testing.expect(
		t,
		ring.batch_slot_idx == saved_batch_idx,
		"Batch should still be open (lazy seal skipped)",
	)
	slot := &ring.send_slots[sid]
	testing.expect(t, sync.atomic_load(&slot.state) == .WRITING, "Slot should still be WRITING")

	batch_commit(ring, sid)

	batch_flush(ring)

	testing.expect(t, ring.batch_slot_idx == -1, "Batch should be sealed now")
	testing.expect(t, sync.atomic_load(&slot.state) == .READY, "Slot should be READY")
}


@(test)
test_all_slots_exhausted :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 4096)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	for _ in 0 ..< 4 {
		slot, _, ok := acquire_slot(ring)
		testing.expect(t, ok, "Should acquire slot")
		slot.length = 100
		sync.atomic_store(&slot.state, .READY)
	}

	_, _, ok := acquire_slot(ring)
	testing.expect(t, !ok, "Should fail when all slots are used")

	ring.send_slots[0].length = 0
	sync.atomic_store(&ring.send_slots[0].state, .FREE)
	sync.atomic_add(&ring.send_complete_idx, 1)

	_, _, ok2 := acquire_slot(ring)
	testing.expect(t, ok2, "Should succeed after freeing a slot")
}

@(test)
test_batch_abort_preserves_stream :: proc(t: ^testing.T) {
	ring := make_test_ring(4, 16 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	msg := make_test_msg(100)
	defer delete(msg)
	batch_append_message(ring, msg)

	dst, sid, ok := batch_reserve(ring, 200)
	testing.expect(t, ok, "Reserve should succeed")
	batch_abort(ring, sid, dst)

	batch_flush(ring)

	slot := &ring.send_slots[0]
	if sync.atomic_load(&slot.state) == .READY {
		data := slot_data(ring, 0)
		testing.expect(
			t,
			validate_batch_messages(data[:slot.length], 0, slot.length),
			"Stream should still be valid after abort",
		)
	}
}


@(test)
test_build_wire_format_pod :: proc(t: ^testing.T) {
	buffer := make([]byte, 256)
	defer delete(buffer)

	to_handle := Handle {
		idx = 1,
		gen = 2,
	}
	from_handle := Handle {
		idx = 3,
		gen = 4,
	}

	Pod_Message :: struct {
		value: i32,
	}
	register_message_type(Pod_Message)

	pod_msg := Pod_Message {
		value = 123,
	}
	written := build_wire_format_into_buffer(buffer, pod_msg, to_handle, from_handle, {}, "")

	testing.expect(t, written > 0, "Should write POD message")

	msg_size := endian.unchecked_get_u32le(buffer[0:4])
	testing.expect(t, msg_size == written - 4, "Size prefix should match")

	header, ok := parse_network_header(buffer[4:written])
	testing.expect(t, ok, "Should parse header")
	testing.expect(t, header.from_handle == from_handle, "From handle mismatch")
	testing.expect(t, header.to_handle == to_handle, "To handle mismatch")
}

@(test)
test_build_wire_format_with_name :: proc(t: ^testing.T) {
	Named_Pod_Message :: struct {
		value: i32,
	}
	register_message_type(Named_Pod_Message)

	buffer := make([]byte, 256)
	defer delete(buffer)

	msg := Named_Pod_Message {
		value = 999,
	}
	actor_name := "target_actor"

	to_handle := Handle {
		idx = u32(len(actor_name)),
		gen = 0,
	}
	from_handle := Handle {
		idx = 5,
		gen = 6,
	}

	written := build_wire_format_into_buffer(
		buffer,
		msg,
		to_handle,
		from_handle,
		{.BY_NAME},
		actor_name,
	)

	testing.expect(t, written > 0, "Should write message with name")

	header, ok := parse_network_header(buffer[4:written])
	testing.expect(t, ok, "Should parse header")
	testing.expect(t, .BY_NAME in header.flags, "BY_NAME flag should be set")
	testing.expect(t, header.to_name == actor_name, "Actor name mismatch")
}

@(test)
test_wire_format_exact_size_matches_build :: proc(t: ^testing.T) {
	buf: [8192]byte
	to := Handle {
		idx = 1,
		gen = 2,
	}
	from := Handle {
		idx = 3,
		gen = 4,
	}

	{
		msg := Test_Empty{}
		exact := wire_format_exact_size(msg, 0)
		built := build_wire_format_into_buffer(buf[:], msg, to, from, {}, "")
		testing.expect(t, exact == built, "Empty: exact_size != built size")
		testing.expect(t, exact == u32(4 + NETWORK_HEADER_SIZE), "Empty: wrong size")
	}
	{
		msg := Test_Inline{}
		exact := wire_format_exact_size(msg, 0)
		built := build_wire_format_into_buffer(buf[:], msg, to, from, {}, "")
		testing.expect(t, exact == built, "Inline: exact_size != built size")
	}
	{
		msg := Test_Medium{}
		exact := wire_format_exact_size(msg, 0)
		built := build_wire_format_into_buffer(buf[:], msg, to, from, {}, "")
		testing.expect(t, exact == built, "Medium: exact_size != built size")
		testing.expect(
			t,
			exact == u32(4 + NETWORK_HEADER_SIZE + size_of(Test_Medium)),
			"Medium: wrong size",
		)
	}
	{
		msg := Test_Large{}
		exact := wire_format_exact_size(msg, 0)
		built := build_wire_format_into_buffer(buf[:], msg, to, from, {}, "")
		testing.expect(t, exact == built, "Large: exact_size != built size")
	}
	{
		msg := Test_Inline{}
		name := "test_actor_name"
		exact := wire_format_exact_size(msg, len(name))
		to_named := Handle {
			idx = u32(len(name)),
			gen = 0,
		}
		built := build_wire_format_into_buffer(buf[:], msg, to_named, from, {.BY_NAME}, name)
		testing.expect(t, exact == built, "Named: exact_size != built size")
	}
}

@(test)
test_send_to_ring_all_sizes :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	for _ in 0 ..< 100 {
		testing.expect(
			t,
			send_to_connection_ring(ring, PID(0), Test_Empty{}) == .OK,
			"Empty send should succeed",
		)
		testing.expect(
			t,
			send_to_connection_ring(ring, PID(0), Test_Inline{}) == .OK,
			"Inline send should succeed",
		)
		testing.expect(
			t,
			send_to_connection_ring(ring, PID(0), Test_Medium{}) == .OK,
			"Medium send should succeed",
		)
		testing.expect(
			t,
			send_to_connection_ring(ring, PID(0), Test_Large{}) == .OK,
			"Large send should succeed",
		)
	}

	batch_flush(ring)

	total_messages := 0
	for i in 0 ..< u32(16) {
		slot := &ring.send_slots[i]
		if sync.atomic_load(&slot.state) != .READY {
			continue
		}
		data := slot_data(ring, i)
		testing.expect(
			t,
			validate_batch_messages(data[:slot.length], i32(i), slot.length),
			"Slot data should validate",
		)
		total_messages += count_messages_in_data(data[:slot.length])
	}

	testing.expect(t, total_messages == 400, "Should have 400 messages total")
}


@(test)
test_stress_with_drainer_small :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 50_000

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Writer_Context
	threads: [num_threads]^thread.Thread

	for i in 0 ..< num_threads {
		ctxs[i] = Writer_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_size  = 20,
			thread_id = u8(i + 1),
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], writer_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failures := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failures += ctxs[i].failures
	}

	testing.expect(t, total_sent == num_threads * MSGS_PER_THREAD, "All sends should succeed")
	testing.expect(t, total_failures == 0, "No send failures")
}

@(test)
test_stress_with_drainer_medium :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 10_000

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Writer_Context
	threads: [num_threads]^thread.Thread

	for i in 0 ..< num_threads {
		ctxs[i] = Writer_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_size  = 286,
			thread_id = u8(i + 1),
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], writer_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failures := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failures += ctxs[i].failures
	}

	testing.expect(t, total_sent == num_threads * MSGS_PER_THREAD, "All sends should succeed")
	testing.expect(t, total_failures == 0, "No send failures")
}

@(test)
test_stress_with_drainer_large :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 5_000

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Writer_Context
	threads: [num_threads]^thread.Thread

	for i in 0 ..< num_threads {
		ctxs[i] = Writer_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_size  = 1058,
			thread_id = u8(i + 1),
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], writer_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failures := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failures += ctxs[i].failures
	}

	testing.expect(t, total_sent == num_threads * MSGS_PER_THREAD, "All sends should succeed")
	testing.expect(t, total_failures == 0, "No send failures")
}


@(test)
test_stress_send_ring_empty :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 100_000

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Send_Ring_Context
	threads: [num_threads]^thread.Thread
	for i in 0 ..< num_threads {
		ctxs[i] = Send_Ring_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_type  = 0,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], send_ring_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failures := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failures += ctxs[i].failures
	}
	testing.expect(t, total_sent == num_threads * MSGS_PER_THREAD, "All sends should succeed")
	testing.expect(t, total_failures == 0, "No failures")
}

@(test)
test_stress_send_ring_medium :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 10_000

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Send_Ring_Context
	threads: [num_threads]^thread.Thread
	for i in 0 ..< num_threads {
		ctxs[i] = Send_Ring_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_type  = 2,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], send_ring_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failures := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failures += ctxs[i].failures
	}
	testing.expect(t, total_sent == num_threads * MSGS_PER_THREAD, "All sends should succeed")
	testing.expect(t, total_failures == 0, "No failures")
}

@(test)
test_stress_send_ring_large :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 5_000

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Send_Ring_Context
	threads: [num_threads]^thread.Thread
	for i in 0 ..< num_threads {
		ctxs[i] = Send_Ring_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_type  = 3,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], send_ring_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failures := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failures += ctxs[i].failures
	}
	testing.expect(t, total_sent == num_threads * MSGS_PER_THREAD, "All sends should succeed")
	testing.expect(t, total_failures == 0, "No failures")
}

@(test)
test_stress_send_ring_1m_baseline :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctx := Send_Ring_Context {
		ring      = ring,
		msg_count = 1_000_000,
		msg_type  = 0,
	}
	send_ring_thread_proc(&ctx)

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	testing.expect(t, ctx.sent == 1_000_000, "All 1M sends should succeed")
	testing.expect(t, ctx.failures == 0, "No failures")
}


@(test)
test_ring_full_rate_medium_messages :: proc(t: ^testing.T) {
	ring := make_test_ring(64, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 50_000

	Stat_Context :: struct {
		ring:      ^Connection_Ring,
		msg_count: int,
		sent:      int,
		failed:    int,
	}

	stat_thread_proc :: proc(data: rawptr) {
		ctx := cast(^Stat_Context)data
		sent := 0
		failed := 0
		for _ in 0 ..< ctx.msg_count {
			result := send_to_connection_ring(ctx.ring, PID(0), Test_Medium{})
			if result == .OK {
				sent += 1
			} else {
				failed += 1
			}
		}
		ctx.sent = sent
		ctx.failed = failed
	}

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Stat_Context
	threads: [num_threads]^thread.Thread

	for i in 0 ..< num_threads {
		ctxs[i] = Stat_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], stat_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failed := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failed += ctxs[i].failed
	}

	total := num_threads * MSGS_PER_THREAD
	drop_pct := f64(total_failed) * 100.0 / f64(total)

	testing.expectf(
		t,
		drop_pct < 1.0,
		"Drop rate %.2f%% too high (%d/%d failed) — ring not draining fast enough",
		drop_pct,
		total_failed,
		total,
	)
}

@(test)
test_ring_full_rate_large_messages :: proc(t: ^testing.T) {
	ring := make_test_ring(64, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	num_threads :: 8
	MSGS_PER_THREAD :: 25_000

	Stat_Context_L :: struct {
		ring:      ^Connection_Ring,
		msg_count: int,
		sent:      int,
		failed:    int,
	}

	stat_thread_proc_l :: proc(data: rawptr) {
		ctx := cast(^Stat_Context_L)data
		sent := 0
		failed := 0
		for _ in 0 ..< ctx.msg_count {
			result := send_to_connection_ring(ctx.ring, PID(0), Test_Large{})
			if result == .OK {
				sent += 1
			} else {
				failed += 1
			}
		}
		ctx.sent = sent
		ctx.failed = failed
	}

	drainer_ctx := Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&drainer_ctx, drainer_thread_proc)

	ctxs: [num_threads]Stat_Context_L
	threads: [num_threads]^thread.Thread

	for i in 0 ..< num_threads {
		ctxs[i] = Stat_Context_L {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], stat_thread_proc_l)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&drainer_ctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	total_failed := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
		total_failed += ctxs[i].failed
	}

	total := num_threads * MSGS_PER_THREAD
	drop_pct := f64(total_failed) * 100.0 / f64(total)

	testing.expectf(
		t,
		drop_pct < 1.0,
		"Drop rate %.2f%% too high (%d/%d failed)",
		drop_pct,
		total_failed,
		total,
	)
}

@(test)
test_drainer_flush_not_starved :: proc(t: ^testing.T) {
	ring := make_test_ring(16, 64 * 1024)
	testing.expect(t, ring != nil, "Ring should be created")
	defer destroy_connection_ring(ring)

	Flush_Drainer_Context :: struct {
		ring:          ^Connection_Ring,
		stop:          bool,
		flush_success: int,
		flush_skipped: int,
		recycled:      int,
	}

	flush_drainer_proc :: proc(data: rawptr) {
		ctx := cast(^Flush_Drainer_Context)data
		ring := ctx.ring

		for !sync.atomic_load(&ctx.stop) {
			if sync.atomic_load(&ring.batch_pending) != 0 {
				if sync.mutex_try_lock(&ring.batch_mutex) {
					sync.atomic_store(&ring.batch_pending, 0)
					batch_seal_locked(ring)
					sync.mutex_unlock(&ring.batch_mutex)
					ctx.flush_success += 1
				} else {
					ctx.flush_skipped += 1
				}
			}
			ctx.recycled += drainer_drain_ready(ring)
			for _ in 0 ..< 100 {
				intrinsics.cpu_relax()
			}
		}

		batch_flush(ring)
		ctx.recycled += drainer_drain_ready(ring)
	}

	MSGS_PER_THREAD :: 20_000
	num_threads := max(2, min(8, threads_act.get_cpu_count() - 1))

	fctx := Flush_Drainer_Context {
		ring = ring,
		stop = false,
	}
	drainer := thread.create_and_start_with_data(&fctx, flush_drainer_proc)

	ctxs := make([]Send_Ring_Context, num_threads)
	defer delete(ctxs)
	threads := make([]^thread.Thread, num_threads)
	defer delete(threads)
	for i in 0 ..< num_threads {
		ctxs[i] = Send_Ring_Context {
			ring      = ring,
			msg_count = MSGS_PER_THREAD,
			msg_type  = 2, // medium 256B
		}
		threads[i] = thread.create_and_start_with_data(&ctxs[i], send_ring_thread_proc)
	}

	for i in 0 ..< num_threads {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	sync.atomic_store(&fctx.stop, true)
	thread.join(drainer)
	thread.destroy(drainer)

	total_sent := 0
	for i in 0 ..< num_threads {
		total_sent += ctxs[i].sent
	}

	total_flushes := fctx.flush_success + fctx.flush_skipped

	testing.expectf(
		t,
		total_sent == num_threads * MSGS_PER_THREAD,
		"All sends should succeed (got %d/%d)",
		total_sent,
		num_threads * MSGS_PER_THREAD,
	)

	testing.expectf(
		t,
		fctx.flush_success > 0,
		"Drainer never acquired batch_mutex (%d/%d) — writers fully starving the IO thread",
		fctx.flush_success,
		total_flushes,
	)

	testing.expectf(
		t,
		fctx.recycled > 0,
		"Drainer should have recycled slots (recycled=%d)",
		fctx.recycled,
	)
}
