package actod

import "base:intrinsics"
import "base:runtime"
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

Send_Slot_State :: enum u32 {
	FREE    = 0,
	WRITING = 1,
	SEALED  = 2,
	READY   = 3,
}

Send_Slot :: struct #align (CACHE_LINE_SIZE) {
	state:          Send_Slot_State,
	length:         u32,
	active_writers: i32,
}

@(private)
slot_data :: #force_inline proc(ring: ^Connection_Ring, slot_idx: u32) -> []byte {
	offset := int(slot_idx) * int(ring.send_slot_size)
	return ring.send_data_buffer[offset:offset + int(ring.send_slot_size)]
}

Connection_Ring_State :: enum {
	Not_Initialized,
	Ready,
	Draining,
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

Connection_Ring :: struct {
	socket:                net.Socket,
	tcp_socket:            net.TCP_Socket,
	node_id:               Node_ID,
	conn_pid:              PID,
	ring_idx:              u32,
	state:                 Connection_Ring_State,
	send_mask:             u32,
	send_slot_size:        u32,
	send_slot_count:       u32,
	send_slots:            []Send_Slot,
	send_data_buffer:      []byte,
	recv_buffer:           []byte,
	recv_buffer_size:      u32,
	tcp_nodelay:           bool,
	pool:                  ^Connection_Pool,
	last_send_time:        i64, // atomic — unix nanos, updated by batch_flush
	_pad_producer:         [CACHE_LINE_SIZE]byte,
	batch_mutex:           sync.Mutex,
	batch_slot_idx:        i32,
	batch_write_pos:       u32,
	nearly_full_threshold: u32,
	send_write_idx:        u32,
	batch_pending:         u32,
	_pad_consumer:         [CACHE_LINE_SIZE]byte,
	send_submit_idx:       u32,
	send_complete_idx:     u32,
	recv_write_pos:        u32,
	pending_recv:          ^nbio.Operation,
	send_in_flight:        bool,
	send_bufs:             [][]byte,
}

MAX_POOL_RINGS :: 16

Scale_Up_Request :: struct {}

Connection_Pool :: struct {
	rings:                [MAX_POOL_RINGS]^Connection_Ring,
	ring_count:           u32, // atomic
	next_ring:            u32, // atomic — round-robin counter
	contention_count:     u32, // atomic — acquire_slot spin failures
	scale_up_requested:   u32, // atomic flag — 1 = request sent to connection actor
	node_id:              Node_ID,
	conn_pid:             PID,
	max_rings:            u32,
	contention_threshold: u32,
	draining_rings:       [MAX_POOL_RINGS]^Connection_Ring, // actor writes, IO reads
	drain_count:          u32, // atomic
	drained_rings:        [MAX_POOL_RINGS]^Connection_Ring, // IO writes, actor reads
	drained_count:        u32, // atomic
}

IO_Context :: struct {
	ring:      ^Connection_Ring,
	pool:      ^Connection_Pool,
	stop_flag: ^i32,
	conn_pid:  PID,
	allocator: runtime.Allocator,
	logger:    runtime.Logger,
}

create_connection_ring :: proc(
	config: Connection_Ring_Config,
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

	ring.send_slots = make([]Send_Slot, config.send_slot_count, allocator)
	if ring.send_slots == nil {
		free(ring, allocator)
		return nil
	}

	send_data_size := int(config.send_slot_count) * int(config.send_slot_size)
	ring.send_data_buffer = make([]byte, send_data_size, allocator)
	if ring.send_data_buffer == nil {
		delete(ring.send_slots, allocator)
		free(ring, allocator)
		return nil
	}

	for i in 0 ..< config.send_slot_count {
		ring.send_slots[i] = Send_Slot {
			state          = .FREE,
			length         = 0,
			active_writers = 0,
		}
	}

	ring.recv_buffer_size = config.recv_buffer_size
	ring.recv_buffer = make([]byte, config.recv_buffer_size, allocator)
	if ring.recv_buffer == nil {
		delete(ring.send_data_buffer, allocator)
		delete(ring.send_slots, allocator)
		free(ring, allocator)
		return nil
	}

	ring.send_bufs = make([][]byte, MAX_SEND_BATCH, allocator)
	if ring.send_bufs == nil {
		delete(ring.recv_buffer, allocator)
		delete(ring.send_data_buffer, allocator)
		delete(ring.send_slots, allocator)
		free(ring, allocator)
		return nil
	}

	ring.state = .Not_Initialized
	ring.batch_slot_idx = -1
	ring.batch_write_pos = 0
	ring.nearly_full_threshold = max(ring.send_slot_size / 8, 1024)

	return ring
}

init_connection_ring_nbio :: proc(ring: ^Connection_Ring) -> bool {
	if ring == nil {
		return false
	}

	when !nbio.FULLY_SUPPORTED {
		log.error("NBIO not fully supported on this platform")
		return false
	}

	ring.tcp_socket = net.TCP_Socket(ring.socket)
	ring.pending_recv = nil
	ring.send_in_flight = false
	return true
}

reset_connection_ring :: proc(ring: ^Connection_Ring) {
	if ring == nil do return

	for i in 0 ..< ring.send_slot_count {
		ring.send_slots[i].state = .FREE
		ring.send_slots[i].length = 0
		ring.send_slots[i].active_writers = 0
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
	ring.state = .Not_Initialized
}

destroy_connection_ring :: proc(ring: ^Connection_Ring, allocator := context.allocator) {
	if ring == nil {
		return
	}

	if ring.recv_buffer != nil do delete(ring.recv_buffer, allocator)
	if ring.send_data_buffer != nil do delete(ring.send_data_buffer, allocator)
	if ring.send_slots != nil do delete(ring.send_slots, allocator)
	if ring.send_bufs != nil do delete(ring.send_bufs, allocator)
	free(ring, allocator)
}

@(private)
acquire_slot :: proc(ring: ^Connection_Ring) -> (slot: ^Send_Slot, idx: u32, ok: bool) {
	if ring == nil || ring.state != .Ready {
		return nil, 0, false
	}

	write_idx := sync.atomic_load(&ring.send_write_idx)
	complete_idx := sync.atomic_load(&ring.send_complete_idx)

	if write_idx - complete_idx >= ring.send_slot_count {
		for spin := 0; spin < 4096; spin += 1 {
			intrinsics.cpu_relax()
			complete_idx = sync.atomic_load(&ring.send_complete_idx)
			if write_idx - complete_idx < ring.send_slot_count {
				break
			}
		}
		if write_idx - complete_idx >= ring.send_slot_count {
			request_pool_scale_up(ring.pool)
			return nil, 0, false
		}
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

	request_pool_scale_up(ring.pool)
	return nil, 0, false
}

@(private)
request_pool_scale_up :: proc(pool: ^Connection_Pool) {
	if pool == nil do return
	count := sync.atomic_add(&pool.contention_count, 1)
	if count < pool.contention_threshold do return
	if _, swapped := sync.atomic_compare_exchange_strong(&pool.scale_up_requested, 0, 1); swapped {
		if pool.conn_pid != 0 {
			send_message(pool.conn_pid, Scale_Up_Request{})
		}
	}
}

// Seals current batch slot. force=true always seals (SEALED if writers active),
// force=false only seals when no active writers.
@(private)
batch_seal_locked :: proc(ring: ^Connection_Ring, force: bool = false) {
	slot_idx := ring.batch_slot_idx
	if slot_idx < 0 {
		return
	}

	if u32(slot_idx) >= ring.send_slot_count {
		log.errorf("Invalid batch_slot_idx: %d >= %d", slot_idx, ring.send_slot_count)
		ring.batch_slot_idx = -1
		ring.batch_write_pos = 0
		return
	}

	slot := &ring.send_slots[slot_idx]
	write_pos := ring.batch_write_pos

	if write_pos > ring.send_slot_size {
		log.errorf("batch_write_pos %d exceeds slot size %d", write_pos, ring.send_slot_size)
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

	if !force && active > 0 {
		return
	}

	slot.length = write_pos
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
		sync.atomic_store(&ring.batch_pending, 1)
		sync.atomic_store(&ring.last_send_time, time.to_unix_nanoseconds(time.now()))
	} else {
		sync.atomic_store(&slot.state, .SEALED)
	}
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
	sync.atomic_store(&ring.batch_pending, 1)
}

batch_append_message :: proc(ring: ^Connection_Ring, msg_data: []byte) -> bool {
	msg_len := u32(len(msg_data))
	if msg_len == 0 {
		return true
	}

	if msg_len > ring.send_slot_size {
		log.errorf("Message too large for slot: %d > %d", msg_len, ring.send_slot_size)
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
	if !ok {
		return false
	}

	intrinsics.mem_copy_non_overlapping(raw_data(dst), raw_data(msg_data), int(msg_len))
	batch_commit(ring, sid)
	return true
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
	if exact_size == 0 || exact_size > ring.send_slot_size {
		return nil, 0, false
	}

	if !sync.mutex_try_lock(&ring.batch_mutex) {
		request_pool_scale_up(ring.pool)
		sync.mutex_lock(&ring.batch_mutex)
	}

	batch_idx := ring.batch_slot_idx
	if batch_idx >= 0 {
		remaining := ring.send_slot_size - ring.batch_write_pos
		if exact_size <= remaining {
			offset := ring.batch_write_pos
			ring.batch_write_pos += exact_size

			slot := &ring.send_slots[batch_idx]
			sync.atomic_add(&slot.active_writers, 1)

			remaining_after := ring.send_slot_size - ring.batch_write_pos
			if remaining_after < ring.nearly_full_threshold {
				batch_seal_locked(ring, force = true)
			} else {
				sync.atomic_store(&ring.batch_pending, 1)
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

	remaining_after := ring.send_slot_size - exact_size
	if remaining_after < ring.nearly_full_threshold {
		batch_seal_locked(ring, force = true)
	} else {
		sync.atomic_store(&ring.batch_pending, 1)
	}

	sync.mutex_unlock(&ring.batch_mutex)

	data := slot_data(ring, new_slot_idx)
	return data[0:exact_size], new_slot_idx, true
}

// Last writer on a SEALED slot promotes it to READY.
@(private)
batch_commit :: proc(ring: ^Connection_Ring, slot_idx: u32) {
	slot := &ring.send_slots[slot_idx]
	old := sync.atomic_sub(&slot.active_writers, 1)

	if old == 1 {
		state := sync.atomic_load(&slot.state)
		if state == .SEALED {
			when ODIN_DEBUG {
				data := slot_data(ring, slot_idx)
				if !validate_batch_messages(data[:slot.length], i32(slot_idx), slot.length) {
					log.errorf(
						"CRITICAL: Corrupted batch in slot %d on commit, releasing",
						slot_idx,
					)
					sync.atomic_store(&slot.state, .FREE)
					return
				}
			}
			sync.atomic_store(&slot.state, .READY)
			sync.atomic_store(&ring.batch_pending, 1)
			sync.atomic_store(&ring.last_send_time, time.to_unix_nanoseconds(time.now()))
		}
	}
}

// Writes a valid padding frame on reserve failure to preserve stream integrity.
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

	batch_count: u32 = 0
	check_idx := ring.send_submit_idx

	for check_idx < write_idx && batch_count < MAX_SEND_BATCH {
		slot_idx := check_idx & ring.send_mask
		slot := &ring.send_slots[slot_idx]

		if sync.atomic_load_explicit(&slot.state, .Acquire) != .READY {
			break
		}

		ring.send_bufs[batch_count] = slot_data(ring, slot_idx)[:slot.length]
		batch_count += 1
		check_idx += 1
	}

	if batch_count == 0 do return

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
		when ODIN_DEBUG {
			assert(slot.active_writers == 0, "Slot still has active writers when freed")
		}
		slot.length = 0
		sync.atomic_store_explicit(&slot.state, .FREE, .Release)
		ring.send_submit_idx += 1
	}
	sync.atomic_add(&ring.send_complete_idx, batch_count)

	if op.send.err != nil {
		log.errorf("async send error: %v", op.send.err)
		notify_ring_error(ring, "send error")
		return
	}

	if ring.state == .Ready {
		submit_nbio_sends(ring)
	}
}

submit_nbio_recv :: proc(ring: ^Connection_Ring) {
	if ring.pending_recv != nil {
		return
	}

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
	ring.pending_recv = nbio.recv_poly(ring.tcp_socket, {recv_buf}, ring, nbio_recv_callback)
}

nbio_recv_callback :: proc(op: ^nbio.Operation, ring: ^Connection_Ring) {
	ring.pending_recv = nil

	if op.recv.err != nil {
		log.errorf("recv error: %v", op.recv.err)
		notify_ring_error(ring, "recv error")
		return
	}

	bytes_recvd := u32(op.recv.received)
	if bytes_recvd == 0 {
		log.info("Connection closed by peer")
		notify_ring_error(ring, "peer closed")
		return
	}

	new_write_pos := ring.recv_write_pos + bytes_recvd
	if new_write_pos > ring.recv_buffer_size {
		notify_ring_error(ring, "recv buffer overflow")
		return
	}

	ring.recv_write_pos = new_write_pos
	process_recv_buffer(ring)

	if ring.state == .Ready {
		submit_nbio_recv(ring)
	}
}

@(private)
io_process_drain_requests :: proc(pool: ^Connection_Pool) {
	drain_count := sync.atomic_load(&pool.drain_count)
	if drain_count == 0 do return

	drained_idx := sync.atomic_load(&pool.drained_count)

	for i in 0 ..< drain_count {
		ring := pool.draining_rings[i]
		if ring == nil do continue

		if ring.pending_recv != nil {
			nbio.remove(ring.pending_recv)
			ring.pending_recv = nil
		}
		ring.state = .Draining

		pool.drained_rings[drained_idx] = ring
		drained_idx += 1
		pool.draining_rings[i] = nil
	}

	sync.atomic_store(&pool.drain_count, 0)
	sync.atomic_store(&pool.drained_count, drained_idx)
}

nbio_io_loop :: proc(t: ^thread.Thread) {
	ctx := cast(^IO_Context)t.user_args[0]
	if ctx == nil {
		return
	}

	ring := ctx.ring
	pool := ctx.pool
	context.allocator = ctx.allocator
	context.logger = ctx.logger

	if err := nbio.acquire_thread_event_loop(); err != nil {
		log.errorf("Failed to acquire NBIO event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	if err := nbio.associate_socket(ring.tcp_socket); err != nil {
		log.errorf("Failed to associate socket: %v", err)
		return
	}

	ring.state = .Ready

	submit_nbio_recv(ring)
	submit_nbio_sends(ring)

	idle_ticks: u32 = 0
	last_known_ring_count: u32 = 1

	for sync.atomic_load(ctx.stop_flag) == 0 {
		if sync.atomic_exchange(&ring.batch_pending, 0) != 0 {
			batch_flush(ring)
		}
		submit_nbio_sends(ring)

		if pool != nil {
			io_process_drain_requests(pool)
			current_count := sync.atomic_load(&pool.ring_count)

			adopted_up_to := last_known_ring_count
			for i in last_known_ring_count ..< current_count {
				pr := atomic_load_ring_ptr(&pool.rings[i])
				if pr != nil && pr.state == .Not_Initialized {
					if int(pr.tcp_socket) <= 2 {
						break
					}
					if err := nbio.associate_socket(pr.tcp_socket); err != nil {
						log.errorf("Failed to associate pool ring %d socket: %v", i, err)
						break
					}
					pr.state = .Ready
					submit_nbio_recv(pr)
				}
				adopted_up_to = u32(i) + 1
			}
			last_known_ring_count = adopted_up_to

			for i: u32 = 1; i < current_count; i += 1 {
				pr := atomic_load_ring_ptr(&pool.rings[i])
				if pr != nil && pr.state == .Ready {
					if sync.atomic_exchange(&pr.batch_pending, 0) != 0 {
						batch_flush(pr)
					}
					submit_nbio_sends(pr)
				}
			}
		}

		any_active := ring.send_in_flight
		if pool != nil {
			count := sync.atomic_load(&pool.ring_count)
			for i: u32 = 1; i < count; i += 1 {
				pr := atomic_load_ring_ptr(&pool.rings[i])
				if pr != nil && pr.send_in_flight {
					any_active = true
					break
				}
			}
		}

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

		if err := nbio.tick(timeout); err != nil {
			log.errorf("NBIO tick error: %v", err)
			notify_ring_error(ring, "nbio error")
			break
		}
	}

	if ring.pending_recv != nil {
		nbio.remove(ring.pending_recv)
		ring.pending_recv = nil
	}
	if pool != nil {
		io_process_drain_requests(pool)
		count := sync.atomic_load(&pool.ring_count)
		for i: u32 = 1; i < count; i += 1 {
			pr := atomic_load_ring_ptr(&pool.rings[i])
			if pr != nil && pr.pending_recv != nil {
				nbio.remove(pr.pending_recv)
				pr.pending_recv = nil
			}
		}
	}
}

@(private)
ring_dispatch_message :: proc(ring: ^Connection_Ring, msg_data: []byte) {
	process_complete_message(ring, msg_data)
}

process_recv_buffer :: proc(ring: ^Connection_Ring) {
	new_pos, err := process_recv_frames(
		ring.recv_buffer,
		ring.recv_write_pos,
		ring,
		ring_dispatch_message,
	)
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
	header, ok := parse_network_header(msg_data)
	if !ok {
		log.warn("Failed to parse network header")
		return
	}

	if .CONTROL in header.flags || .LIFECYCLE_EVENT in header.flags || .BROADCAST in header.flags {
		msg_copy := make([]byte, len(msg_data))
		copy(msg_copy, msg_data)
		remote_msg := Remote_Message {
			from = pack_pid(Handle{}, ring.node_id),
			data = msg_copy,
		}
		err := send_message(ring.conn_pid, remote_msg)
		if err != .OK {
			log.warnf("Failed to send control/lifecycle message: %v", err)
		}
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
	)
}

notify_ring_error :: proc(ring: ^Connection_Ring, reason: string) {
	if ring.ring_idx > 0 {
		send_message(ring.conn_pid, Pool_Ring_Closed{ring_idx = ring.ring_idx})
	} else {
		send_message(ring.conn_pid, Close_Connection{reason = reason})
	}
}

send_raw_via_ring :: proc(ring: ^Connection_Ring, raw_data_with_size: []byte) -> bool {
	if ring == nil || ring.state != .Ready {
		return false
	}

	if len(raw_data_with_size) > int(ring.send_slot_size) {
		log.errorf("Data too large: %d > %d", len(raw_data_with_size), ring.send_slot_size)
		return false
	}

	return batch_append_message(ring, raw_data_with_size)
}

send_to_connection_ring :: proc(
	ring: ^Connection_Ring,
	to: PID,
	content: $T,
	base_flags: Network_Message_Flags = {},
) -> Send_Error {
	if ring == nil || ring.state != .Ready {
		return .NETWORK_ERROR
	}

	to_handle, _ := unpack_pid(to)
	from_handle, _ := unpack_pid(get_self_pid())

	exact_size := wire_format_exact_size(content, 0)

	dst, sid, ok := batch_reserve(ring, exact_size)
	if !ok {
		return .NETWORK_RING_FULL
	}

	msg_len := build_wire_format_into_buffer(dst, content, to_handle, from_handle, base_flags, "")
	if msg_len == 0 {
		batch_abort(ring, sid, dst)
		return .NETWORK_ERROR
	}

	when ODIN_DEBUG {
		assert(msg_len == exact_size, "wire format size mismatch in send_to_connection_ring")
	}

	batch_commit(ring, sid)
	return .OK
}

send_to_connection_ring_by_name :: proc(
	ring: ^Connection_Ring,
	actor_name: string,
	content: $T,
	base_flags: Network_Message_Flags = {},
) -> Send_Error {
	if ring == nil || ring.state != .Ready {
		return .NETWORK_ERROR
	}

	from_handle, _ := unpack_pid(get_self_pid())
	to_handle := Handle {
		idx = u32(len(actor_name)),
		gen = 0,
	}

	flags := base_flags | {.BY_NAME}

	exact_size := wire_format_exact_size(content, len(actor_name))

	dst, sid, ok := batch_reserve(ring, exact_size)
	if !ok {
		return .NETWORK_RING_FULL
	}

	msg_len := build_wire_format_into_buffer(
		dst,
		content,
		to_handle,
		from_handle,
		flags,
		actor_name,
	)
	if msg_len == 0 {
		batch_abort(ring, sid, dst)
		return .NETWORK_ERROR
	}

	when ODIN_DEBUG {
		assert(
			msg_len == exact_size,
			"wire format size mismatch in send_to_connection_ring_by_name",
		)
	}

	batch_commit(ring, sid)
	return .OK
}

create_connection_pool :: proc(
	node_id: Node_ID,
	max_rings: u32 = 8,
	allocator := context.allocator,
) -> ^Connection_Pool {
	pool := new(Connection_Pool, allocator)
	if pool == nil do return nil
	pool.node_id = node_id
	pool.max_rings = max_rings > MAX_POOL_RINGS ? MAX_POOL_RINGS : max_rings
	pool.ring_count = 0
	pool.next_ring = 0
	pool.contention_count = 0
	return pool
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

pool_add_ring :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring) -> bool {
	if pool == nil || ring == nil do return false
	count := sync.atomic_load(&pool.ring_count)
	if count >= pool.max_rings do return false
	ring.pool = pool
	ring.ring_idx = count
	atomic_store_ring_ptr(&pool.rings[count], ring)
	sync.atomic_store(&pool.ring_count, count + 1)
	return true
}

pool_remove_ring :: proc(pool: ^Connection_Pool, idx: u32) -> ^Connection_Ring {
	if pool == nil do return nil
	count := sync.atomic_load(&pool.ring_count)
	if idx >= count || count <= 1 do return nil

	ring := pool.rings[idx]
	last := count - 1
	if idx != last {
		moved_ring := pool.rings[last]
		moved_ring.ring_idx = idx
		atomic_store_ring_ptr(&pool.rings[idx], moved_ring)
	}
	atomic_store_ring_ptr(&pool.rings[last], nil)
	sync.atomic_store(&pool.ring_count, last)
	ring.pool = nil
	return ring
}

destroy_connection_pool :: proc(pool: ^Connection_Pool, allocator := context.allocator) {
	if pool == nil do return
	free(pool, allocator)
}

get_pool_ring_ready :: #force_inline proc(pool: ^Connection_Pool) -> ^Connection_Ring {
	if pool == nil do return nil
	r := atomic_load_ring_ptr(&pool.rings[0])
	if r == nil do return nil
	if r.state == .Ready {
		if atomic_load_ring_ptr(&pool.rings[1]) == nil do return r
	}

	count := sync.atomic_load(&pool.ring_count)
	start := sync.atomic_add(&pool.next_ring, 1)
	for i in 0 ..< count {
		idx := (start + i) % count
		mr := atomic_load_ring_ptr(&pool.rings[idx])
		if mr != nil && mr.state == .Ready do return mr
	}
	return nil
}
