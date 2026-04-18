package actod

import "base:intrinsics"
import "base:runtime"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

CTRL_MSG_HANDSHAKE :: 1
CTRL_MSG_HEARTBEAT :: 2
CTRL_MSG_NODE_DIRECTORY :: 3
CTRL_MSG_DISCONNECT :: 4
CTRL_MSG_POOL_RING :: 5

Connection_Control_Message :: union {
	Handshake_Message,
	Heartbeat_Message,
}

Handshake_Message :: struct {
	node_id:    Node_ID,
	node_name:  string,
	version:    u32,
	auth_token: string,
	nonce:      u64,
}

Heartbeat_Message :: struct {
	timestamp: time.Time,
	seq_num:   u64,
}

Connection_Command :: union {
	Connect_Request,
	Close_Connection,
	Start_Receiving,
	Reconnect,
	Raw_Network_Buffer,
	Accept_Pool_Ring_Socket,
	Pool_Ring_Closed,
}

Accept_Pool_Ring_Socket :: struct {
	socket: net.TCP_Socket,
}

Pool_Ring_Closed :: struct {
	ring_idx: u32,
}

Connect_Request :: struct {
	node_id:   Node_ID,
	address:   net.Endpoint,
	transport: Transport_Strategy,
}

Close_Connection :: struct {
	reason: string,
}

Start_Receiving :: struct {}

Reconnect :: struct {
	delay: time.Duration,
}

Raw_Network_Buffer :: struct {
	data: []byte,
}

Connection_State :: enum {
	Disconnected,
	Connecting,
	Handshaking,
	Connected,
	Failed,
}

Connection_Actor_Data :: struct {
	node_id:                   Node_ID,
	node_name:                 string,
	state:                     Connection_State,
	transport:                 Transport_Strategy,
	address:                   net.Endpoint,
	tcp_socket:                net.TCP_Socket,
	last_heartbeat:            time.Time,
	last_activity:             time.Time,
	heartbeat_interval:        time.Duration,
	heartbeat_timeout:         time.Duration,
	reconnect_initial_delay:   time.Duration,
	reconnect_retry_delay:     time.Duration,
	auth_password:             string,
	is_incoming:               bool,
	peer_initiated_disconnect: bool,
	first_message:             []byte,
	pending_messages:          [dynamic][]byte,
	pool:                      ^Connection_Pool,
	io_threads:                [MAX_POOL_RINGS]^thread.Thread,
	io_stop_flags:             [MAX_POOL_RINGS]i32,
	io_contexts:               [MAX_POOL_RINGS]^IO_Context,
	ring_config:               Connection_Ring_Config,
	heartbeat_timer_id:        u32,
	reconnect_timer_id:        u32,
}

Connection_Actor_Behaviour :: Actor_Behaviour(Connection_Actor_Data) {
	handle_message = connection_handle_message,
	init           = connection_actor_init,
	terminate      = connection_actor_terminate,
}

connection_actor_init :: proc(data: ^Connection_Actor_Data) {
	data.pending_messages = make([dynamic][]byte, 0, 10)

	max_rings := data.ring_config.max_pool_rings
	if max_rings == 0 do max_rings = 8
	data.pool = create_connection_pool(data.node_id, max_rings)

	ring := create_connection_ring(data.ring_config)
	if ring != nil {
		ring.node_id = data.node_id
		pool_add_ring(data.pool, ring)
	}

	for i in 0 ..< MAX_POOL_RINGS {
		sync.atomic_store(&data.io_stop_flags[i], 0)
	}
}

connection_actor_terminate :: proc(data: ^Connection_Actor_Data) {
	if data.tcp_socket != 0 {
		net.close(data.tcp_socket)
		data.tcp_socket = 0
	}

	if data.pool != nil {
		ring_count := sync.atomic_load(&data.pool.ring_count)
		for i in 0 ..< ring_count {
			if data.pool.rings[i] != nil do data.pool.rings[i].state = .Draining
		}
	}

	for i in 0 ..< MAX_POOL_RINGS {
		sync.atomic_store(&data.io_stop_flags[i], 1)
	}

	for i in 0 ..< MAX_POOL_RINGS {
		if data.io_threads[i] != nil {
			thread.join(data.io_threads[i])
			thread.destroy(data.io_threads[i])
			data.io_threads[i] = nil
		}
	}

	is_active := is_active_connection(data)

	if data.node_id != 0 && is_active {
		unregister_connection_pool(data.node_id)
	}

	if data.pool != nil {
		ring_count := sync.atomic_load(&data.pool.ring_count)
		for i in 0 ..< ring_count {
			if data.pool.rings[i] != nil {
				destroy_connection_ring(data.pool.rings[i])
				data.pool.rings[i] = nil
			}
		}
		destroy_connection_pool(data.pool)
		data.pool = nil
	}

	if data.node_id != 0 && data.node_id < MAX_NODES && is_active {
		sync.atomic_store_explicit(
			cast(^u64)&NODE.connection_actors[data.node_id],
			u64(0),
			.Release,
		)
	}

	if len(data.pending_messages) > 0 {
		log.warnf(
			"Connection actor for node %s (id=%d) terminating with %d unsent messages dropped",
			data.node_name,
			data.node_id,
			len(data.pending_messages),
		)
	}
	for msg in data.pending_messages {
		delete(msg)
	}
	delete(data.pending_messages)

	if data.first_message != nil {
		delete(data.first_message, actor_system_allocator)
		data.first_message = nil
	}
}

