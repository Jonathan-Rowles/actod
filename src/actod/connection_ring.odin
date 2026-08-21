package actod

import "base:intrinsics"
import "base:runtime"
import "core:crypto"
import "core:encoding/endian"
import "core:log"
import "core:nbio"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

TICK_ACTIVE_TIMEOUT :: 50 * time.Microsecond
TICK_IDLE_TIMEOUT :: 2 * time.Millisecond
TICK_IDLE_THRESHOLD :: 50

IO_ATTACH_RETRIES :: 50_000
IO_ATTACH_RETRY_DELAY :: 100 * time.Microsecond
RING_RESET_WRITER_SPIN :: 1_000_000

Send_Slot_State :: enum u32 {
	FREE      = 0,
	WRITING   = 1,
	SEALED    = 2,
	READY     = 3,
	DISCARDED = 4,
}

Send_Slot :: struct #align (CACHE_LINE_SIZE) {
	state:          Send_Slot_State,
	length:         u32,
	active_writers: i32,
	seal_id:        u64,
}

g_seal_counter: u64

@(private)
slot_data :: #force_inline proc(ring: ^Connection_Ring, slot_idx: u32) -> []byte {
	offset := int(slot_idx) * int(ring.send_slot_size)
	return ring.send_data_buffer[offset:offset + int(ring.send_slot_size)]
}

Connection_Ring_State :: enum u32 {
	Buffering,
	Ready,
}

Connection_Ring_Config :: struct {
	send_slot_count:               u32,
	send_slot_size:                u32,
	recv_buffer_size:              u32,
	tcp_nodelay:                   bool,
	max_pool_rings:                u32,
	scale_up_contention_threshold: u32,
	scale_down_idle_seconds:       u32,
}

DEFAULT_CONNECTION_RING_CONFIG :: Connection_Ring_Config {
	send_slot_count               = 64,
	send_slot_size                = 64 * 1024,
	recv_buffer_size              = 2 * 1024 * 1024,
	tcp_nodelay                   = true,
	max_pool_rings                = 8,
	scale_up_contention_threshold = 100,
	scale_down_idle_seconds       = 10,
}

MAX_POOL_RINGS :: 16

Scale_Up_Request :: struct {}

Pool_Ring_Closed :: struct {
	ring_ptr: u64,
}

Ring_Park_State :: enum u32 {
	Active     = 0,
	Park_Asked = 1,
	Park_Acked = 2,
	Draining   = 3,
}

Connection_Pool :: struct {
	rings:                [MAX_POOL_RINGS]^Connection_Ring,
	ring_count:           u32,
	next_ring:            u32,
	contention_count:     u32,
	scale_up_requested:   u32,
	conn_pid:             u64,
	join_token:           u64,
	contention_threshold: u32,
	max_rings:            u32,
	node_id:              Node_ID,
	parked:               [MAX_POOL_RINGS]^Connection_Ring,
	parked_count:         u32,
	draining:             [MAX_POOL_RINGS]^Connection_Ring,
	draining_count:       u32,
}

// Owned by NODE (registered in NODE.connection_rings), never destroyed while
// producers may hold a pointer. Connection actors adopt the ring: they set
// tcp_socket/conn_pid/transport_keys between handshake and IO attach, and must
// stop + join the IO thread before calling ring_reset.
Connection_Ring :: struct {
	tcp_socket:            net.TCP_Socket,
	node_id:               Node_ID,
	conn_pid:              PID,
	send_mask:             u32,
	send_slot_size:        u32,
	usable_slot_size:      u32,
	send_slot_count:       u32,
	send_slots:            []Send_Slot,
	send_data_buffer:      []byte,
	recv_buffer:           []byte,
	recv_buffer_size:      u32,
	tcp_nodelay:           bool,
	encrypted:             bool,
	state:                 Connection_Ring_State,
	transport_keys:        Noise_Transport,
	seal_scratch:          []byte,
	open_scratch:          []byte,
	io_owner:              u64,
	io_stop:               i32,
	io_thread:             ^thread.Thread,
	io_event_loop:         ^nbio.Event_Loop,
	io_wakers:             u32,
	io_sleeping:           u32,
	pool:                  ^Connection_Pool,
	park_state:            Ring_Park_State,
	_pad_producer:         [CACHE_LINE_SIZE]byte,
	batch_mutex:           sync.Mutex,
	batch_slot_idx:        i32,
	batch_write_pos:       u32,
	nearly_full_threshold: u32,
	send_write_idx:        u32,
	batch_pending:         u32,
	last_activity_time:    i64,
	_pad_consumer:         [CACHE_LINE_SIZE]byte,
	send_submit_idx:       u32,
	send_complete_idx:     u32,
	recv_write_pos:        u32,
	pending_recv:          ^nbio.Operation,
	send_in_flight:        bool,
	send_bufs:             [][]byte,
}

IO_Context :: struct {
	ring:      ^Connection_Ring,
	conn_pid:  PID,
	allocator: runtime.Allocator,
	logger:    runtime.Logger,
}

make_connection_ring :: proc(
	config: Connection_Ring_Config,
	encrypted: bool = false,
	allocator := context.allocator,
) -> ^Connection_Ring {
	if config.send_slot_count == 0 || !is_power_of_two(config.send_slot_count) {
		log.errorf("send_slot_count must be a power of 2, got %d", config.send_slot_count)
		return nil
	}
	if config.recv_buffer_size == 0 {
		log.errorf("recv_buffer_size must be > 0")
		return nil
	}

	ring := new(Connection_Ring, allocator)
	if ring == nil do return nil

	ring.send_slot_count = config.send_slot_count
	ring.send_slot_size = config.send_slot_size
	ring.send_mask = config.send_slot_count - 1
	ring.tcp_nodelay = config.tcp_nodelay
	ring.encrypted = encrypted
	ring.usable_slot_size = config.send_slot_size
	if encrypted && ring.usable_slot_size > MAX_ENVELOPE_PLAINTEXT {
		ring.usable_slot_size = MAX_ENVELOPE_PLAINTEXT
	}

	ring.send_slots = make([]Send_Slot, config.send_slot_count, allocator)
	if ring.send_slots == nil {
		destroy_connection_ring(ring, allocator)
		return nil
	}

	send_data_size := int(config.send_slot_count) * int(config.send_slot_size)
	ring.send_data_buffer = make([]byte, send_data_size, allocator)
	if ring.send_data_buffer == nil {
		destroy_connection_ring(ring, allocator)
		return nil
	}

	ring.recv_buffer_size = config.recv_buffer_size
	ring.recv_buffer = make([]byte, config.recv_buffer_size, allocator)
	if ring.recv_buffer == nil {
		destroy_connection_ring(ring, allocator)
		return nil
	}

	ring.send_bufs = make([][]byte, MAX_SEND_BATCH, allocator)
	if ring.send_bufs == nil {
		destroy_connection_ring(ring, allocator)
		return nil
	}

	if encrypted {
		seal_stride := int(ring.usable_slot_size) + ENVELOPE_OVERHEAD
		ring.seal_scratch = make([]byte, MAX_SEND_BATCH * seal_stride, allocator)
		ring.open_scratch = make([]byte, MAX_ENVELOPE_PLAINTEXT, allocator)
		if ring.seal_scratch == nil || ring.open_scratch == nil {
			destroy_connection_ring(ring, allocator)
			return nil
		}
	}

	ring.state = .Buffering
	ring.batch_slot_idx = -1
	ring.batch_write_pos = 0
	ring.nearly_full_threshold = max(ring.usable_slot_size / 8, 1024)

	return ring
}

destroy_connection_ring :: proc(ring: ^Connection_Ring, allocator := context.allocator) {
	if ring == nil do return

	if ring.open_scratch != nil do delete(ring.open_scratch, allocator)
	if ring.seal_scratch != nil do delete(ring.seal_scratch, allocator)
	if ring.recv_buffer != nil do delete(ring.recv_buffer, allocator)
	if ring.send_data_buffer != nil do delete(ring.send_data_buffer, allocator)
	if ring.send_slots != nil do delete(ring.send_slots, allocator)
	if ring.send_bufs != nil do delete(ring.send_bufs, allocator)
	free(ring, allocator)
}

ring_migrate_slots :: proc(loser: ^Connection_Ring, survivor: ^Connection_Ring) -> int {
	if loser == nil || survivor == nil || loser == survivor do return 0

	sync.mutex_lock(&loser.batch_mutex)

	for spin := 0; spin < RING_RESET_WRITER_SPIN; spin += 1 {
		active := false
		for i in 0 ..< loser.send_slot_count {
			if sync.atomic_load(&loser.send_slots[i].active_writers) > 0 {
				active = true
				break
			}
		}
		if !active do break
		intrinsics.cpu_relax()
	}

	batch_seal_locked(loser, force = true)
	sync.mutex_unlock(&loser.batch_mutex)

	migrated := 0
	write_idx := sync.atomic_load(&loser.send_write_idx)
	for idx := loser.send_submit_idx; idx < write_idx; idx += 1 {
		slot := &loser.send_slots[idx & loser.send_mask]
		if sync.atomic_load(&slot.state) != .READY do continue
		length := slot.length
		if length == 0 do continue
		if u32(length) > survivor.usable_slot_size {
			log.errorf(
				"Cannot migrate %d buffered bytes to the surviving ring for node %d, its slots hold %d",
				length,
				survivor.node_id,
				survivor.usable_slot_size,
			)
			continue
		}
		blob := slot_data(loser, idx & loser.send_mask)[:length]
		if batch_append_message_retry(survivor, blob) {
			slot.length = 0
			sync.atomic_store(&slot.state, .FREE)
			migrated += 1
		} else {
			log.errorf(
				"Failed to migrate a %d byte buffered slot to the surviving ring for node %d, frames dropped",
				length,
				survivor.node_id,
			)
		}
	}
	return migrated
}

// Caller must have stopped and joined the IO thread first. Drops all buffered
// slots (unflushed data does not survive a dead connection) and wipes the
// session keys. Returns the number of dropped slots.
ring_reset :: proc(ring: ^Connection_Ring) -> int {
	if ring == nil do return 0

	sync.mutex_lock(&ring.batch_mutex)
	defer sync.mutex_unlock(&ring.batch_mutex)

	for spin := 0; spin < RING_RESET_WRITER_SPIN; spin += 1 {
		active := false
		for i in 0 ..< ring.send_slot_count {
			if sync.atomic_load(&ring.send_slots[i].active_writers) > 0 {
				active = true
				break
			}
		}
		if !active do break
		intrinsics.cpu_relax()
	}

	dropped := 0
	for i in 0 ..< ring.send_slot_count {
		slot := &ring.send_slots[i]
		if sync.atomic_load(&slot.state) != .FREE do dropped += 1
		slot.length = 0
		if sync.atomic_load(&slot.active_writers) > 0 {
			sync.atomic_store(&slot.state, .DISCARDED)
			continue
		}
		slot.state = .FREE
		slot.active_writers = 0
	}

	ring.send_write_idx = 0
	ring.send_submit_idx = 0
	ring.send_complete_idx = 0
	ring.recv_write_pos = 0
	ring.batch_slot_idx = -1
	ring.batch_write_pos = 0
	ring.batch_pending = 0
	ring.pending_recv = nil
	ring.send_in_flight = false
	ring.tcp_socket = 0
	sync.atomic_store(&ring.last_activity_time, i64(0))
	sync.atomic_store(&ring.park_state, Ring_Park_State.Active)
	crypto.zero_explicit(&ring.transport_keys, size_of(Noise_Transport))
	sync.atomic_store_explicit(&ring.state, Connection_Ring_State.Buffering, .Release)

	return dropped
}

// Caller must be the ring's only reader: the IO thread has acked the park and
// released the ring, or has been stopped and joined. Returns true once the
// peer's EOF has been observed, meaning no more bytes will ever arrive.
ring_drain_socket :: proc(ring: ^Connection_Ring) -> bool {
	if ring.tcp_socket == 0 do return true
	if !sim_is_socket(ring.tcp_socket) do net.set_blocking(ring.tcp_socket, false)
	eof := false
	for {
		write_pos := ring.recv_write_pos
		available := ring.recv_buffer_size - write_pos
		if available == 0 {
			process_recv_buffer(ring)
			if ring.recv_write_pos == write_pos do break
			continue
		}
		dst := ring.recv_buffer[write_pos:write_pos + available]
		n := 0
		if sim_is_socket(ring.tcp_socket) {
			sim_eof: bool
			n, sim_eof = sim_drain_available(ring.tcp_socket, dst)
			if n <= 0 {
				eof = sim_eof
				break
			}
		} else {
			received, err := net.recv_tcp(ring.tcp_socket, dst)
			if err != nil {
				eof = err != .Would_Block && err != .Timeout
				break
			}
			if received == 0 {
				eof = true
				break
			}
			n = received
		}
		ring.recv_write_pos += u32(n)
		process_recv_buffer(ring)
	}
	if ring.recv_write_pos > 0 do process_recv_buffer(ring)
	return eof
}

ring_shutdown_write :: proc(ring: ^Connection_Ring) {
	if ring.tcp_socket == 0 do return
	if sim_is_socket(ring.tcp_socket) {
		sim_shutdown_write(ring.tcp_socket)
		return
	}
	_ = net.shutdown(ring.tcp_socket, .Send)
}

pool_add_draining :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring) {
	if pool.draining_count >= MAX_POOL_RINGS {
		log.error("Pool draining list full, leaking ring")
		return
	}
	pool.draining[pool.draining_count] = ring
	pool.draining_count += 1
}