connection_handle_message :: proc(data: ^Connection_Actor_Data, from: PID, msg: any) {
	switch m in msg {
	case Connect_Request:
		if data.state != .Disconnected {
			log.warnf("Connection already in progress for node %d", data.node_id)
			return
		}

		data.address = m.address
		data.transport = m.transport
		data.state = .Connecting

		if !initiate_connection(data) {
			data.state = .Failed
			data.reconnect_timer_id, _ = set_timer(data.reconnect_retry_delay, false)
			return
		}

	case Close_Connection:
		log.infof("Closing connection to node %d: %s", data.node_id, m.reason)
		close_connection(data)

	case Start_Receiving:
		if data.is_incoming && data.tcp_socket != 0 {
			if data.first_message != nil {
				handle_incoming_data(data, data.first_message)
				delete(data.first_message, actor_system_allocator)
				data.first_message = nil
			}
			start_io_thread(data)
		}

	case Remote_Message:
		handle_incoming_data(data, m.data)

	case Timer_Tick:
		if data.state == .Connected {
			if m.id == data.heartbeat_timer_id && data.heartbeat_interval > 0 {
				send_heartbeat_message(data)
				check_heartbeat_timeout(data)
				pool_check_scaling(data)
			}
		} else if (data.state == .Disconnected || data.state == .Failed) &&
		   m.id == data.reconnect_timer_id {
			cancel_timer(data.reconnect_timer_id)
			attempt_reconnect(data)
		}

	case Reconnect:
		if data.state == .Disconnected || data.state == .Failed {
			if m.delay > 0 {
				data.reconnect_timer_id, _ = set_timer(m.delay, false)
				log.infof("Scheduled reconnect to node %d in %v", data.node_id, m.delay)
			} else {
				attempt_reconnect(data)
			}
		}

	case Scale_Up_Request:
		if data.state == .Connected && data.pool != nil {
			pool_scale_up(data)
			sync.atomic_store(&data.pool.contention_count, 0)
			sync.atomic_store(&data.pool.scale_up_requested, 0)
		}

	case Raw_Network_Buffer:
		if data.state != .Connected {
			log.warnf("Cannot send - not connected to node %d, queueing raw buffer", data.node_id)
			buffer_copy := make([]byte, len(m.data) - 4)
			copy(buffer_copy, m.data[4:])
			append(&data.pending_messages, buffer_copy)
			if data.state == .Disconnected {
				send_message(
					get_self_pid(),
					Connect_Request {
						node_id = data.node_id,
						address = data.address,
						transport = data.transport,
					},
				)
			}
			return
		}

		ring := get_pool_ring_ready(data.pool)
		if ring != nil {
			// Must go through ring — blocking send would interleave with NBIO.
			sent := false
			for attempt in 0 ..< 10_000 {
				if send_raw_via_ring(ring, m.data) {
					sent = true
					break
				}
				if attempt < 100 {
					intrinsics.cpu_relax()
				} else {
					time.sleep(1 * time.Microsecond)
				}
			}
			if sent {
				data.last_activity = time.now()
			} else {
				log.errorf(
					"Raw buffer dropped — ring full after retries for node %d",
					data.node_id,
				)
			}
		} else {
			if !tcp_send_all(data.tcp_socket, m.data) {
				log.errorf(
					"Failed to send raw buffer to node %s (id=%d) - message dropped",
					data.node_name,
					data.node_id,
				)
				data.state = .Disconnected
			} else {
				data.last_activity = time.now()
			}
		}

	case Accept_Pool_Ring_Socket:
		if data.state != .Connected || data.pool == nil {
			log.warnf("Cannot accept pool ring - not connected to node %d", data.node_id)
			net.close(m.socket)
			return
		}

		ring := create_connection_ring(data.ring_config)
		if ring == nil {
			net.close(m.socket)
			return
		}

		ring.node_id = data.node_id
		ring.socket = net.Socket(m.socket)
		ring.conn_pid = get_self_pid()
		if !init_connection_ring_nbio(ring) {
			destroy_connection_ring(ring)
			net.close(m.socket)
			return
		}

		if !pool_add_ring(data.pool, ring) {
			destroy_connection_ring(ring)
			net.close(m.socket)
			return
		}

		new_idx := sync.atomic_load(&data.pool.ring_count) - 1
		start_io_thread_for_ring(data, new_idx, m.socket)

		log.infof(
			"Accepted pool ring from node %s (id=%d): %d rings",
			data.node_name,
			data.node_id,
			sync.atomic_load(&data.pool.ring_count),
		)

	case Pool_Ring_Closed:
		if m.ring_idx == 0 {
			close_connection(data)
			return
		}

		if data.pool == nil {
			return
		}

		ring_count := sync.atomic_load(&data.pool.ring_count)
		if m.ring_idx >= ring_count {
			return
		}

		last_idx := ring_count - 1
		ring := pool_remove_ring(data.pool, m.ring_idx)
		if ring == nil {
			return
		}

		cleanup_ring_io_state(data, m.ring_idx, last_idx, join_thread = false)
		pool_submit_drain_and_wait(data.pool, ring)

		log.infof(
			"Pool ring %d closed for node %s (id=%d): %d rings remaining",
			m.ring_idx,
			data.node_name,
			data.node_id,
			sync.atomic_load(&data.pool.ring_count),
		)
	}
}

initiate_connection :: proc(data: ^Connection_Actor_Data) -> bool {
	#partial switch data.transport {
	case .TCP_Custom_Protocol:
		sock, err := net.dial_tcp(data.address)
		if err != nil {
			log.errorf("Failed to connect to node %d: %v", data.node_id, err)
			return false
		}

		data.tcp_socket = sock
		data.state = .Handshaking

		if !send_handshake_message(data) {
			net.close(sock)
			return false
		}

		start_io_thread(data)
		return true

	case:
		log.errorf("Unsupported transport: %v", data.transport)
		return false
	}
}

send_handshake_message :: proc(data: ^Connection_Actor_Data) -> bool {
	nonce := generate_nonce()

	auth_token := ""
	if data.auth_password != "" {
		auth_input := fmt.tprintf("%s:%s:%d", data.auth_password, NODE.name, nonce)

		hash_digest := hash.hash_string(.SHA256, auth_input)
		auth_token = fmt.tprintf("%x", hash_digest)
		delete(hash_digest)
	}

	handshake := Handshake_Message {
		node_id    = current_node_id,
		node_name  = NODE.name,
		version    = 1,
		auth_token = auth_token,
		nonce      = nonce,
	}

	msg := Connection_Control_Message(handshake)
	return send_control_message(data, msg)
}

send_control_message :: proc(
	data: ^Connection_Actor_Data,
	msg: Connection_Control_Message,
) -> bool {
	switch m in msg {
	case Handshake_Message:
		total := 1 + 2 + (2 + len(m.node_name)) + 4 + (2 + len(m.auth_token)) + 8
		ctrl_data := make([]byte, total)
		defer delete(ctrl_data)

		w := Ctrl_Writer {
			buf = ctrl_data,
		}
		ctrl_put_u8(&w, CTRL_MSG_HANDSHAKE)
		ctrl_put_u16(&w, u16(m.node_id))
		ctrl_put_str(&w, m.node_name)
		ctrl_put_u32(&w, m.version)
		ctrl_put_str(&w, m.auth_token)
		ctrl_put_u64(&w, m.nonce)

		msg_buffer := wrap_control_message(ctrl_data)
		defer delete(msg_buffer)
		return send_raw_connection_data(data, msg_buffer)

	case Heartbeat_Message:
		ctrl_buf: [17]byte
		w := Ctrl_Writer {
			buf = ctrl_buf[:],
		}
		ctrl_put_u8(&w, CTRL_MSG_HEARTBEAT)
		ctrl_put_u64(&w, u64(time.to_unix_nanoseconds(m.timestamp)))
		ctrl_put_u64(&w, m.seq_num)

		msg_buf: [NETWORK_HEADER_SIZE + 17]byte
		write_network_header(msg_buf[:], {.CONTROL}, 0, Handle{}, Handle{})
		copy(msg_buf[NETWORK_HEADER_SIZE:], ctrl_buf[:])
		return send_raw_connection_data(data, msg_buf[:])
	}
	return false
}

send_raw_connection_data :: proc(data: ^Connection_Actor_Data, raw_data: []byte) -> bool {
	#partial switch data.transport {
	case .TCP_Custom_Protocol:
		total_size := 4 + len(raw_data)
		msg_buffer := make([]byte, total_size)
		defer delete(msg_buffer)

		endian.put_u32(msg_buffer[0:4], .Little, u32(len(raw_data)))
		copy(msg_buffer[4:], raw_data)

		ring := get_pool_ring_ready(data.pool)
		if ring != nil {
			for attempt in 0 ..< 10_000 {
				if send_raw_via_ring(ring, msg_buffer) {
					data.last_activity = time.now()
					return true
				}
				if attempt < 100 {
					intrinsics.cpu_relax()
				} else {
					time.sleep(1 * time.Microsecond)
				}
			}
			log.warn("Ring send failed after retries for raw connection data")
			return false
		}

		if !tcp_send_all(data.tcp_socket, msg_buffer) {
			return false
		}

		data.last_activity = time.now()
		return true

	case:
		return false
	}
}

tcp_send_all :: proc(socket: net.TCP_Socket, data: []byte) -> bool {
	if len(data) == 0 {
		return true
	}

	total_sent := 0
	wouldblock_spins: u32 = 0
	for total_sent < len(data) {
		n, err := net.send_tcp(socket, data[total_sent:])
		if err != nil {
			if err == .Would_Block {
				wouldblock_spins += 1
				if wouldblock_spins > 100_000 {
					return false
				}
				intrinsics.cpu_relax()
				continue
			}
			log.errorf("TCP send error: %v", err)
			return false
		}
		if n == 0 {
			log.error("TCP send returned 0 bytes")
			return false
		}
		total_sent += n
		wouldblock_spins = 0
	}
	return true
}

handle_incoming_data :: proc(data: ^Connection_Actor_Data, raw_data: []byte) {
	header, ok := parse_network_header(raw_data)
	if !ok {
		log.error("Failed to parse network message header")
		return
	}

	if .CONTROL in header.flags {
		handle_control_message(data, header.payload)
		data.last_activity = time.now()
		return
	}

	if .LIFECYCLE_EVENT in header.flags {
		handle_lifecycle_event(data.node_id, header.type_hash, header.payload)
		data.last_activity = time.now()
		return
	}

	deliver_to_target(
		data.node_id,
		header.flags,
		header.type_hash,
		header.from_handle,
		header.to_handle,
		header.to_name,
		header.payload,
	)
	data.last_activity = time.now()
}

handle_control_message :: proc(data: ^Connection_Actor_Data, ctrl_data: []byte) {
	if len(ctrl_data) < 1 {
		log.error("Control message too short")
		return
	}

	msg_type := ctrl_data[0]

	switch msg_type {
	case CTRL_MSG_HANDSHAKE:
		r := Ctrl_Reader {
			data = ctrl_data,
			pos  = 1,
			ok   = true,
		}
		node_id := Node_ID(ctrl_get_u16(&r))
		node_name := ctrl_get_str(&r)
		version := ctrl_get_u32(&r)
		auth_token := ctrl_get_str(&r)
		nonce := ctrl_get_u64(&r)
		if !r.ok {
			log.error("Handshake message truncated")
			return
		}

		if data.auth_password != "" {
			auth_input := fmt.tprintf("%s:%s:%d", data.auth_password, node_name, nonce)

			hash_digest := hash.hash_string(.SHA256, auth_input)
			expected_token := fmt.tprintf("%x", hash_digest)
			delete(hash_digest)

			if auth_token != expected_token {
				log.errorf("Authentication failed from node %s (%d)", node_name, node_id)
				close_connection(data)
				return
			}
		}

		log.infof(
			"Handshake successful with node %s (remote node's self ID: %d, version: %d)",
			node_name,
			node_id,
			version,
		)

		if data.is_incoming {
			local_node_id, registered := register_node(node_name, data.address, data.transport)
			if !registered {
				local_node_id, registered = get_node_by_name(node_name)
				if !registered {
					log.errorf("Failed to register remote node %s", node_name)
					close_connection(data)
					return
				}
			}
			data.node_id = local_node_id

			existing_conn := PID(
				sync.atomic_load_explicit(
					cast(^u64)&NODE.connection_actors[local_node_id],
					.Acquire,
				),
			)
			if existing_conn != 0 {
				our_port := SYSTEM_CONFIG.network.port
				their_port := data.address.port
				if remote_info, ok := get_node_info(local_node_id); ok {
					their_port = remote_info.address.port
				}

				we_keep_outgoing :=
					our_port > their_port || (our_port == their_port && NODE.name < node_name)

				if we_keep_outgoing {
					log.infof(
						"Closing duplicate incoming from %s (keeping outgoing, port %d > %d)",
						node_name,
						our_port,
						their_port,
					)
					close_connection(data)
					return
				} else {
					log.infof(
						"Replacing outgoing with incoming from %s (port %d <= %d)",
						node_name,
						our_port,
						their_port,
					)
					terminate_actor(existing_conn, .SHUTDOWN)
				}
			}

			if data.pool != nil {
				data.pool.node_id = local_node_id
				ring_count := sync.atomic_load(&data.pool.ring_count)
				for ri in 0 ..< ring_count {
					if data.pool.rings[ri] != nil do data.pool.rings[ri].node_id = local_node_id
				}
			}

			sync.atomic_store_explicit(
				cast(^u64)&NODE.connection_actors[local_node_id],
				u64(get_self_pid()),
				.Release,
			)
		}

		data.node_name = strings.clone(node_name)
		data.last_heartbeat = time.now()

		new_name := fmt.tprintf("%s_connection", node_name)
		defer delete(new_name)
		self_rename(new_name)

		if data.is_incoming {
			send_handshake_message(data)
		}

		data.state = .Connected

		send_registry_snapshot(data)
		send_node_directory(data)

		if data.heartbeat_interval > 0 {
			data.heartbeat_timer_id, _ = set_timer(data.heartbeat_interval, true)
		}

		if len(data.pending_messages) > 0 {
			for i := 0; i < len(data.pending_messages); i += 1 {
				msg := data.pending_messages[i]
				send_raw_connection_data(data, msg)
				delete(msg)
			}
			clear_dynamic_array(&data.pending_messages)
		}

	case CTRL_MSG_HEARTBEAT:
		if len(ctrl_data) < 1 + 8 + 8 {
			log.error("Heartbeat message too short")
			return
		}
		data.last_heartbeat = time.now()

	case CTRL_MSG_NODE_DIRECTORY:
		handle_node_directory(ctrl_data)

	case CTRL_MSG_DISCONNECT:
		r := Ctrl_Reader {
			data = ctrl_data,
			pos  = 1,
			ok   = true,
		}
		node_id := Node_ID(ctrl_get_u16(&r))
		reason := ctrl_get_str(&r)
		if !r.ok {return}
		log.infof("Node %s (id=%d) graceful disconnect: %s", data.node_name, node_id, reason)
		data.peer_initiated_disconnect = true
		close_connection(data)
	}
}