pool_remove_draining_at :: proc(pool: ^Connection_Pool, idx: u32) {
	last := pool.draining_count - 1
	pool.draining[idx] = pool.draining[last]
	pool.draining[last] = nil
	pool.draining_count = last
}

@(private)
ring_io_attach :: proc(ring: ^Connection_Ring, owner: PID) -> bool {
	for _ in 0 ..< IO_ATTACH_RETRIES {
		_, swapped := sync.atomic_compare_exchange_strong_explicit(
			&ring.io_owner,
			0,
			u64(owner),
			.Acq_Rel,
			.Acquire,
		)
		if swapped do return true
		runtime_sleep(IO_ATTACH_RETRY_DELAY)
	}
	return false
}

@(private)
ring_io_release :: proc(ring: ^Connection_Ring) {
	sync.atomic_store_explicit(&ring.io_owner, 0, .Release)
}

@(private)
ring_signal_batch :: proc(ring: ^Connection_Ring) {
	if sync.atomic_exchange_explicit(&ring.batch_pending, 1, .Seq_Cst) == 0 do ring_wake_io(ring)
}

@(private)
ring_wake_io :: proc(ring: ^Connection_Ring) {
	target := ring
	if ring.pool != nil {
		if primary := atomic_load_ring_ptr(&ring.pool.rings[0]); primary != nil do target = primary
	}
	if sync.atomic_load_explicit(&target.io_sleeping, .Seq_Cst) == 0 do return
	sync.atomic_add_explicit(&target.io_wakers, 1, .Seq_Cst)
	loop := cast(^nbio.Event_Loop)rawptr(
		uintptr(sync.atomic_load_explicit(cast(^u64)&target.io_event_loop, .Seq_Cst)),
	)
	if loop != nil do nbio.wake_up(loop)
	sync.atomic_sub_explicit(&target.io_wakers, 1, .Release)
}

@(private)
acquire_slot :: proc(ring: ^Connection_Ring) -> (slot: ^Send_Slot, idx: u32, ok: bool) {
	write_idx := sync.atomic_load(&ring.send_write_idx)
	complete_idx := sync.atomic_load(&ring.send_complete_idx)

	if write_idx - complete_idx >= ring.send_slot_count {
		for spin := 0; spin < 4096; spin += 1 {
			intrinsics.cpu_relax()
			complete_idx = sync.atomic_load(&ring.send_complete_idx)
			if write_idx - complete_idx < ring.send_slot_count do break
		}
		if write_idx - complete_idx >= ring.send_slot_count do return nil, 0, false
	}

	sync.atomic_store(&ring.send_write_idx, write_idx + 1)

	slot_idx := write_idx & ring.send_mask
	slot = &ring.send_slots[slot_idx]

	for spin := 0; spin < 256; spin += 1 {
		if sync.atomic_load_explicit(&slot.state, .Acquire) == .FREE {
			slot.state = .WRITING
			slot.active_writers = 0
			return slot, slot_idx, true
		}
		intrinsics.cpu_relax()
	}

	pool_note_contention(ring.pool)
	return nil, 0, false
}

@(private)
pool_note_contention :: proc(pool: ^Connection_Pool) {
	if pool == nil || pool.max_rings <= 1 do return
	if sync.atomic_load_explicit(&pool.scale_up_requested, .Relaxed) != 0 do return
	count := sync.atomic_add(&pool.contention_count, 1)
	if count < pool.contention_threshold do return
	if _, swapped := sync.atomic_compare_exchange_strong(&pool.scale_up_requested, 0, 1);
	   swapped {
		conn_pid := PID(sync.atomic_load_explicit(&pool.conn_pid, .Acquire))
		if conn_pid != 0 {
			_ = send_message(conn_pid, Scale_Up_Request{})
		}
	}
}

@(private)
batch_seal_locked :: proc(ring: ^Connection_Ring, force: bool = false) {
	slot_idx := ring.batch_slot_idx
	if slot_idx < 0 do return

	if u32(slot_idx) >= ring.send_slot_count {
		log.errorf("Invalid batch_slot_idx: %d >= %d", slot_idx, ring.send_slot_count)
		ring.batch_slot_idx = -1
		ring.batch_write_pos = 0
		return
	}

	slot := &ring.send_slots[slot_idx]
	write_pos := ring.batch_write_pos

	if write_pos > ring.usable_slot_size {
		log.errorf("batch_write_pos %d exceeds usable slot size %d", write_pos, ring.usable_slot_size)
		ring.batch_slot_idx = -1
		ring.batch_write_pos = 0
		return
	}

	state := sync.atomic_load(&slot.state)
	if state != .WRITING {
		ring.batch_slot_idx = -1
		ring.batch_write_pos = 0
		return
	}

	active := sync.atomic_load(&slot.active_writers)

	if write_pos == 0 && active == 0 {
		sync.atomic_store(&slot.state, .FREE)
		ring.batch_slot_idx = -1
		ring.batch_write_pos = 0
		return
	}

	if !force && active > 0 do return

	slot.length = write_pos
	sync.atomic_store(&slot.seal_id, sync.atomic_add(&g_seal_counter, 1) + 1)
	ring.batch_slot_idx = -1
	ring.batch_write_pos = 0

	if active == 0 {
		when ODIN_DEBUG {
			data := slot_data(ring, u32(slot_idx))
			if !validate_batch_messages(data[:write_pos], slot_idx, write_pos) {
				log.errorf(
					"CRITICAL: Refusing to send corrupted batch, releasing slot %d",
					slot_idx,
				)
				sync.atomic_store(&slot.state, .FREE)
				return
			}
		}
		sync.atomic_store(&slot.state, .READY)
		ring_signal_batch(ring)
		sync.atomic_store(&ring.last_activity_time, time.to_unix_nanoseconds(now()))
	} else {
		sync.atomic_store(&slot.state, .SEALED)
		if sync.atomic_load(&slot.active_writers) == 0 {
			batch_promote_sealed(ring, u32(slot_idx))
		}
	}
}

@(private)
batch_promote_sealed :: proc(ring: ^Connection_Ring, slot_idx: u32) {
	slot := &ring.send_slots[slot_idx]
	when ODIN_DEBUG {
		data := slot_data(ring, slot_idx)
		if !validate_batch_messages(data[:slot.length], i32(slot_idx), slot.length) {
			log.errorf(
				"CRITICAL: Corrupted batch in slot %d on commit, releasing",
				slot_idx,
			)
			_, _ = sync.atomic_compare_exchange_strong(&slot.state, .SEALED, .FREE)
			return
		}
	}
	_, swapped := sync.atomic_compare_exchange_strong(&slot.state, .SEALED, .READY)
	if !swapped do return
	ring_signal_batch(ring)
	sync.atomic_store(&ring.last_activity_time, time.to_unix_nanoseconds(now()))
}

@(private)
validate_batch_messages :: proc(data: []byte, slot_idx: i32, write_pos: u32) -> bool {
	offset: u32 = 0

	for offset + 4 <= write_pos {
		msg_size := endian.unchecked_get_u32le(data[offset:])

		if msg_size == 0 {
			log.errorf("slot %d: zero size at offset %d", slot_idx, offset)
			return false
		}
		if msg_size > MAX_MESSAGE_SIZE {
			log.errorf("slot %d: invalid size %d at offset %d", slot_idx, msg_size, offset)
			return false
		}

		total_msg_size := 4 + msg_size
		if offset + total_msg_size > write_pos {
			log.errorf(
				"slot %d: msg at offset %d extends past write_pos %d",
				slot_idx,
				offset,
				write_pos,
			)
			return false
		}

		offset += total_msg_size
	}

	if offset != write_pos {
		log.errorf("slot %d: trailing bytes, offset=%d write_pos=%d", slot_idx, offset, write_pos)
		return false
	}

	return true
}

FLUSH_SPIN_ATTEMPTS :: 8

batch_flush :: proc(ring: ^Connection_Ring) {
	for _ in 0 ..< FLUSH_SPIN_ATTEMPTS {
		if sync.mutex_try_lock(&ring.batch_mutex) {
			batch_seal_locked(ring)
			sync.mutex_unlock(&ring.batch_mutex)
			return
		}
		intrinsics.cpu_relax()
	}
	ring_signal_batch(ring)
}

batch_append_message :: proc(ring: ^Connection_Ring, msg_data: []byte) -> bool {
	when ODIN_TEST {
		drop, dup, _ := frame_tap(.Out, frame_tap_out_hash(msg_data), msg_data, ring.node_id)
		if drop do return true
		if dup do _ = batch_append_raw(ring, msg_data)
	}
	return batch_append_raw(ring, msg_data)
}

batch_append_raw :: proc(target: ^Connection_Ring, msg_data: []byte) -> bool {
	ring := target
	if ring.pool != nil && sync.atomic_load(&ring.park_state) != .Active {
		if primary := atomic_load_ring_ptr(&ring.pool.rings[0]); primary != nil do ring = primary
	}
	msg_len := u32(len(msg_data))
	if msg_len == 0 do return true

	if msg_len > ring.usable_slot_size {
		log.errorf("Message too large for slot: %d > %d", msg_len, ring.usable_slot_size)
		return false
	}

	if msg_len >= 4 {
		incoming_size := endian.unchecked_get_u32le(msg_data[:])
		if incoming_size == 0 {
			log.errorf("batch_append_message: zero size prefix, msg_len=%d", msg_len)
			return false
		}
	}

	dst, sid, ok := batch_reserve(ring, msg_len)
	if !ok do return false

	intrinsics.mem_copy_non_overlapping(raw_data(dst), raw_data(msg_data), int(msg_len))
	batch_commit(ring, sid)
	return true
}

ring_full_backoff :: proc(retry: int) {
	if retry < RING_SEND_SPIN_RETRIES {
		intrinsics.cpu_relax()
	} else {
		runtime_sleep(1 * time.Microsecond)
	}
}

batch_append_message_retry :: proc(ring: ^Connection_Ring, msg_data: []byte) -> bool {
	when ODIN_TEST {
		drop, dup, _ := frame_tap(.Out, frame_tap_out_hash(msg_data), msg_data, ring.node_id)
		if drop do return true
		if dup do _ = batch_append_raw(ring, msg_data)
	}
	for retry in 0 ..< RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES {
		if batch_append_raw(ring, msg_data) do return true
		ring_full_backoff(retry)
	}
	return false
}

@(private)
batch_reserve :: proc(
	ring: ^Connection_Ring,
	exact_size: u32,
) -> (
	dst: []byte,
	slot_idx: u32,
	ok: bool,
) {
	if exact_size == 0 || exact_size > ring.usable_slot_size do return nil, 0, false

	if !sync.mutex_try_lock(&ring.batch_mutex) {
		pool_note_contention(ring.pool)
		sync.mutex_lock(&ring.batch_mutex)
	}

	batch_idx := ring.batch_slot_idx
	if batch_idx >= 0 {
		remaining := ring.usable_slot_size - ring.batch_write_pos
		if exact_size <= remaining {
			offset := ring.batch_write_pos
			ring.batch_write_pos += exact_size

			slot := &ring.send_slots[batch_idx]
			sync.atomic_add(&slot.active_writers, 1)

			remaining_after := ring.usable_slot_size - ring.batch_write_pos
			if remaining_after < ring.nearly_full_threshold {
				batch_seal_locked(ring, force = true)
			} else {
				ring_signal_batch(ring)
			}

			sync.mutex_unlock(&ring.batch_mutex)
			data := slot_data(ring, u32(batch_idx))
			return data[offset:offset + exact_size], u32(batch_idx), true
		}

		batch_seal_locked(ring, force = true)
	}

	_, new_slot_idx, acquired := acquire_slot(ring)
	if !acquired {
		sync.mutex_unlock(&ring.batch_mutex)
		return nil, 0, false
	}

	ring.batch_slot_idx = i32(new_slot_idx)
	ring.batch_write_pos = exact_size

	slot := &ring.send_slots[new_slot_idx]
	sync.atomic_add(&slot.active_writers, 1)

	remaining_after := ring.usable_slot_size - exact_size
	if remaining_after < ring.nearly_full_threshold {
		batch_seal_locked(ring, force = true)
	} else {
		ring_signal_batch(ring)
	}

	sync.mutex_unlock(&ring.batch_mutex)

	data := slot_data(ring, new_slot_idx)
	return data[0:exact_size], new_slot_idx, true
}

@(private)
batch_commit :: proc(ring: ^Connection_Ring, slot_idx: u32) {
	slot := &ring.send_slots[slot_idx]
	old := sync.atomic_sub(&slot.active_writers, 1)
	assert(old >= 1, "batch_commit without a matching reserve, active_writers underflow")

	if old == 1 {
		state := sync.atomic_load(&slot.state)
		if state == .DISCARDED {
			slot.length = 0
			sync.atomic_store(&slot.state, .FREE)
			return
		}
		if state == .SEALED {
			batch_promote_sealed(ring, slot_idx)
		} else if state == .WRITING {
			ring_signal_batch(ring)
		}
	}
}

@(private)
batch_abort :: proc(ring: ^Connection_Ring, slot_idx: u32, dst: []byte) {
	if len(dst) >= 4 {
		body_len := u32(len(dst) - 4)
		endian.put_u32(dst[0:4], .Little, body_len)
		for i in 4 ..< len(dst) {
			dst[i] = 0
		}
	}
	batch_commit(ring, slot_idx)
}