broadcast_disconnect_terminations :: proc(disconnected_node_id: Node_ID) {
	if disconnected_node_id == 0 || disconnected_node_id == current_node_id {
		return
	}

	source_name, name_ok := get_node_name(disconnected_node_id)
	if !name_ok {
		return
	}

	num_items := sync.atomic_load_explicit(&global_registry.num_items, .Acquire)

	for i in 1 ..< num_items {
		entry := &global_registry.items[i]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 {
			continue
		}

		pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if get_node_id(pid) != disconnected_node_id {
			continue
		}

		actor_name := entry.remote_name
		if at_idx := strings.index_byte(actor_name, '@'); at_idx >= 0 {
			actor_name = actor_name[:at_idx]
		}

		handle, _ := unpack_pid(pid)
		original_pid := pack_pid(handle, current_node_id)

		msg := Actor_Terminated_Broadcast {
			pid              = original_pid,
			name             = actor_name,
			reason           = .SHUTDOWN,
			ttl              = DEFAULT_BROADCAST_TTL,
			source_node_name = source_name,
		}

		broadcast_to_others(msg, disconnected_node_id)
	}
}

is_active_connection :: proc(data: ^Connection_Actor_Data) -> bool {
	if data.node_id == 0 || data.node_id >= MAX_NODES {
		return false
	}
	current_conn := PID(
		sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[data.node_id], .Acquire),
	)
	return current_conn == get_self_pid()
}

close_connection :: proc(data: ^Connection_Actor_Data) {
	is_active := is_active_connection(data)

	if data.node_id != 0 && is_active {
		clear_subscriptions_for_node(data.node_id)
		broadcast_disconnect_terminations(data.node_id)
		handle_node_disconnect(data.node_id)
	}

	for i in 0 ..< MAX_POOL_RINGS {
		sync.atomic_store(&data.io_stop_flags[i], 1)
	}

	if data.pool != nil {
		ring_count := sync.atomic_load(&data.pool.ring_count)
		for i in 0 ..< ring_count {
			if data.pool.rings[i] != nil do data.pool.rings[i].state = .Draining
		}
	}

	if data.state == .Connected || data.state == .Connecting || data.state == .Handshaking {
		#partial switch data.transport {
		case .TCP_Custom_Protocol:
			if data.tcp_socket != 0 {
				net.close(data.tcp_socket)
				data.tcp_socket = 0
			}
		}
	}

	for i in 0 ..< MAX_POOL_RINGS {
		if data.io_threads[i] != nil {
			thread.join(data.io_threads[i])
			thread.destroy(data.io_threads[i])
			data.io_threads[i] = nil
		}
		sync.atomic_store(&data.io_stop_flags[i], 0)
	}

	if data.node_id != 0 && is_active {
		unregister_connection_pool(data.node_id)
	}

	if data.pool != nil {
		ring_count := sync.atomic_load(&data.pool.ring_count)
		for i := ring_count; i > 1; i -= 1 {
			idx := i - 1
			ring := data.pool.rings[idx]
			if ring != nil {
				destroy_connection_ring(ring)
				data.pool.rings[idx] = nil
			}
		}
		sync.atomic_store(&data.pool.ring_count, data.pool.rings[0] != nil ? 1 : 0)

		if data.pool.rings[0] != nil {
			reset_connection_ring(data.pool.rings[0])
		}
		sync.atomic_store(&data.pool.contention_count, 0)
	}

	data.state = .Disconnected

	cancel_timer(data.heartbeat_timer_id)

	if !data.is_incoming && !data.peer_initiated_disconnect {
		data.reconnect_timer_id, _ = set_timer(data.reconnect_initial_delay, false)
		log.infof(
			"Scheduled reconnection for node %d in %v",
			data.node_id,
			data.reconnect_initial_delay,
		)
	}
}

attempt_reconnect :: proc(data: ^Connection_Actor_Data) {
	log.infof("Attempting to reconnect to node %d", data.node_id)
	data.state = .Connecting

	if !initiate_connection(data) {
		data.state = .Failed
		data.reconnect_timer_id, _ = set_timer(data.reconnect_retry_delay, false)
		log.infof("Reconnect failed, retry scheduled in %v", data.reconnect_retry_delay)
	}
}

send_heartbeat_message :: proc(data: ^Connection_Actor_Data) {
	heartbeat := Heartbeat_Message {
		timestamp = time.now(),
		seq_num   = 0,
	}

	msg := Connection_Control_Message(heartbeat)
	send_control_message(data, msg)
}

check_heartbeat_timeout :: proc(data: ^Connection_Actor_Data) {
	if data.heartbeat_timeout > 0 {
		time_since := time.since(data.last_heartbeat)
		if time_since > data.heartbeat_timeout {
			log.warnf("Connection to node %d timed out", data.node_id)
			close_connection(data)
		}
	}
}

pool_check_scaling :: proc(data: ^Connection_Actor_Data) {
	pool := data.pool
	if pool == nil do return

	ring_count := sync.atomic_load(&pool.ring_count)
	threshold := data.ring_config.scale_up_contention_threshold
	if threshold == 0 do threshold = 100
	idle_secs := data.ring_config.scale_down_idle_seconds
	if idle_secs == 0 do idle_secs = 10

	contention := sync.atomic_exchange(&pool.contention_count, 0)
	if contention > threshold && ring_count < pool.max_rings {
		pool_scale_up(data)
	}

	if ring_count > 1 {
		now_ns := time.to_unix_nanoseconds(time.now())
		idle_ns := i64(idle_secs) * 1_000_000_000

		for i := ring_count; i > 1; i -= 1 {
			idx := i - 1
			ring := pool.rings[idx]
			if ring == nil do continue
			last := sync.atomic_load(&ring.last_send_time)
			if last != 0 && (now_ns - last) > idle_ns {
				pool_scale_down(data, idx)
			}
		}
	}
}