MAX_SEND_BATCH :: 8

submit_nbio_sends :: proc(ring: ^Connection_Ring) {
	if ring.send_in_flight do return

	write_idx := sync.atomic_load(&ring.send_write_idx)
	if ring.send_submit_idx >= write_idx do return

	assert(
		ring.tcp_socket != 0,
		"submitting sends on a ring whose socket is already closed",
	)

	batch_count: u32 = 0
	check_idx := ring.send_submit_idx

	for check_idx < write_idx && batch_count < MAX_SEND_BATCH {
		slot_idx := check_idx & ring.send_mask
		slot := &ring.send_slots[slot_idx]

		if sync.atomic_load_explicit(&slot.state, .Acquire) != .READY do break

		if ring.encrypted {
			stride := int(ring.usable_slot_size) + ENVELOPE_OVERHEAD
			region := ring.seal_scratch[int(batch_count) * stride:int(batch_count + 1) * stride]
			sealed_len, sealed := envelope_seal(
				&ring.transport_keys,
				slot_data(ring, slot_idx)[:slot.length],
				region,
			)
			if !sealed {
				log.error("Envelope seal failed")
				notify_ring_error(ring, "seal failure")
				return
			}
			ring.send_bufs[batch_count] = region[:sealed_len]
		} else {
			ring.send_bufs[batch_count] = slot_data(ring, slot_idx)[:slot.length]
		}
		batch_count += 1
		check_idx += 1
	}

	if batch_count == 0 do return

	if sim_is_socket(ring.tcp_socket) {
		sim_ring_send(ring, batch_count)
		return
	}

	nbio.send_poly2(
		ring.tcp_socket,
		ring.send_bufs[:batch_count],
		ring,
		batch_count,
		nbio_send_callback,
		all = true,
	)
	ring.send_in_flight = true
}

nbio_send_callback :: proc(op: ^nbio.Operation, ring: ^Connection_Ring, batch_count: u32) {
	ring.send_in_flight = false

	for _ in 0 ..< batch_count {
		slot_idx := ring.send_submit_idx & ring.send_mask
		slot := &ring.send_slots[slot_idx]
		assert(
			sync.atomic_load(&slot.active_writers) == 0,
			"send slot freed while a writer is still copying into it",
		)
		slot.length = 0
		sync.atomic_store_explicit(&slot.state, .FREE, .Release)
		ring.send_submit_idx += 1
	}
	sync.atomic_add(&ring.send_complete_idx, batch_count)

	if op.send.err != nil {
		if sync.atomic_load(&ring.io_stop) == 0 {
			tcp_err, is_tcp := op.send.err.(net.TCP_Send_Error)
			peer_lost := is_tcp && tcp_err == .Connection_Closed
			if peer_lost {
				log.warnf("connection lost during send: %v", tcp_err)
			} else {
				log.errorf("async send error: %v", op.send.err)
			}
			notify_ring_error(ring, "send error")
		}
		return
	}

	if sync.atomic_load(&ring.state) == .Ready do submit_nbio_sends(ring)
}

submit_nbio_recv :: proc(ring: ^Connection_Ring) {
	if ring.pending_recv != nil do return

	write_pos := ring.recv_write_pos
	available := ring.recv_buffer_size - write_pos
	if available < 1024 {
		if write_pos > 0 {
			log.warnf(
				"recv buffer near-full: write_pos=%d/%d, no recv posted",
				write_pos,
				ring.recv_buffer_size,
			)
		}
		return
	}

	recv_buf := ring.recv_buffer[write_pos:write_pos + available]
	if sim_is_socket(ring.tcp_socket) {
		ring.pending_recv = sim_ring_post_recv(ring, recv_buf)
		return
	}
	ring.pending_recv = nbio.recv_poly(ring.tcp_socket, {recv_buf}, ring, nbio_recv_callback)
}

nbio_recv_callback :: proc(op: ^nbio.Operation, ring: ^Connection_Ring) {
	ring.pending_recv = nil

	if op.recv.err != nil {
		if sync.atomic_load(&ring.io_stop) == 0 {
			tcp_err, is_tcp := op.recv.err.(net.TCP_Recv_Error)
			peer_lost := is_tcp && tcp_err == .Connection_Closed
			if peer_lost {
				log.warnf("connection lost: %v", tcp_err)
			} else {
				log.errorf("recv error: %v", op.recv.err)
			}
			notify_ring_error(ring, "recv error")
		}
		return
	}

	bytes_recvd := u32(op.recv.received)
	if bytes_recvd == 0 {
		if sync.atomic_load(&ring.io_stop) == 0 {
			log.info("Connection closed by peer")
			notify_ring_error(ring, "peer closed")
		}
		return
	}

	new_write_pos := ring.recv_write_pos + bytes_recvd
	if new_write_pos > ring.recv_buffer_size {
		notify_ring_error(ring, "recv buffer overflow")
		return
	}

	ring.recv_write_pos = new_write_pos
	sync.atomic_store(&ring.last_activity_time, time.to_unix_nanoseconds(now()))
	process_recv_buffer(ring)

	if sync.atomic_load(&ring.state) == .Ready do submit_nbio_recv(ring)
}

@(private)
g_nbio_probe_mutex: sync.Mutex
@(private)
g_nbio_probed: bool
@(private)
g_nbio_available: bool

nbio_available :: proc() -> bool {
	if NODE.config.sim_mode do return true

	sync.mutex_lock(&g_nbio_probe_mutex)
	defer sync.mutex_unlock(&g_nbio_probe_mutex)

	if !g_nbio_probed {
		g_nbio_probed = true
		if err := nbio.acquire_thread_event_loop(); err != nil {
			log.errorf(
				"Async IO backend (nbio/io_uring) unavailable on this host: %v. actod networking requires io_uring support (recent Linux kernel); remote messaging is disabled. Set network.port = 0 for a local-only node, or run on a host with io_uring. If the error is Allocation_Failed, the io_uring queues exceeded RLIMIT_MEMLOCK (ulimit -l): rebuild with -define:ODIN_NBIO_QUEUE_SIZE=256 or raise the limit.",
				err,
			)
			g_nbio_available = false
		} else {
			nbio.release_thread_event_loop()
			g_nbio_available = true
		}
	}

	return g_nbio_available
}