pool_scale_up :: proc(data: ^Connection_Actor_Data) {
	pool := data.pool
	ring_count := sync.atomic_load(&pool.ring_count)
	if ring_count >= pool.max_rings do return

	sock, err := net.dial_tcp(data.address)
	if err != nil {
		log.errorf("Pool scale-up: failed to connect to node %d: %v", data.node_id, err)
		return
	}

	if !send_pool_ring_identifier(sock) {
		log.errorf("Pool scale-up: failed to send pool ring identifier to node %d", data.node_id)
		net.close(sock)
		return
	}

	ring := create_connection_ring(data.ring_config)
	if ring == nil {
		net.close(sock)
		return
	}

	ring.node_id = data.node_id
	ring.socket = net.Socket(sock)
	ring.conn_pid = get_self_pid()
	if !init_connection_ring_nbio(ring) {
		destroy_connection_ring(ring)
		net.close(sock)
		return
	}

	if !pool_add_ring(pool, ring) {
		destroy_connection_ring(ring)
		net.close(sock)
		return
	}

	new_idx := sync.atomic_load(&pool.ring_count) - 1
	start_io_thread_for_ring(data, new_idx, sock)

	log.infof(
		"Pool scaled up for node %d: %d rings",
		data.node_id,
		sync.atomic_load(&pool.ring_count),
	)
}

send_pool_ring_identifier :: proc(sock: net.TCP_Socket) -> bool {
	// Wire format: [size:u32][header:26][CTRL_MSG_POOL_RING:u8][name_len:u16][node_name]
	ctrl_size := 1 + 2 + len(NODE.name)
	ctrl_buf := make([]byte, ctrl_size)
	defer delete(ctrl_buf)

	w := Ctrl_Writer {
		buf = ctrl_buf,
	}
	ctrl_put_u8(&w, CTRL_MSG_POOL_RING)
	ctrl_put_str(&w, NODE.name)

	frame_buf := make([]byte, 4 + NETWORK_HEADER_SIZE + ctrl_size)
	defer delete(frame_buf)
	n := frame_control_message(ctrl_buf, frame_buf)

	return tcp_send_all(sock, frame_buf[:n])
}

cleanup_ring_io_state :: proc(
	data: ^Connection_Actor_Data,
	ring_idx: u32,
	last_idx: u32,
	join_thread: bool,
) {
	if join_thread {
		sync.atomic_store(&data.io_stop_flags[ring_idx], 1)
	}

	if data.io_threads[ring_idx] != nil {
		thread.join(data.io_threads[ring_idx])
		thread.destroy(data.io_threads[ring_idx])
		data.io_threads[ring_idx] = nil
	}
	sync.atomic_store(&data.io_stop_flags[ring_idx], 0)

	if data.io_contexts[ring_idx] != nil {
		free(data.io_contexts[ring_idx])
		data.io_contexts[ring_idx] = nil
	}

	if ring_idx != last_idx {
		data.io_threads[ring_idx] = data.io_threads[last_idx]
		data.io_threads[last_idx] = nil
		sync.atomic_store(
			&data.io_stop_flags[ring_idx],
			sync.atomic_load(&data.io_stop_flags[last_idx]),
		)
		sync.atomic_store(&data.io_stop_flags[last_idx], 0)
		data.io_contexts[ring_idx] = data.io_contexts[last_idx]
		data.io_contexts[last_idx] = nil

		if data.io_contexts[ring_idx] != nil {
			data.io_contexts[ring_idx].stop_flag = &data.io_stop_flags[ring_idx]
		}
	}
}

DRAIN_SPIN_LIMIT :: 1_000_000

@(private)
pool_submit_drain_and_wait :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring) {
	drain_idx := sync.atomic_load(&pool.drain_count)
	pool.draining_rings[drain_idx] = ring
	sync.atomic_store(&pool.drain_count, drain_idx + 1)

	for spin := 0; spin < DRAIN_SPIN_LIMIT; spin += 1 {
		if sync.atomic_load(&pool.drained_count) > 0 {
			break
		}
		intrinsics.cpu_relax()
	}

	drained_count := sync.atomic_load(&pool.drained_count)
	if drained_count > 0 {
		for i in 0 ..< drained_count {
			dr := pool.drained_rings[i]
			if dr != nil {
				if dr.tcp_socket != 0 {
					net.close(dr.tcp_socket)
				}
				destroy_connection_ring(dr)
				pool.drained_rings[i] = nil
			}
		}
		sync.atomic_store(&pool.drained_count, 0)
	} else {
		dc := sync.atomic_load(&pool.drain_count)
		for i in 0 ..< dc {
			dr := pool.draining_rings[i]
			if dr != nil {
				if dr.tcp_socket != 0 {
					net.close(dr.tcp_socket)
				}
				destroy_connection_ring(dr)
				pool.draining_rings[i] = nil
			}
		}
		sync.atomic_store(&pool.drain_count, 0)
	}
}

pool_scale_down :: proc(data: ^Connection_Actor_Data, ring_idx: u32) {
	pool := data.pool
	if ring_idx == 0 do return

	ring_count := sync.atomic_load(&pool.ring_count)
	last_idx := ring_count - 1

	ring := pool_remove_ring(pool, ring_idx)
	if ring == nil do return

	cleanup_ring_io_state(data, ring_idx, last_idx, join_thread = false)
	pool_submit_drain_and_wait(pool, ring)

	log.infof(
		"Pool scaled down for node %d: %d rings",
		data.node_id,
		sync.atomic_load(&pool.ring_count),
	)
}

start_io_thread :: proc(data: ^Connection_Actor_Data) {
	start_io_thread_for_ring(data, 0, data.tcp_socket)
}

start_io_thread_for_ring :: proc(
	data: ^Connection_Actor_Data,
	ring_idx: u32,
	socket: net.TCP_Socket,
) {
	if data.io_threads[ring_idx] != nil {
		return
	}

	ring: ^Connection_Ring
	if data.pool != nil && ring_idx < sync.atomic_load(&data.pool.ring_count) {
		ring = data.pool.rings[ring_idx]
	}

	tcp_nodelay := ring != nil ? ring.tcp_nodelay : false
	if !set_tcp_nodelay(socket, tcp_nodelay) {
		log.warn("Failed to set TCP_NODELAY")
	}

	if !set_socket_buffers(socket) {
		log.warn("Failed to set socket buffers")
	}

	if ring != nil {
		if ring_idx == 0 {
			ring.socket = net.Socket(socket)
			ring.node_id = data.node_id
			ring.conn_pid = get_self_pid()
		}

		if ring.tcp_socket != 0 || init_connection_ring_nbio(ring) {
			if ring_idx == 0 {
				data.pool.conn_pid = get_self_pid()
				threshold := data.ring_config.scale_up_contention_threshold
				if threshold == 0 do threshold = 100
				data.pool.contention_threshold = threshold
				register_connection_pool(data.node_id, data.pool)

				ctx := new(IO_Context)
				ctx.ring = ring
				ctx.pool = data.pool
				ctx.stop_flag = &data.io_stop_flags[0]
				ctx.conn_pid = get_self_pid()
				ctx.allocator = context.allocator
				ctx.logger = context.logger
				data.io_contexts[0] = ctx

				t := thread.create(nbio_io_loop)
				if t != nil {
					t.user_args[0] = ctx
					thread.start(t)
					data.io_threads[0] = t
					return
				}
				free(ctx)
				data.io_contexts[0] = nil
			} else {
				// Ring 0's IO thread will adopt this ring.
				return
			}
			log.error("Failed to create nbio_io_loop thread")
		}
		log.info("NBIO not available, using blocking TCP fallback")
	}

	if ring_idx == 0 {
		start_blocking_recv_thread(data)
	}
}