nbio_io_loop :: proc(t: ^thread.Thread) {
	ctx := cast(^IO_Context)t.user_args[0]
	if ctx == nil do return

	ring := ctx.ring
	context.allocator = ctx.allocator
	context.logger = ctx.logger

	if !ring_io_attach(ring, ctx.conn_pid) {
		log.warn("IO attach timed out, previous owner still active, closing to reconnect")
		_ = send_message(ctx.conn_pid, Close_Connection{reason = "io attach timeout"})
		return
	}
	defer ring_io_release(ring)

	if err := nbio.acquire_thread_event_loop(); err != nil {
		log.errorf(
			"Failed to acquire NBIO event loop: %v. Each connection's IO thread creates an io_uring instance whose queues count against RLIMIT_MEMLOCK (ulimit -l), so this typically means the process holds too many connections for the limit. Rebuild with -define:ODIN_NBIO_QUEUE_SIZE=256 (default 2048) to shrink each instance, or raise the memlock limit.",
			err,
		)
		_ = send_message(ctx.conn_pid, Close_Connection{reason = "nbio unavailable"})
		return
	}
	defer nbio.release_thread_event_loop()

	sync.atomic_store_explicit(
		cast(^u64)&ring.io_event_loop,
		u64(uintptr(nbio.current_thread_event_loop())),
		.Seq_Cst,
	)
	defer {
		sync.atomic_store_explicit(cast(^u64)&ring.io_event_loop, 0, .Seq_Cst)
		for sync.atomic_load_explicit(&ring.io_wakers, .Seq_Cst) != 0 {
			intrinsics.cpu_relax()
		}
	}

	if err := nbio.associate_socket(ring.tcp_socket); err != nil {
		if sync.atomic_load(&ring.io_stop) == 0 {
			log.warnf("Failed to associate socket, closing to reconnect: %v", err)
			_ = send_message(ctx.conn_pid, Close_Connection{reason = "nbio associate failed"})
		}
		return
	}

	ring.pending_recv = nil
	ring.send_in_flight = false
	ring.recv_write_pos = 0
	sync.atomic_store_explicit(&ring.state, Connection_Ring_State.Ready, .Release)

	submit_nbio_recv(ring)
	submit_nbio_sends(ring)

	pool := ring.pool
	idle_ticks: u32 = 0

	for sync.atomic_load(&ring.io_stop) == 0 {
		free_all(context.temp_allocator)
		if sync.atomic_exchange(&ring.batch_pending, 0) != 0 do batch_flush(ring)
		submit_nbio_sends(ring)

		if pool != nil do io_service_pool_rings(pool, ring, ctx.conn_pid)

		any_active := ring.send_in_flight
		if !any_active && pool != nil do any_active = io_pool_any_in_flight(pool, ring)

		timeout: time.Duration
		if any_active {
			idle_ticks = 0
			timeout = TICK_ACTIVE_TIMEOUT
		} else if idle_ticks < TICK_IDLE_THRESHOLD {
			idle_ticks += 1
			timeout = TICK_ACTIVE_TIMEOUT
		} else {
			timeout = TICK_IDLE_TIMEOUT
		}

		if !any_active {
			sync.atomic_store_explicit(&ring.io_sleeping, 1, .Seq_Cst)
			if io_any_batch_pending(ring, pool) {
				sync.atomic_store_explicit(&ring.io_sleeping, 0, .Relaxed)
				continue
			}
		}

		err := nbio.tick(timeout)
		sync.atomic_store_explicit(&ring.io_sleeping, 0, .Relaxed)
		if err != nil {
			log.errorf("NBIO tick error: %v", err)
			notify_ring_error(ring, "nbio error")
			break
		}
	}

	if ring.pending_recv != nil {
		nbio.remove(ring.pending_recv)
		ring.pending_recv = nil
	}
	if pool != nil do io_release_pool_rings(pool, ring, ctx.conn_pid)
}

@(private)
io_service_pool_rings :: proc(pool: ^Connection_Pool, primary: ^Connection_Ring, owner: PID) {
	count := sync.atomic_load_explicit(&pool.ring_count, .Acquire)
	for i: u32 = 1; i < count; i += 1 {
		pr := atomic_load_ring_ptr(&pool.rings[i])
		if pr == nil || pr == primary do continue

		owned := sync.atomic_load_explicit(&pr.io_owner, .Acquire) == u64(owner)

		park := sync.atomic_load(&pr.park_state)
		if park == .Park_Asked {
			if owned {
				if pr.pending_recv != nil {
					nbio.remove(pr.pending_recv)
					pr.pending_recv = nil
				}
				sync.atomic_store_explicit(&pr.state, Connection_Ring_State.Buffering, .Release)
				ring_io_release(pr)
				sync.atomic_store(&pr.park_state, Ring_Park_State.Park_Acked)
			}
			continue
		}
		if park != .Active do continue

		if !owned {
			if pr.tcp_socket == 0 do continue
			_, swapped := sync.atomic_compare_exchange_strong_explicit(
				&pr.io_owner,
				0,
				u64(owner),
				.Acq_Rel,
				.Acquire,
			)
			if !swapped do continue
			if err := nbio.associate_socket(pr.tcp_socket); err != nil {
				log.errorf("Failed to associate pool ring socket: %v", err)
				ring_io_release(pr)
				notify_ring_error(pr, "pool ring associate failed")
				continue
			}
			pr.pending_recv = nil
			pr.send_in_flight = false
			pr.recv_write_pos = 0
			sync.atomic_store_explicit(&pr.state, Connection_Ring_State.Ready, .Release)
			submit_nbio_recv(pr)
		}

		if sync.atomic_exchange(&pr.batch_pending, 0) != 0 do batch_flush(pr)
		submit_nbio_sends(pr)
	}
}

@(private)
io_any_batch_pending :: proc(ring: ^Connection_Ring, pool: ^Connection_Pool) -> bool {
	if sync.atomic_load_explicit(&ring.batch_pending, .Seq_Cst) != 0 do return true
	if pool == nil do return false
	count := sync.atomic_load_explicit(&pool.ring_count, .Acquire)
	for i: u32 = 1; i < count; i += 1 {
		pr := atomic_load_ring_ptr(&pool.rings[i])
		if pr != nil && pr != ring && sync.atomic_load_explicit(&pr.batch_pending, .Seq_Cst) != 0 {
			return true
		}
	}
	return false
}

@(private)
io_pool_any_in_flight :: proc(pool: ^Connection_Pool, primary: ^Connection_Ring) -> bool {
	count := sync.atomic_load_explicit(&pool.ring_count, .Acquire)
	for i: u32 = 1; i < count; i += 1 {
		pr := atomic_load_ring_ptr(&pool.rings[i])
		if pr != nil && pr != primary && pr.send_in_flight do return true
	}
	return false
}

@(private)
io_release_pool_rings :: proc(pool: ^Connection_Pool, primary: ^Connection_Ring, owner: PID) {
	count := sync.atomic_load_explicit(&pool.ring_count, .Acquire)
	for i: u32 = 1; i < count; i += 1 {
		pr := atomic_load_ring_ptr(&pool.rings[i])
		if pr == nil || pr == primary do continue
		if sync.atomic_load_explicit(&pr.io_owner, .Acquire) != u64(owner) do continue
		if pr.pending_recv != nil {
			nbio.remove(pr.pending_recv)
			pr.pending_recv = nil
		}
		sync.atomic_store_explicit(&pr.state, Connection_Ring_State.Buffering, .Release)
		ring_io_release(pr)
	}
}