Blocking_Recv_Context :: struct {
	socket:      net.TCP_Socket,
	node_id_ptr: ^Node_ID,
	conn_pid:    PID,
	stop_flag:   ^i32,
	allocator:   runtime.Allocator,
	logger:      runtime.Logger,
}

BLOCKING_RECV_TIMEOUT_SECS :: 10

start_blocking_recv_thread :: proc(data: ^Connection_Actor_Data) {
	net.set_blocking(data.tcp_socket, true)
	set_recv_timeout(data.tcp_socket, BLOCKING_RECV_TIMEOUT_SECS)

	ctx := new(Blocking_Recv_Context)
	ctx.socket = data.tcp_socket
	ctx.node_id_ptr = &data.node_id
	ctx.conn_pid = get_self_pid()
	ctx.stop_flag = &data.io_stop_flags[0]
	ctx.allocator = context.allocator
	ctx.logger = context.logger

	t := thread.create(blocking_recv_loop)
	if t != nil {
		t.user_args[0] = ctx
		thread.start(t)
		data.io_threads[0] = t
		log.infof("Started blocking recv thread for node %d", data.node_id)
	} else {
		free(ctx)
		log.error("Failed to create blocking recv thread")
	}
}

@(private)
blocking_dispatch_message :: proc(ctx: ^Blocking_Recv_Context, msg_data: []byte) {
	process_blocking_recv_message(ctx, msg_data)
}

blocking_recv_loop :: proc(t: ^thread.Thread) {
	ctx := cast(^Blocking_Recv_Context)t.user_args[0]
	if ctx == nil {
		return
	}
	defer free(ctx)

	context.allocator = ctx.allocator
	context.logger = ctx.logger

	RECV_BUFFER_SIZE :: 4 * 1024 * 1024

	recv_buffer := make([]byte, RECV_BUFFER_SIZE)
	defer delete(recv_buffer)

	write_pos: u32 = 0

	for sync.atomic_load(ctx.stop_flag) == 0 {
		available := RECV_BUFFER_SIZE - int(write_pos)
		if available < 1024 {
			log.error("Blocking recv buffer overflow")
			break
		}

		n, err := net.recv_tcp(ctx.socket, recv_buffer[write_pos:])
		if err != nil {
			if sync.atomic_load(ctx.stop_flag) != 0 {
				break
			}
			if err == .Timeout || err == .Would_Block {
				continue // recv timeout — re-check stop flag
			}
			log.errorf("Blocking recv error: %v", err)
			send_message(ctx.conn_pid, Close_Connection{reason = "recv error"})
			break
		}

		if n == 0 {
			log.info("Connection closed by peer (blocking recv)")
			send_message(ctx.conn_pid, Close_Connection{reason = "peer closed"})
			break
		}

		write_pos += u32(n)

		new_pos, frame_err := process_recv_frames(
			recv_buffer,
			write_pos,
			ctx,
			blocking_dispatch_message,
		)
		if frame_err != .None {
			reason: string
			switch frame_err {
			case .Zero_Size:
				reason = "zero message size"
			case .Too_Large:
				reason = "message too large"
			case .None:
				unreachable()
			}
			send_message(ctx.conn_pid, Close_Connection{reason = reason})
			return
		}
		write_pos = new_pos
	}

	log.debug("Blocking recv loop exiting")
}

process_blocking_recv_message :: proc(ctx: ^Blocking_Recv_Context, msg_data: []byte) {
	header, ok := parse_network_header(msg_data)
	if !ok {
		log.warn("Failed to parse network header in blocking recv")
		return
	}

	node_id := ctx.node_id_ptr^

	if .CONTROL in header.flags || .LIFECYCLE_EVENT in header.flags {
		msg_copy := make([]byte, len(msg_data))
		copy(msg_copy, msg_data)
		remote_msg := Remote_Message {
			from = pack_pid(Handle{}, node_id),
			data = msg_copy,
		}
		err := send_message(ctx.conn_pid, remote_msg)
		if err != .OK {
			log.warnf("Failed to send control/lifecycle message: %v", err)
		}
		delete(msg_copy)
		return
	}

	deliver_to_target(
		node_id,
		header.flags,
		header.type_hash,
		header.from_handle,
		header.to_handle,
		header.to_name,
		header.payload,
	)
}

@(private)
build_and_send_network_command :: proc(
	conn_pid: PID,
	content: $T,
	base_flags: Network_Message_Flags,
	to_handle: Handle,
	to_name: string,
) -> Send_Error {
	info := get_validated_message_info(T)
	from_handle, _ := unpack_pid(get_self_pid())

	flags := base_flags | {.POD_PAYLOAD}

	to_name_bytes: []byte
	to_name_len: u16 = 0
	actual_to_handle := to_handle
	if .BY_NAME in base_flags {
		to_name_bytes = transmute([]byte)to_name
		to_name_len = u16(len(to_name_bytes))
		actual_to_handle = Handle {
			idx = u32(to_name_len),
			gen = 0,
		}
	}

	content_copy := content
	total_string_size := 0
	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
			total_string_size += len(str_ptr^)
		}
	}
	payload_size := size_of(T) + total_string_size

	message_size := NETWORK_HEADER_SIZE + int(to_name_len) + payload_size
	total_buffer_size := 4 + message_size

	buffer := make([]byte, total_buffer_size)

	endian.put_u32(buffer[0:4], .Little, u32(message_size))

	write_network_header(buffer[4:], flags, info.type_hash, from_handle, actual_to_handle)

	offset := 4 + NETWORK_HEADER_SIZE

	if .BY_NAME in base_flags {
		copy(buffer[offset:], to_name_bytes)
		offset += int(to_name_len)
	}

	when size_of(T) > 0 {
		intrinsics.mem_copy_non_overlapping(rawptr(&buffer[offset]), &content_copy, size_of(T))
		offset += size_of(T)
	}

	if .Has_Strings in info.flags {
		for field in info.string_fields {
			str_ptr := cast(^string)(uintptr(&content_copy) + field.offset)
			if len(str_ptr^) > 0 {
				intrinsics.mem_copy_non_overlapping(
					rawptr(&buffer[offset]),
					raw_data(str_ptr^),
					len(str_ptr^),
				)
				offset += len(str_ptr^)
			}
		}
	}

	result := send_message(conn_pid, Raw_Network_Buffer{data = buffer})
	delete(buffer)
	return result
}

handle_lifecycle_event :: proc(from_node: Node_ID, type_hash: u64, payload: []byte) {
	spawned_info := get_validated_message_info(Actor_Spawned_Broadcast)
	terminated_info := get_validated_message_info(Actor_Terminated_Broadcast)

	if type_hash == spawned_info.type_hash {
		if len(payload) < size_of(Actor_Spawned_Broadcast) {
			log.warn("Spawn broadcast payload too short")
			return
		}

		msg: Actor_Spawned_Broadcast
		intrinsics.mem_copy_non_overlapping(
			&msg,
			raw_data(payload),
			size_of(Actor_Spawned_Broadcast),
		)

		str_offset := size_of(Actor_Spawned_Broadcast)

		name_len := len(msg.name)
		if name_len > 0 {
			if len(payload) < str_offset + name_len {
				log.warn("Spawn broadcast payload truncated at name")
				return
			}
			msg.name = string(payload[str_offset:str_offset + name_len])
			str_offset += name_len
		}

		source_name_len := len(msg.source_node_name)
		if source_name_len > 0 {
			if len(payload) < str_offset + source_name_len {
				log.warn("Spawn broadcast payload truncated at source_node_name")
				return
			}
			msg.source_node_name = string(payload[str_offset:str_offset + source_name_len])
		}

		handle_spawn_broadcast(msg, from_node)

	} else if type_hash == terminated_info.type_hash {
		if len(payload) < size_of(Actor_Terminated_Broadcast) {
			log.warn("Terminate broadcast payload too short")
			return
		}

		msg: Actor_Terminated_Broadcast
		intrinsics.mem_copy_non_overlapping(
			&msg,
			raw_data(payload),
			size_of(Actor_Terminated_Broadcast),
		)

		str_offset := size_of(Actor_Terminated_Broadcast)

		name_len := len(msg.name)
		if name_len > 0 {
			if len(payload) < str_offset + name_len {
				log.warn("Terminate broadcast payload truncated at name")
				return
			}
			msg.name = string(payload[str_offset:str_offset + name_len])
			str_offset += name_len
		}

		source_name_len := len(msg.source_node_name)
		if source_name_len > 0 {
			if len(payload) < str_offset + source_name_len {
				log.warn("Terminate broadcast payload truncated at source_node_name")
				return
			}
			msg.source_node_name = string(payload[str_offset:str_offset + source_name_len])
		}

		handle_terminate_broadcast(msg, from_node)

	} else if type_hash == get_validated_message_info(Remote_Spawn_Request).type_hash {
		handle_remote_spawn_request(from_node, payload)

	} else if type_hash == get_validated_message_info(Remote_Spawn_Response).type_hash {
		handle_remote_spawn_response(payload)

	} else if type_hash == get_validated_message_info(Subscribe_Remote).type_hash {
		if len(payload) >= size_of(Subscribe_Remote) {
			msg: Subscribe_Remote
			intrinsics.mem_copy_non_overlapping(&msg, raw_data(payload), size_of(Subscribe_Remote))
			handle_remote_subscribe(msg, from_node)
		}

	} else if type_hash == get_validated_message_info(Unsubscribe_Remote).type_hash {
		if len(payload) >= size_of(Unsubscribe_Remote) {
			msg: Unsubscribe_Remote
			intrinsics.mem_copy_non_overlapping(
				&msg,
				raw_data(payload),
				size_of(Unsubscribe_Remote),
			)
			handle_remote_unsubscribe(msg, from_node)
		}

	} else {
		log.warnf("Unknown lifecycle event type hash: %x", type_hash)
	}
}

@(private)
handle_remote_spawn_request :: proc(from_node: Node_ID, payload: []byte) {
	if len(payload) < size_of(Remote_Spawn_Request) {
		log.warn("Remote spawn request payload too short")
		return
	}

	msg: Remote_Spawn_Request
	intrinsics.mem_copy_non_overlapping(&msg, raw_data(payload), size_of(Remote_Spawn_Request))

	name_len := len(msg.actor_name)
	if name_len > 0 {
		name_start := size_of(Remote_Spawn_Request)
		if len(payload) < name_start + name_len {
			log.warn("Remote spawn request payload truncated at actor_name")
			return
		}
		msg.actor_name = string(payload[name_start:name_start + name_len])
	}

	spawn_func, found := get_spawn_func_by_hash(msg.spawn_func_name_hash)
	if !found {
		send_spawn_response(
			from_node,
			Remote_Spawn_Response {
				request_id = msg.request_id,
				success = false,
				pid = 0,
				error_msg = "Unknown spawn function",
			},
		)
		return
	}

	pid, ok := spawn_func(msg.actor_name, msg.parent_pid)

	send_spawn_response(
		from_node,
		Remote_Spawn_Response {
			request_id = msg.request_id,
			success = ok,
			pid = pid,
			error_msg = ok ? "" : "Spawn failed",
		},
	)
}

@(private)
handle_remote_spawn_response :: proc(payload: []byte) {
	if len(payload) < size_of(Remote_Spawn_Response) {
		log.warn("Remote spawn response payload too short")
		return
	}

	msg: Remote_Spawn_Response
	intrinsics.mem_copy_non_overlapping(&msg, raw_data(payload), size_of(Remote_Spawn_Response))

	error_len := len(msg.error_msg)
	if error_len > 0 {
		str_start := size_of(Remote_Spawn_Response)
		if len(payload) < str_start + error_len {
			log.warn("Remote spawn response payload truncated at error_msg")
			return
		}
		msg.error_msg = string(payload[str_start:str_start + error_len])
	}

	resolve_spawn_request(msg)
}

@(private)
send_spawn_response :: proc(to_node: Node_ID, response: Remote_Spawn_Response) {
	ring := get_connection_ring(to_node)
	if ring != nil && ring.state == .Ready {
		send_lifecycle_message(ring, response)
	} else {
		log.warnf("Cannot send spawn response to node %d - not connected", to_node)
	}
}