@(private)
ring_dispatch_envelope :: proc(ring: ^Connection_Ring, envelope: []byte) {
	plaintext, ok := envelope_open(&ring.transport_keys, envelope, ring.open_scratch)
	if !ok {
		log.error("Failed to open sealed envelope")
		notify_ring_error(ring, "decrypt failure")
		return
	}

	remaining, err := process_recv_frames(
		ring.open_scratch,
		u32(len(plaintext)),
		ring,
		process_complete_message,
	)
	if err != .None || remaining != 0 {
		log.error("Corrupt frame inside sealed envelope")
		notify_ring_error(ring, "corrupt envelope")
	}
}

process_recv_buffer :: proc(ring: ^Connection_Ring) {
	dispatch := ring.encrypted ? ring_dispatch_envelope : process_complete_message
	new_pos, err := process_recv_frames(ring.recv_buffer, ring.recv_write_pos, ring, dispatch)
	if err != .None {
		reason: string
		switch err {
		case .Zero_Size:
			reason = "zero message size"
		case .Too_Large:
			reason = "message too large"
		case .None:
			unreachable()
		}
		log.errorf("recv frame error: %s", reason)
		notify_ring_error(ring, reason)
		ring.recv_write_pos = 0
		return
	}
	ring.recv_write_pos = new_pos
}

process_complete_message :: proc(ring: ^Connection_Ring, msg_data: []byte) {
	when ODIN_TEST {
		drop, dup, _ := frame_tap(.In, frame_tap_in_hash(msg_data), msg_data, ring.node_id)
		if drop do return
		if dup do process_complete_message_impl(ring, msg_data)
	}
	process_complete_message_impl(ring, msg_data)
}

@(private = "file")
process_complete_message_impl :: proc(ring: ^Connection_Ring, msg_data: []byte) {
	if sync.atomic_load(&ring.io_stop) != 0 do return

	header, ok := parse_network_header(msg_data)
	if !ok {
		log.warn("Failed to parse network header")
		return
	}

	if .LIFECYCLE_EVENT in header.flags &&
	   !sim_is_socket(ring.tcp_socket) &&
	   handle_lifecycle_event_inline(ring.node_id, header.type_hash, header.payload) {
		return
	}

	if .CONTROL in header.flags || .LIFECYCLE_EVENT in header.flags {
		msg_copy := make([]byte, len(msg_data))
		copy(msg_copy, msg_data)
		remote_msg := Remote_Message {
			from = pack_pid(Handle{}, ring.node_id),
			data = msg_copy,
		}
		err := send_message(ring.conn_pid, remote_msg)
		if err != .OK do log.warnf("Failed to send control/lifecycle message: %v", err)
		delete(msg_copy)
		return
	}

	deliver_to_target(
		ring.node_id,
		header.flags,
		header.type_hash,
		header.from_handle,
		header.to_handle,
		header.to_name,
		header.payload,
		header.ask_token,
	)
}

notify_ring_error :: proc(ring: ^Connection_Ring, reason: string) {
	pool := ring.pool
	if pool != nil {
		primary := atomic_load_ring_ptr(&pool.rings[0])
		if primary != nil && ring != primary {
			_ = send_message(ring.conn_pid, Pool_Ring_Closed{ring_ptr = u64(uintptr(ring))})
			return
		}
	}
	_ = send_message(ring.conn_pid, Close_Connection{reason = reason})
}

send_raw_via_ring :: proc(ring: ^Connection_Ring, raw_data_with_size: []byte) -> bool {
	if ring == nil do return false
	return batch_append_message(ring, raw_data_with_size)
}

send_to_connection_ring :: #force_inline proc(
	ring: ^Connection_Ring,
	to: PID,
	content: $T,
	base_flags: Network_Message_Flags = {},
) -> Send_Error {
	v := content
	return send_to_connection_ring_impl(
		ring,
		to,
		&v,
		get_validated_message_info_ptr(T),
		base_flags,
	)
}

send_to_connection_ring_by_name :: #force_inline proc(
	ring: ^Connection_Ring,
	actor_name: string,
	content: $T,
	base_flags: Network_Message_Flags = {},
) -> Send_Error {
	v := content
	return send_to_connection_ring_by_name_impl(
		ring,
		actor_name,
		&v,
		get_validated_message_info_ptr(T),
		base_flags,
	)
}

make_connection_pool :: proc(
	node_id: Node_ID,
	config: Connection_Ring_Config,
	allocator := context.allocator,
) -> ^Connection_Pool {
	pool := new(Connection_Pool, allocator)
	if pool == nil do return nil
	pool.node_id = node_id
	pool.max_rings = clamp(config.max_pool_rings, 1, MAX_POOL_RINGS)
	pool.contention_threshold = config.scale_up_contention_threshold
	if pool.contention_threshold == 0 do pool.contention_threshold = 100
	return pool
}

// Active-ring mutation is conn-actor-thread only; readers (producers, IO) go
// through the atomic ring pointers and ring_count.
pool_add_ring :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring) -> bool {
	if pool == nil || ring == nil do return false
	count := sync.atomic_load(&pool.ring_count)
	if count >= pool.max_rings do return false
	ring.pool = pool
	atomic_store_ring_ptr(&pool.rings[count], ring)
	sync.atomic_store_explicit(&pool.ring_count, count + 1, .Release)
	return true
}

pool_remove_active :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring) -> bool {
	count := sync.atomic_load(&pool.ring_count)
	for i: u32 = 1; i < count; i += 1 {
		if atomic_load_ring_ptr(&pool.rings[i]) != ring do continue
		last := count - 1
		if i != last {
			atomic_store_ring_ptr(&pool.rings[i], atomic_load_ring_ptr(&pool.rings[last]))
		}
		atomic_store_ring_ptr(&pool.rings[last], nil)
		sync.atomic_store_explicit(&pool.ring_count, last, .Release)
		return true
	}
	return false
}

pool_take_parked :: proc(pool: ^Connection_Pool) -> ^Connection_Ring {
	if pool.parked_count == 0 do return nil
	pool.parked_count -= 1
	ring := pool.parked[pool.parked_count]
	pool.parked[pool.parked_count] = nil
	return ring
}

pool_park :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring) {
	if pool.parked_count >= MAX_POOL_RINGS {
		log.error("Pool parked list full, leaking ring")
		return
	}
	pool.parked[pool.parked_count] = ring
	pool.parked_count += 1
}

pool_active_count :: #force_inline proc(pool: ^Connection_Pool) -> u32 {
	return sync.atomic_load_explicit(&pool.ring_count, .Acquire)
}

get_pool_ring_at :: #force_inline proc(pool: ^Connection_Pool, idx: u32) -> ^Connection_Ring {
	if idx >= sync.atomic_load_explicit(&pool.ring_count, .Acquire) do return nil
	return atomic_load_ring_ptr(&pool.rings[idx])
}

get_pool_ring_ready :: proc(pool: ^Connection_Pool) -> ^Connection_Ring {
	count := sync.atomic_load_explicit(&pool.ring_count, .Acquire)
	if count == 0 do return nil

	start: u32
	if w := current_worker; w != nil {
		start = u32(w.id)
	} else {
		start = sync.atomic_add(&pool.next_ring, 1)
	}
	for i in 0 ..< count {
		idx := (start + u32(i)) % count
		r := atomic_load_ring_ptr(&pool.rings[idx])
		if r != nil &&
		   sync.atomic_load(&r.state) == .Ready &&
		   sync.atomic_load(&r.park_state) == .Active {
			return r
		}
	}
	return atomic_load_ring_ptr(&pool.rings[0])
}

@(private)
atomic_load_ring_ptr :: #force_inline proc(slot: ^^Connection_Ring) -> ^Connection_Ring {
	return(
		cast(^Connection_Ring)rawptr(
			uintptr(sync.atomic_load_explicit(cast(^u64)slot, .Acquire)),
		) \
	)
}

@(private)
atomic_store_ring_ptr :: #force_inline proc(slot: ^^Connection_Ring, ring: ^Connection_Ring) {
	sync.atomic_store_explicit(cast(^u64)slot, u64(uintptr(ring)), .Release)
}

get_or_create_node_ring :: proc(
	node_id: Node_ID,
	config: Connection_Ring_Config,
) -> ^Connection_Ring {
	if node_id == 0 || node_id >= MAX_NODES do return nil

	ring := atomic_load_ring_ptr(&NODE.connection_rings[node_id])
	if ring != nil do return ring

	new_pool := make_connection_pool(node_id, config, get_system_allocator())
	if new_pool == nil do return nil

	new_ring := make_connection_ring(
		config,
		NODE.config.network.enable_encryption,
		get_system_allocator(),
	)
	if new_ring == nil {
		free(new_pool, get_system_allocator())
		return nil
	}
	new_ring.node_id = node_id
	new_ring.pool = new_pool
	atomic_store_ring_ptr(&new_pool.rings[0], new_ring)
	sync.atomic_store_explicit(&new_pool.ring_count, u32(1), .Release)

	old, swapped := sync.atomic_compare_exchange_strong_explicit(
		cast(^u64)&NODE.connection_rings[node_id],
		u64(0),
		u64(uintptr(new_ring)),
		.Acq_Rel,
		.Acquire,
	)
	if !swapped {
		destroy_connection_ring(new_ring, get_system_allocator())
		free(new_pool, get_system_allocator())
		return cast(^Connection_Ring)rawptr(uintptr(old))
	}
	sync.atomic_store_explicit(
		cast(^u64)&NODE.connection_pools[node_id],
		u64(uintptr(new_pool)),
		.Release,
	)
	return new_ring
}

get_connection_pool :: #force_inline proc(node_id: Node_ID) -> ^Connection_Pool {
	if node_id == 0 || node_id >= MAX_NODES do return nil
	return cast(^Connection_Pool)rawptr(
		uintptr(sync.atomic_load_explicit(cast(^u64)&NODE.connection_pools[node_id], .Acquire)),
	)
}

find_pool_owner_by_join_token :: proc(token: u64) -> (PID, ^Connection_Pool) {
	if token == 0 do return 0, nil
	for i in 2 ..< MAX_NODES {
		pool := get_connection_pool(Node_ID(i))
		if pool == nil do continue
		if sync.atomic_load_explicit(&pool.join_token, .Acquire) == token {
			return PID(sync.atomic_load_explicit(&pool.conn_pid, .Acquire)), pool
		}
	}
	return 0, nil
}

register_connection_ring :: proc(node_id: Node_ID, ring: ^Connection_Ring) {
	if node_id == 0 || node_id >= MAX_NODES || ring == nil do return
	atomic_store_ring_ptr(&NODE.connection_rings[node_id], ring)
}

get_connection_ring :: #force_inline proc(node_id: Node_ID) -> ^Connection_Ring {
	if node_id == 0 || node_id >= MAX_NODES do return nil
	ring := atomic_load_ring_ptr(&NODE.connection_rings[node_id])
	if ring != nil {
		pool := ring.pool
		if pool != nil && sync.atomic_load_explicit(&pool.ring_count, .Acquire) > 1 {
			return get_pool_ring_ready(pool)
		}
	}
	return ring
}

@(private)
destroy_ring_if_quiesced :: proc(ring: ^Connection_Ring, node_id: int) -> bool {
	sync.atomic_store(&ring.io_stop, 1)
	released := false
	for _ in 0 ..< 1000 {
		if sync.atomic_load_explicit(&ring.io_owner, .Acquire) == 0 {
			released = true
			break
		}
		runtime_sleep(1 * time.Millisecond)
	}
	if !released || ring.io_thread != nil {
		log.errorf("Leaking connection ring for node %d: IO thread never cleaned up", node_id)
		return false
	}
	destroy_connection_ring(ring, get_system_allocator())
	return true
}

destroy_all_connection_rings :: proc() {
	for i in 1 ..< MAX_NODES {
		ring := atomic_load_ring_ptr(&NODE.connection_rings[i])
		pool := get_connection_pool(Node_ID(i))
		if ring == nil && pool == nil do continue

		conn_pid := PID(sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[i], .Acquire))
		if conn_pid != 0 {
			log.errorf("Leaking connection ring for node %d: connection actor still alive", i)
			continue
		}

		leaked := false
		if pool != nil {
			count := sync.atomic_load(&pool.ring_count)
			for r: u32 = 1; r < count; r += 1 {
				pr := atomic_load_ring_ptr(&pool.rings[r])
				atomic_store_ring_ptr(&pool.rings[r], nil)
				if pr != nil && pr != ring && !destroy_ring_if_quiesced(pr, i) do leaked = true
			}
			for p in 0 ..< pool.parked_count {
				if pool.parked[p] != nil && !destroy_ring_if_quiesced(pool.parked[p], i) {
					leaked = true
				}
				pool.parked[p] = nil
			}
			pool.parked_count = 0
			sync.atomic_store(&pool.ring_count, u32(0))
		}

		if ring != nil {
			atomic_store_ring_ptr(&NODE.connection_rings[i], nil)
			if !destroy_ring_if_quiesced(ring, i) do leaked = true
		}

		if pool != nil && !leaked {
			sync.atomic_store_explicit(cast(^u64)&NODE.connection_pools[i], u64(0), .Release)
			free(pool, get_system_allocator())
		}
	}
}