send_registry_snapshot :: proc(data: ^Connection_Actor_Data) {
	from_handle, _ := unpack_pid(get_self_pid())
	num_items := sync.atomic_load_explicit(&global_registry.num_items, .Acquire)
	sent: int

	local_info := NODE.node_registry[current_node_id]

	for i in 1 ..< num_items {
		entry := &global_registry.items[i]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 {
			continue
		}

		pid := sync.atomic_load_explicit(&entry.pid, .Acquire)

		if !is_local_pid(pid) {
			continue
		}

		if pid == NODE.pid || pid == OBSERVER_PID {
			continue
		}

		msg := Actor_Spawned_Broadcast {
			pid              = pid,
			name             = get_actor_name(pid),
			actor_type       = get_pid_actor_type(pid),
			parent_pid       = get_actor_parent(pid),
			ttl              = 0,
			source_node_name = NODE.name,
			source_port      = u16(local_info.address.port),
			source_ip        = ipv4_to_u32(local_info.address.address),
		}

		buf: [512]byte
		msg_len := build_wire_format_into_buffer(
			buf[:],
			msg,
			Handle{},
			from_handle,
			{.LIFECYCLE_EVENT},
			"",
		)
		if msg_len == 0 {
			continue
		}

		ring := get_pool_ring_ready(data.pool)
		if ring != nil {
			batch_append_message(ring, buf[:msg_len])
		} else {
			send_raw_connection_data(data, buf[4:msg_len])
		}

		sent += 1
	}

	log.infof("Sent registry snapshot with %d actors to node %s", sent, data.node_name)
}

send_node_directory :: proc(data: ^Connection_Actor_Data) {
	entry_count: u16 = 0
	total_size := 1 + 2 // type + entry_count
	for i in 2 ..< MAX_NODES {
		info := NODE.node_registry[i]
		if info.node_name == "" do continue
		if info.node_name == NODE.name || info.node_name == data.node_name do continue
		entry_count += 1
		total_size += 2 + len(info.node_name) + 4 + 2
	}

	if entry_count == 0 {
		return
	}

	ctrl_data := make([]byte, total_size)
	defer delete(ctrl_data)

	w := Ctrl_Writer {
		buf = ctrl_data,
	}
	ctrl_put_u8(&w, CTRL_MSG_NODE_DIRECTORY)
	ctrl_put_u16(&w, entry_count)

	for i in 2 ..< MAX_NODES {
		info := NODE.node_registry[i]
		if info.node_name == "" do continue
		if info.node_name == NODE.name || info.node_name == data.node_name do continue

		ctrl_put_str(&w, info.node_name)
		ctrl_put_u32(&w, ipv4_to_u32(info.address.address))
		ctrl_put_u16(&w, u16(info.address.port))
	}

	msg_buffer := wrap_control_message(ctrl_data)
	defer delete(msg_buffer)

	send_raw_connection_data(data, msg_buffer)
	log.infof("Sent node directory with %d entries to node %s", entry_count, data.node_name)
}

handle_node_directory :: proc(ctrl_data: []byte) {
	r := Ctrl_Reader {
		data = ctrl_data,
		pos  = 1,
		ok   = true,
	}
	entry_count := int(ctrl_get_u16(&r))
	if !r.ok {
		log.error("Node directory message too short")
		return
	}

	registered := 0
	for _ in 0 ..< entry_count {
		node_name := ctrl_get_str(&r)
		ip := ctrl_get_u32(&r)
		port := ctrl_get_u16(&r)
		if !r.ok {
			log.error("Node directory entry truncated")
			return
		}

		if node_name == NODE.name do continue
		if _, exists := get_node_by_name(node_name); exists do continue

		endpoint := net.Endpoint {
			address = u32_to_ipv4(ip),
			port    = int(port),
		}
		_, ok := register_node(node_name, endpoint, .TCP_Custom_Protocol)
		if ok {
			registered += 1
		}
	}

	if registered > 0 {
		log.infof("Registered %d nodes from node directory", registered)
	}
}

handle_spawn_broadcast :: proc(msg: Actor_Spawned_Broadcast, from_node: Node_ID) {
	source_name: string
	if msg.source_node_name != "" {
		source_name = msg.source_node_name
	} else {
		name_ok: bool
		source_name, name_ok = get_node_name(from_node)
		if !name_ok {
			log.warnf("Unknown node %d in spawn broadcast", from_node)
			return
		}
	}

	// Skip our own actors (can happen in mesh forwarding loops)
	if source_name == NODE.name {
		return
	}

	// Get or register source node (ensures we have connection info for lazy connections)
	source_node_id, found := get_node_by_name(source_name)
	if !found {
		endpoint := build_endpoint_from_broadcast(msg)
		source_node_id, _ = register_node(source_name, endpoint, .TCP_Custom_Protocol)
		if source_node_id == 0 {
			log.warnf("Failed to register source node %s from spawn broadcast", source_name)
			return
		}
	}

	handle, _ := unpack_pid(msg.pid)
	remapped_pid := pack_pid(handle, source_node_id)

	qualified_name := fmt.tprintf("%s@%s", msg.name, source_name)
	_, is_new := add_remote(&global_registry, remapped_pid, qualified_name)

	if is_new && msg.ttl > 0 {
		forward_msg := msg
		forward_msg.ttl -= 1
		broadcast_to_others(forward_msg, except = from_node)
	}
}

handle_terminate_broadcast :: proc(msg: Actor_Terminated_Broadcast, from_node: Node_ID) {
	source_name: string
	if msg.source_node_name != "" {
		source_name = msg.source_node_name
	} else {
		name_ok: bool
		source_name, name_ok = get_node_name(from_node)
		if !name_ok {
			log.warnf("Unknown node %d in terminate broadcast", from_node)
			return
		}
	}

	if source_name == NODE.name {
		return
	}

	source_node_id, found := get_node_by_name(source_name)
	if !found {
		return
	}

	handle, _ := unpack_pid(msg.pid)
	remapped_pid := pack_pid(handle, source_node_id)

	removed := remove_remote(&global_registry, remapped_pid)

	if removed && msg.ttl > 0 {
		forward_msg := msg
		forward_msg.ttl -= 1
		broadcast_to_others(forward_msg, except = from_node)
	}
}

send_disconnect_to_ring :: proc(ring: ^Connection_Ring, reason: string) {
	ctrl_buf: [256]byte
	w := Ctrl_Writer {
		buf = ctrl_buf[:],
	}
	ctrl_put_u8(&w, CTRL_MSG_DISCONNECT)
	ctrl_put_u16(&w, u16(current_node_id))
	ctrl_put_str(&w, reason)

	frame_buf: [512]byte
	n := frame_control_message(ctrl_buf[:w.pos], frame_buf[:])
	if n > len(frame_buf) {return}

	send_raw_via_ring(ring, frame_buf[:n])
	batch_flush(ring)
}

broadcast_graceful_disconnect :: proc(reason: string) {
	for node_id in 2 ..< MAX_NODES {
		ring := get_connection_ring(Node_ID(node_id))
		if ring != nil && ring.state == .Ready {
			send_disconnect_to_ring(ring, reason)
		}
	}
}
