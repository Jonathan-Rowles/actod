package actod

import "../pkgs/coro"
import "base:intrinsics"
import "core:crypto"
import "core:crypto/hash"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

WIRE_PROTOCOL_VERSION :: 5
HANDSHAKE_TIMEOUT_SECS :: 5
HANDSHAKE_TIMEOUT :: HANDSHAKE_TIMEOUT_SECS * time.Second
DUPLICATE_TAKEOVER_TIMEOUT :: 5 * time.Second

CTRL_MSG_HEARTBEAT :: 2
CTRL_MSG_NODE_DIRECTORY :: 3
CTRL_MSG_DISCONNECT :: 4
CTRL_MSG_HELLO :: 6
CTRL_MSG_NOISE_1 :: 7
CTRL_MSG_NOISE_2 :: 8
CTRL_MSG_UDP_INFO :: 9
CTRL_MSG_AUTH :: 10
CTRL_MSG_LIFECYCLE_STREAM :: 11

HELLO_FLAG_ENCRYPTED: u8 : 1 << 0
HELLO_FLAG_POOL_JOIN: u8 : 1 << 1

Connect_Request :: struct {
	node_id: Node_ID,
	address: net.Endpoint,
}

Close_Connection :: struct {
	reason: string,
}

Start_Receiving :: struct {}

Reconnect :: struct {
	delay: time.Duration,
}

Adopt_Pool_Ring :: struct {
	socket:   net.TCP_Socket,
	keys_ptr: u64,
}

Establish_Result :: enum {
	Established,
	Failed,
	Transferred,
}

Connection_State :: enum {
	Disconnected,
	Connecting,
	Connected,
	Failed,
}

Connection_Actor_Data :: struct {
	node_id:                   Node_ID,
	node_name:                 string,
	state:                     Connection_State,
	address:                   net.Endpoint,
	tcp_socket:                net.TCP_Socket,
	ring:                      ^Connection_Ring,
	io_ctx:                    ^IO_Context,
	last_heartbeat:            time.Time,
	heartbeat_interval:        time.Duration,
	heartbeat_timeout:         time.Duration,
	reconnect_initial_delay:   time.Duration,
	reconnect_retry_delay:     time.Duration,
	auth_password:             string,
	encrypted:                 bool,
	is_incoming:               bool,
	peer_initiated_disconnect: bool,
	pending_incoming_released: bool,
	ring_config:               Connection_Ring_Config,
	heartbeat_timer_id:        u32,
	reconnect_timer_id:        u32,
	peer_listen_port:          u16,
	peer_udp_port:             u16,
	my_join_token:             u64,
	peer_join_token:           u64,
	my_udp_token:              u32,
	peer_udp_token:            u32,
	udp_seed:                  [UDP_SEED_SIZE]byte,
	udp_seed_set:              bool,
	udp_activated:             bool,
}

Connection_Actor_Behaviour :: Actor_Behaviour(Connection_Actor_Data) {
	handle_message = connection_handle_message,
	init           = connection_actor_init,
	terminate      = connection_actor_terminate,
}

connection_actor_init :: proc(data: ^Connection_Actor_Data) {
	data.encrypted = NODE.config.network.enable_encryption
	if data.node_id != 0 do data.ring = get_or_create_node_ring(data.node_id, data.ring_config)
}

@(private)
conn_pool :: proc(data: ^Connection_Actor_Data) -> ^Connection_Pool {
	return data.ring != nil ? data.ring.pool : nil
}

@(private)
close_conn_socket :: proc(data: ^Connection_Actor_Data) {
	if data.tcp_socket != 0 {
		close_tcp(data.tcp_socket)
		data.tcp_socket = 0
	}
}

connection_actor_terminate :: proc(data: ^Connection_Actor_Data) {
	is_active := is_active_connection(data)

	if data.node_id != 0 && is_active && data.ring != nil {
		sync.atomic_store(&data.ring.io_stop, 1)
	}
	close_conn_socket(data)

	cancel_timer(data.heartbeat_timer_id)
	cancel_timer(data.reconnect_timer_id)

	if data.node_id != 0 && is_active {
		stop_connection_io(data)

		udp_clear_peer(data.node_id)
		if data.ring != nil {
			drain_pool_rings_into_primary(data)
			teardown_pool_rings(data)
			if pool := data.ring.pool; pool != nil {
				sync.atomic_store_explicit(&pool.conn_pid, u64(0), .Release)
			}
			survivor := get_connection_ring(data.node_id)
			if survivor != nil && survivor != data.ring {
				migrated := ring_migrate_slots(data.ring, survivor)
				if migrated > 0 {
					log.infof(
						"Migrated %d buffered send slots to the surviving connection for node %s (id=%d)",
						migrated,
						data.node_name,
						data.node_id,
					)
				}
			}
			if survivor == data.ring && !sync.atomic_load(&NODE.shutting_down) {
				log.infof(
					"Connection actor for node %s (id=%d) terminating while its ring is still registered, leaving buffered slots for the replacement to migrate",
					data.node_name,
					data.node_id,
				)
			} else {
				dropped := ring_reset(data.ring)
				if dropped > 0 {
					log.warnf(
						"Connection actor for node %s (id=%d) terminating with %d buffered slots dropped",
						data.node_name,
						data.node_id,
						dropped,
					)
				}
			}
		}
		sync.atomic_store(&NODE.lifecycle_stream_peers[data.node_id], false)
		sync.atomic_store_explicit(
			cast(^u64)&NODE.connection_actors[data.node_id],
			u64(0),
			.Release,
		)
	}

	release_pending_incoming(data)
}

@(private)
release_pending_incoming :: proc(data: ^Connection_Actor_Data) {
	if data.is_incoming && !data.pending_incoming_released {
		data.pending_incoming_released = true
		sync.atomic_sub(&g_pending_incoming_handshakes, 1)
	}
}

connection_handle_message :: proc(data: ^Connection_Actor_Data, from: PID, msg: any) {
	switch m in msg {
	case Connect_Request:
		if data.state != .Disconnected && data.state != .Failed do return
		cancel_timer(data.reconnect_timer_id)
		data.address = m.address
		if data.node_id == 0 do data.node_id = m.node_id
		data.state = .Connecting
		if !initiate_connection(data) {
			data.state = .Failed
			data.reconnect_timer_id, _ = set_timer(data.reconnect_retry_delay, false)
		}

	case Close_Connection:
		if data.state == .Disconnected || data.state == .Failed do return
		log.infof("Closing connection to node %d: %s", data.node_id, m.reason)
		close_connection(data)

	case Start_Receiving:
		if !data.is_incoming || data.tcp_socket == 0 || data.state != .Disconnected do return
		data.state = .Connecting
		result := establish_connection(data)
		release_pending_incoming(data)
		if result != .Established {
			close_conn_socket(data)
			data.state = .Disconnected
			_ = terminate_actor(get_self_pid(), .SHUTDOWN)
		}

	case Remote_Message:
		handle_incoming_data(data, m.data)

	case Scale_Up_Request:
		if data.state == .Connected {
			pool := conn_pool(data)
			if pool != nil {
				sync.atomic_store(&pool.contention_count, u32(0))
				if pool_active_count(pool) < pool.max_rings {
					establish_pool_ring(data)
					sync.atomic_store(&pool.scale_up_requested, u32(0))
				}
			}
		}

	case Adopt_Pool_Ring:
		adopt_pool_ring(data, m)

	case Pool_Ring_Closed:
		pool := conn_pool(data)
		if pool != nil {
			count := pool_active_count(pool)
			for i: u32 = 1; i < count; i += 1 {
				pr := get_pool_ring_at(pool, i)
				if pr == nil || u64(uintptr(pr)) != m.ring_ptr do continue
				if sync.atomic_load(&pr.park_state) == .Active {
					sync.atomic_store(&pr.park_state, Ring_Park_State.Park_Asked)
				}
				break
			}
		}

	case Timer_Tick:
		if data.state == .Connected {
			if m.id == data.heartbeat_timer_id && data.heartbeat_interval > 0 {
				send_heartbeat(data)
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
	}
}

initiate_connection :: proc(data: ^Connection_Actor_Data) -> bool {
	sock, err := runtime_dial_tcp(data.address)
	if err != nil {
		log.warnf(
			"Failed to connect to node %d: %v, a reconnect is scheduled",
			data.node_id,
			err,
		)
		return false
	}

	data.tcp_socket = sock
	if establish_connection(data) != .Established {
		close_conn_socket(data)
		return false
	}
	return true
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

Hello_Info :: struct {
	version:     u32,
	encrypted:   bool,
	pool_join:   bool,
	listen_port: u16,
	udp_port:    u16,
	node_name:   string,
	nonce:       u64,
	join_token:  u64,
	incarnation: u64,
	gossip_seq:  u64,
}

@(private)
build_hello_body :: proc(
	data: ^Connection_Actor_Data,
	nonce: u64,
	join_token: u64,
	pool_join: bool,
) -> []byte {
	flags: u8 = 0
	if data.encrypted do flags |= HELLO_FLAG_ENCRYPTED
	if pool_join do flags |= HELLO_FLAG_POOL_JOIN

	total := 1 + 4 + 1 + 2 + 2 + (2 + len(NODE.name)) + 8 + 8 + 8 + 8
	body := make([]byte, total)
	w := Ctrl_Writer {
		buf = body,
	}
	ctrl_put_u8(&w, CTRL_MSG_HELLO)
	ctrl_put_u32(&w, WIRE_PROTOCOL_VERSION)
	ctrl_put_u8(&w, flags)
	ctrl_put_u16(&w, u16(NODE.config.network.port))
	ctrl_put_u16(&w, u16(NODE.config.network.udp_port))
	ctrl_put_str(&w, NODE.name)
	ctrl_put_u64(&w, nonce)
	ctrl_put_u64(&w, join_token)
	ctrl_put_u64(&w, NODE.incarnation)
	ctrl_put_u64(&w, sync.atomic_load(&NODE.gossip_seq))
	return body
}

@(private)
parse_hello :: proc(payload: []byte) -> (info: Hello_Info, ok: bool) {
	r := Ctrl_Reader {
		data = payload,
		pos  = 1,
		ok   = true,
	}
	info.version = ctrl_get_u32(&r)
	flags := ctrl_get_u8(&r)
	info.listen_port = ctrl_get_u16(&r)
	info.udp_port = ctrl_get_u16(&r)
	info.node_name = ctrl_get_str(&r)
	info.nonce = ctrl_get_u64(&r)
	info.join_token = ctrl_get_u64(&r)
	if r.pos + 8 <= len(r.data) do info.incarnation = ctrl_get_u64(&r)
	if r.pos + 8 <= len(r.data) do info.gossip_seq = ctrl_get_u64(&r)
	info.encrypted = flags & HELLO_FLAG_ENCRYPTED != 0
	info.pool_join = flags & HELLO_FLAG_POOL_JOIN != 0
	return info, r.ok && len(info.node_name) > 0
}

@(private)
compute_auth_proof :: proc(password, node_name: string, challenge: u64) -> string {
	auth_input := fmt.tprintf("%s:%s:%d", password, node_name, challenge)
	digest := hash.hash_string(.SHA256, auth_input)
	proof := fmt.tprintf("%x", digest)
	delete(digest)
	return proof
}

@(private)
perform_plaintext_auth :: proc(
	data: ^Connection_Actor_Data,
	sock: net.TCP_Socket,
	my_nonce: u64,
	info: Hello_Info,
	deadline: time.Time,
) -> bool {
	if data.encrypted || data.auth_password == "" do return true

	proof := compute_auth_proof(data.auth_password, NODE.name, info.nonce)
	body := make([]byte, 1 + 2 + len(proof))
	defer delete(body)
	w := Ctrl_Writer {
		buf = body,
	}
	ctrl_put_u8(&w, CTRL_MSG_AUTH)
	ctrl_put_str(&w, proof)
	if !handshake_send_ctrl(sock, body[:w.pos]) do return false

	raw, payload := handshake_recv_ctrl(sock, CTRL_MSG_AUTH, deadline)
	if raw == nil {
		log.errorf("Authentication failed from node %s (no proof)", info.node_name)
		return false
	}
	defer delete(raw, actor_system_allocator)

	r := Ctrl_Reader {
		data = payload,
		pos  = 1,
		ok   = true,
	}
	peer_proof := ctrl_get_str(&r)
	if !r.ok do return false

	expected := compute_auth_proof(data.auth_password, info.node_name, my_nonce)
	if crypto.compare_constant_time(transmute([]byte)peer_proof, transmute([]byte)expected) != 1 {
		log.errorf("Authentication failed from node %s", info.node_name)
		return false
	}
	return true
}

@(private)
handshake_send_ctrl :: proc(sock: net.TCP_Socket, ctrl_body: []byte) -> bool {
	frame := make([]byte, 4 + NETWORK_HEADER_SIZE + len(ctrl_body))
	defer delete(frame)
	n := frame_control_message(ctrl_body, frame)
	when ODIN_TEST {
		drop, dup, _ := frame_tap(.Out, FRAME_TAP_HANDSHAKE, frame[:n])
		if drop do return true
		if dup do _ = tcp_send_all(sock, frame[:n])
	}
	return tcp_send_all(sock, frame[:n])
}

@(private)
handshake_recv_ctrl :: proc(
	sock: net.TCP_Socket,
	expected_type: u8,
	deadline: time.Time,
) -> (
	raw: []byte,
	payload: []byte,
) {
	raw = tcp_recv_framed_message(sock, deadline)
	if raw == nil do return nil, nil
	when ODIN_TEST {
		drop, _, _ := frame_tap(.In, FRAME_TAP_HANDSHAKE, raw)
		if drop {
			delete(raw, actor_system_allocator)
			return nil, nil
		}
	}
	header, ok := parse_network_header(raw)
	if !ok ||
	   .CONTROL not_in header.flags ||
	   len(header.payload) < 1 ||
	   header.payload[0] != expected_type {
		delete(raw, actor_system_allocator)
		return nil, nil
	}
	return raw, header.payload
}

@(private)
run_noise_handshake :: proc(
	data: ^Connection_Actor_Data,
	sock: net.TCP_Socket,
	initiator: bool,
	my_hello: []byte,
	peer_hello: []byte,
	keys: ^Noise_Transport,
	deadline: time.Time,
) -> bool {
	psk, psk_ok := derive_cluster_psk(data.auth_password)
	if !psk_ok {
		log.error("Refusing encrypted handshake: cluster PSK derivation failed")
		return false
	}

	dialer_body := my_hello if initiator else peer_hello
	responder_body := peer_hello if initiator else my_hello
	prologue := make([]byte, len(dialer_body) + len(responder_body))
	defer delete(prologue)
	copy(prologue, dialer_body)
	copy(prologue[len(dialer_body):], responder_body)

	hs: Noise_Handshake
	if !noise_handshake_begin(&hs, initiator, prologue, psk[:]) {
		log.error("Failed to initialize noise handshake")
		return false
	}

	if initiator {
		msg1, _, ok1 := noise_handshake_step(&hs, nil)
		if !ok1 || msg1 == nil do return false
		sent1 := send_noise_ctrl(sock, CTRL_MSG_NOISE_1, msg1)
		delete(msg1)
		if !sent1 do return false

		raw2, payload2 := handshake_recv_ctrl(sock, CTRL_MSG_NOISE_2, deadline)
		if raw2 == nil {
			log.warn("Did not receive noise response from peer")
			return false
		}
		defer delete(raw2, actor_system_allocator)

		out, done, ok2 := noise_handshake_step(&hs, payload2[1:])
		if out != nil do delete(out)
		if !ok2 || !done {
			log.error("Noise handshake failed (wrong cluster password?)")
			return false
		}
	} else {
		raw1, payload1 := handshake_recv_ctrl(sock, CTRL_MSG_NOISE_1, deadline)
		if raw1 == nil {
			log.warn("Did not receive noise initiation from peer")
			return false
		}
		defer delete(raw1, actor_system_allocator)

		msg2, done, ok2 := noise_handshake_step(&hs, payload1[1:])
		if !ok2 || !done || msg2 == nil {
			log.error("Noise handshake failed (wrong cluster password?)")
			return false
		}
		sent2 := send_noise_ctrl(sock, CTRL_MSG_NOISE_2, msg2)
		delete(msg2)
		if !sent2 do return false
	}

	return noise_handshake_finish(&hs, keys)
}

@(private)
send_noise_ctrl :: proc(sock: net.TCP_Socket, ctrl_type: u8, msg: []byte) -> bool {
	body := make([]byte, 1 + len(msg))
	defer delete(body)
	body[0] = ctrl_type
	copy(body[1:], msg)
	return handshake_send_ctrl(sock, body)
}

@(private)
establish_connection :: proc(data: ^Connection_Actor_Data) -> Establish_Result {
	sock := data.tcp_socket
	if !sim_is_socket(sock) do net.set_blocking(sock, true)
	set_recv_timeout(sock, HANDSHAKE_TIMEOUT_SECS)
	deadline := time.time_add(now(), HANDSHAKE_TIMEOUT)

	data.my_join_token = generate_nonzero_nonce()
	my_nonce := generate_nonce()
	my_hello := build_hello_body(data, my_nonce, data.my_join_token, false)
	defer delete(my_hello)

	peer_raw: []byte
	peer_payload: []byte
	if data.is_incoming {
		peer_raw, peer_payload = handshake_recv_ctrl(sock, CTRL_MSG_HELLO, deadline)
		if peer_raw == nil {
			log.warn("Failed to read HELLO from incoming connection")
			return .Failed
		}
		if !handshake_send_ctrl(sock, my_hello) {
			delete(peer_raw, actor_system_allocator)
			return .Failed
		}
	} else {
		if !handshake_send_ctrl(sock, my_hello) do return .Failed
		peer_raw, peer_payload = handshake_recv_ctrl(sock, CTRL_MSG_HELLO, deadline)
		if peer_raw == nil {
			log.warnf("Failed to read HELLO from node %d", data.node_id)
			return .Failed
		}
	}
	defer delete(peer_raw, actor_system_allocator)

	info, parsed := parse_hello(peer_payload)
	if !parsed {
		log.warn("Malformed HELLO from peer")
		return .Failed
	}
	if info.version != WIRE_PROTOCOL_VERSION {
		log.warnf(
			"Protocol version mismatch with node %s: peer v%d, ours v%d",
			info.node_name,
			info.version,
			WIRE_PROTOCOL_VERSION,
		)
		return .Failed
	}
	if info.encrypted != data.encrypted {
		log.warnf(
			"Encryption mode mismatch with node %s (peer encrypted=%v, ours=%v)",
			info.node_name,
			info.encrypted,
			data.encrypted,
		)
		return .Failed
	}
	if !perform_plaintext_auth(data, sock, my_nonce, info, deadline) do return .Failed

	if info.pool_join {
		if !data.is_incoming {
			log.warn("Unexpected pool-join flag in HELLO response")
			return .Failed
		}
		return handle_incoming_pool_join(data, my_hello, peer_payload, info, deadline)
	}

	keys: Noise_Transport
	if data.encrypted {
		if !run_noise_handshake(data, sock, !data.is_incoming, my_hello, peer_payload, &keys, deadline) {
			return .Failed
		}
	}

	set_recv_timeout(sock, 0)

	if data.is_incoming {
		if !resolve_incoming_peer(data, info) do return .Failed
	}

	if data.ring == nil do data.ring = get_or_create_node_ring(data.node_id, data.ring_config)
	if data.ring == nil {
		log.errorf("No connection ring available for node %d", data.node_id)
		return .Failed
	}

	ring := data.ring
	ring.node_id = data.node_id
	ring.conn_pid = get_self_pid()
	ring.tcp_socket = data.tcp_socket
	if data.encrypted do ring.transport_keys = keys
	replaced := get_connection_ring(data.node_id)
	register_connection_ring(data.node_id, ring)
	if replaced != nil &&
	   replaced != ring &&
	   sync.atomic_load_explicit(&replaced.io_owner, .Acquire) == 0 {
		if migrated := ring_migrate_slots(replaced, ring); migrated > 0 {
			log.infof(
				"Migrated %d buffered send slots from the replaced connection for node %d",
				migrated,
				data.node_id,
			)
		}
	}

	if !start_connection_io(data) do return .Failed

	registry_name, _ := get_node_name(data.node_id)
	data.node_name = registry_name
	data.peer_listen_port = info.listen_port
	data.peer_udp_port = info.udp_port
	data.peer_join_token = info.join_token
	set_node_incarnation(data.node_id, info.incarnation)
	gossip_seq_reset(data.node_id, info.gossip_seq)
	data.last_heartbeat = now()
	data.peer_initiated_disconnect = false
	data.state = .Connected

	if pool := ring.pool; pool != nil {
		sync.atomic_store_explicit(&pool.conn_pid, u64(get_self_pid()), .Release)
		sync.atomic_store(&pool.join_token, data.my_join_token)
	}

	self_rename(fmt.tprintf("%s_connection", data.node_name))

	log.infof(
		"Handshake successful with node %s (id=%d, v%d, encrypted=%v)",
		data.node_name,
		data.node_id,
		info.version,
		data.encrypted,
	)

	announce_subscriptions_to_node(data.node_id)
	send_node_directory(data)
	send_udp_info(data)
	try_activate_udp(data)
	request_lifecycle_stream(data)

	if data.heartbeat_interval > 0 {
		data.heartbeat_timer_id, _ = set_timer(data.heartbeat_interval, true)
	}

	return .Established
}

// Runs on the temporary incoming actor.
@(private)
handle_incoming_pool_join :: proc(
	data: ^Connection_Actor_Data,
	my_hello: []byte,
	peer_hello: []byte,
	info: Hello_Info,
	deadline: time.Time,
) -> Establish_Result {
	sock := data.tcp_socket

	keys: Noise_Transport
	if data.encrypted {
		if !run_noise_handshake(data, sock, false, my_hello, peer_hello, &keys, deadline) {
			return .Failed
		}
	}

	set_recv_timeout(sock, 0)

	owner_pid := find_pool_owner_by_join_token(info.join_token)
	if owner_pid == 0 {
		log.warnf("Pool join from %s with unknown token", info.node_name)
		return .Failed
	}

	if owner_ptr, owner_alive := get(&NODE.actor_registry, owner_pid); !owner_alive || owner_ptr == nil {
		log.warnf("Pool join from %s: owner connection gone", info.node_name)
		return .Failed
	}

	keys_ptr: u64 = 0
	if data.encrypted {
		keys_box := new(Noise_Transport, get_system_allocator())
		keys_box^ = keys
		crypto.zero_explicit(&keys, size_of(Noise_Transport))
		keys_ptr = u64(uintptr(keys_box))
	}

	err := send_message(owner_pid, Adopt_Pool_Ring{socket = sock, keys_ptr = keys_ptr})
	if err != .OK {
		log.warnf("Failed to hand pool ring to connection actor: %v", err)
		free_boxed_keys(keys_ptr)
		return .Failed
	}

	data.tcp_socket = 0
	log.infof("Accepted pool ring join from node %s", info.node_name)
	return .Transferred
}

@(private)
establish_pool_ring :: proc(data: ^Connection_Actor_Data) -> bool {
	pool := conn_pool(data)
	if pool == nil || data.peer_join_token == 0 do return false
	if pool_active_count(pool) >= pool.max_rings do return false

	dial_endpoint := net.Endpoint {
		address = data.address.address,
		port    = int(data.peer_listen_port),
	}
	sock, err := runtime_dial_tcp(dial_endpoint)
	if err != nil {
		log.warnf("Pool scale-up: failed to dial node %d: %v", data.node_id, err)
		return false
	}

	if !sim_is_socket(sock) do net.set_blocking(sock, true)
	set_recv_timeout(sock, HANDSHAKE_TIMEOUT_SECS)
	deadline := time.time_add(now(), HANDSHAKE_TIMEOUT)

	ok := false
	defer if !ok do close_tcp(sock)

	my_nonce := generate_nonce()
	my_hello := build_hello_body(data, my_nonce, data.peer_join_token, true)
	defer delete(my_hello)

	if !handshake_send_ctrl(sock, my_hello) do return false
	peer_raw, peer_payload := handshake_recv_ctrl(sock, CTRL_MSG_HELLO, deadline)
	if peer_raw == nil {
		log.warnf("Pool scale-up: no HELLO reply from node %d", data.node_id)
		return false
	}
	defer delete(peer_raw, actor_system_allocator)

	info, parsed := parse_hello(peer_payload)
	if !parsed || info.version != WIRE_PROTOCOL_VERSION || info.encrypted != data.encrypted {
		return false
	}
	if !perform_plaintext_auth(data, sock, my_nonce, info, deadline) do return false

	keys: Noise_Transport
	if data.encrypted {
		if !run_noise_handshake(data, sock, true, my_hello, peer_payload, &keys, deadline) {
			return false
		}
	}

	set_recv_timeout(sock, 0)

	if !attach_pool_ring(data, sock, keys) do return false

	ok = true
	log.infof(
		"Pool scaled up for node %s (id=%d): %d rings",
		data.node_name,
		data.node_id,
		pool_active_count(pool),
	)
	return true
}

@(private)
attach_pool_ring :: proc(
	data: ^Connection_Actor_Data,
	sock: net.TCP_Socket,
	keys: Noise_Transport,
) -> bool {
	pool := conn_pool(data)
	if pool == nil do return false

	ring := pool_take_parked(pool)
	if ring == nil {
		ring = make_connection_ring(data.ring_config, data.encrypted, get_system_allocator())
	}
	if ring == nil do return false

	ring.node_id = data.node_id
	ring.conn_pid = get_self_pid()
	ring.tcp_socket = sock
	sync.atomic_store(&ring.last_activity_time, time.to_unix_nanoseconds(now()))
	if data.encrypted do ring.transport_keys = keys

	if !set_tcp_nodelay(sock, ring.tcp_nodelay) {
		log.warn("Failed to set TCP_NODELAY on pool ring")
	}
	if !set_socket_buffers(sock) do log.warn("Failed to set socket buffers on pool ring")

	if !pool_add_ring(pool, ring) {
		ring.tcp_socket = 0
		pool_park(pool, ring)
		return false
	}

	if NODE.config.sim_mode && !sim_attach_pool_ring(ring, get_self_pid()) {
		pool_remove_active(pool, ring)
		ring.tcp_socket = 0
		pool_park(pool, ring)
		return false
	}
	return true
}

@(private)
free_boxed_keys :: proc(keys_ptr: u64) {
	if keys_ptr == 0 do return
	keys_box := cast(^Noise_Transport)rawptr(uintptr(keys_ptr))
	crypto.zero_explicit(keys_box, size_of(Noise_Transport))
	free(keys_box, get_system_allocator())
}

@(private)
adopt_pool_ring :: proc(data: ^Connection_Actor_Data, msg: Adopt_Pool_Ring) {
	keys: Noise_Transport
	if msg.keys_ptr != 0 {
		keys_box := cast(^Noise_Transport)rawptr(uintptr(msg.keys_ptr))
		keys = keys_box^
	}
	free_boxed_keys(msg.keys_ptr)

	pool := conn_pool(data)
	if data.state != .Connected || pool == nil {
		close_tcp(msg.socket)
		return
	}
	if pool_active_count(pool) >= pool.max_rings {
		close_tcp(msg.socket)
		return
	}
	if !attach_pool_ring(data, msg.socket, keys) {
		close_tcp(msg.socket)
		return
	}
	log.infof(
		"Adopted pool ring from node %s (id=%d): %d rings",
		data.node_name,
		data.node_id,
		pool_active_count(pool),
	)
}

@(private)
pool_check_scaling :: proc(data: ^Connection_Actor_Data) {
	pool := conn_pool(data)
	if pool == nil do return

	finalize_parked_rings(data, pool)

	idle_secs := data.ring_config.scale_down_idle_seconds
	if idle_secs == 0 do idle_secs = 10
	idle_ns := i64(idle_secs) * 1_000_000_000
	now_ns := time.to_unix_nanoseconds(now())

	count := pool_active_count(pool)
	for i: u32 = 1; i < count; i += 1 {
		ring := get_pool_ring_at(pool, i)
		if ring == nil do continue
		if sync.atomic_load(&ring.park_state) != .Active do continue
		last := sync.atomic_load(&ring.last_activity_time)
		if last != 0 && (now_ns - last) > idle_ns {
			sync.atomic_store(&ring.park_state, Ring_Park_State.Park_Asked)
		}
	}

	contention := sync.atomic_exchange(&pool.contention_count, 0)
	if contention > pool.contention_threshold && pool_active_count(pool) < pool.max_rings {
		establish_pool_ring(data)
	}
	sync.atomic_store(&pool.scale_up_requested, 0)
}

@(private)
park_pool_ring :: proc(pool: ^Connection_Pool, ring: ^Connection_Ring, migrate: bool) {
	pool_remove_active(pool, ring)
	if ring.tcp_socket != 0 do close_tcp(ring.tcp_socket)
	if migrate {
		primary := get_pool_ring_at(pool, 0)
		if primary != nil && primary != ring do _ = ring_migrate_slots(ring, primary)
	}
	ring_reset(ring)
	pool_park(pool, ring)
}

@(private)
finalize_parked_rings :: proc(data: ^Connection_Actor_Data, pool: ^Connection_Pool) {
	count := pool_active_count(pool)
	for i := count; i > 1; i -= 1 {
		ring := get_pool_ring_at(pool, i - 1)
		if ring == nil do continue
		if sync.atomic_load(&ring.park_state) != .Park_Acked do continue
		park_pool_ring(pool, ring, migrate = true)
		log.infof(
			"Pool ring parked for node %s (id=%d): %d rings",
			data.node_name,
			data.node_id,
			pool_active_count(pool),
		)
	}
}

// Called with the IO thread already stopped and joined.
@(private)
drain_pool_rings_into_primary :: proc(data: ^Connection_Actor_Data) {
	pool := conn_pool(data)
	if pool == nil do return

	count := pool_active_count(pool)
	for i := count; i > 1; i -= 1 {
		ring := get_pool_ring_at(pool, i - 1)
		if ring == nil || ring == data.ring do continue
		_ = ring_migrate_slots(ring, data.ring)
	}
}

// Called with the IO thread already stopped and joined: every pool ring is
// quiesced, so reset them all and park for reuse by the next session.
@(private)
teardown_pool_rings :: proc(data: ^Connection_Actor_Data) {
	pool := conn_pool(data)
	if pool == nil do return

	count := pool_active_count(pool)
	for i := count; i > 1; i -= 1 {
		ring := get_pool_ring_at(pool, i - 1)
		if ring == nil do continue
		park_pool_ring(pool, ring, migrate = false)
	}

	sync.atomic_store(&pool.contention_count, u32(0))
	sync.atomic_store(&pool.scale_up_requested, u32(0))
	sync.atomic_store(&pool.join_token, u64(0))
}

@(private)
resolve_incoming_peer :: proc(data: ^Connection_Actor_Data, info: Hello_Info) -> bool {
	peer_endpoint := net.Endpoint {
		address = data.address.address,
		port    = int(info.listen_port),
	}

	local_node_id, registered := register_discovered_node(info.node_name, peer_endpoint, .TCP_Custom_Protocol)
	if !registered {
		local_node_id, registered = get_node_by_name(info.node_name)
		if !registered {
			log.errorf("Failed to register remote node %s", info.node_name)
			return false
		}
	}
	data.node_id = local_node_id

	existing_conn := PID(
		sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[local_node_id], .Acquire),
	)
	if existing_conn != 0 && existing_conn != get_self_pid() {
		our_port := NODE.config.network.port
		their_port := int(info.listen_port)
		we_keep_outgoing :=
			our_port > their_port || (our_port == their_port && NODE.name < info.node_name)

		if we_keep_outgoing {
			log.infof(
				"Closing duplicate incoming from %s (keeping outgoing, port %d > %d)",
				info.node_name,
				our_port,
				their_port,
			)
			return false
		}

		log.infof(
			"Replacing outgoing with incoming from %s (port %d <= %d)",
			info.node_name,
			our_port,
			their_port,
		)
		_ = terminate_actor(existing_conn, .SHUTDOWN)
		if !wait_for_actor_exit(existing_conn, DUPLICATE_TAKEOVER_TIMEOUT) {
			log.errorf("Timed out waiting for duplicate connection actor to exit")
			return false
		}
	}

	sync.atomic_store_explicit(
		cast(^u64)&NODE.connection_actors[local_node_id],
		u64(get_self_pid()),
		.Release,
	)
	return true
}

@(private)
wait_for_actor_exit :: proc(pid: PID, timeout: time.Duration) -> bool {
	iterations := int(timeout / time.Millisecond)
	co := coro.running()
	for _ in 0 ..< iterations {
		if actor_ptr, exists := get(&NODE.actor_registry, pid); !exists || actor_ptr == nil {
			return true
		}
		if co != nil {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.wants_reschedule = true
			coro.yield(co)
		} else if NODE.config.sim_mode {
			if !sim_pump() do runtime_sleep(1 * time.Millisecond)
		} else {
			runtime_sleep(1 * time.Millisecond)
		}
	}
	actor_ptr, exists := get(&NODE.actor_registry, pid)
	return !exists || actor_ptr == nil
}

@(private)
start_connection_io :: proc(data: ^Connection_Actor_Data) -> bool {
	ring := data.ring

	if NODE.config.sim_mode do return sim_start_connection_io(data)

	if !set_tcp_nodelay(data.tcp_socket, ring.tcp_nodelay) do log.warn("Failed to set TCP_NODELAY")
	if !set_socket_buffers(data.tcp_socket) do log.warn("Failed to set socket buffers")

	ctx := new(IO_Context)
	ctx.ring = ring
	ctx.conn_pid = get_self_pid()
	ctx.allocator = context.allocator
	ctx.logger = context.logger

	sync.atomic_store(&ring.io_stop, 0)

	prev_allocator := context.allocator
	context.allocator = get_system_allocator()
	t := thread.create(nbio_io_loop)
	context.allocator = prev_allocator
	if t == nil {
		free(ctx)
		log.error("Failed to create connection IO thread")
		return false
	}
	t.user_args[0] = ctx
	data.io_ctx = ctx
	ring.io_thread = t
	thread.start(t)
	return true
}

@(private)
stop_connection_io :: proc(data: ^Connection_Actor_Data) {
	ring := data.ring
	if ring == nil do return
	sync.atomic_store(&ring.io_stop, 1)
	if NODE.config.sim_mode do sim_stop_connection_io(ring)
	if ring.io_thread != nil {
		thread.join(ring.io_thread)
		thread.destroy(ring.io_thread)
		ring.io_thread = nil
	}
	sync.atomic_store(&ring.io_stop, 0)
	if data.io_ctx != nil {
		free(data.io_ctx)
		data.io_ctx = nil
	}
}

is_active_connection :: proc(data: ^Connection_Actor_Data) -> bool {
	if data.node_id == 0 || data.node_id >= MAX_NODES do return false
	current_conn := PID(
		sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[data.node_id], .Acquire),
	)
	return current_conn == get_self_pid()
}

close_connection :: proc(data: ^Connection_Actor_Data) {
	is_active := is_active_connection(data)

	if data.node_id != 0 && is_active {
		sync.atomic_store(&NODE.lifecycle_stream_peers[data.node_id], false)
		clear_subscriptions_for_node(data.node_id)
		broadcast_disconnect_terminations(data.node_id)
		handle_node_disconnect(data.node_id)
		udp_clear_peer(data.node_id)
	}

	if data.ring != nil do sync.atomic_store(&data.ring.io_stop, 1)
	close_conn_socket(data)
	stop_connection_io(data)

	if data.ring != nil && is_active {
		teardown_pool_rings(data)
		dropped := ring_reset(data.ring)
		if dropped > 0 {
			log.warnf(
				"Dropped %d buffered send slots for node %d on disconnect",
				dropped,
				data.node_id,
			)
		}
	}

	data.state = .Disconnected
	data.udp_activated = false
	data.peer_udp_token = 0
	data.udp_seed_set = false
	cancel_timer(data.heartbeat_timer_id)

	if data.is_incoming {
		_ = terminate_actor(get_self_pid(), .SHUTDOWN)
		return
	}

	if !data.peer_initiated_disconnect {
		data.reconnect_timer_id, _ = set_timer(data.reconnect_initial_delay, false)
		log.infof(
			"Scheduled reconnection for node %d in %v",
			data.node_id,
			data.reconnect_initial_delay,
		)
	}
}

handle_incoming_data :: proc(data: ^Connection_Actor_Data, raw_data: []byte) {
	header, ok := parse_network_header(raw_data)
	if !ok {
		log.error("Failed to parse network message header")
		return
	}

	if .CONTROL in header.flags {
		handle_control_message(data, header.payload)
		return
	}

	if .LIFECYCLE_EVENT in header.flags {
		handle_lifecycle_event(data.node_id, header.type_hash, header.payload)
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
		header.ask_token,
	)
}

handle_control_message :: proc(data: ^Connection_Actor_Data, ctrl_data: []byte) {
	if len(ctrl_data) < 1 {
		log.error("Control message too short")
		return
	}

	switch ctrl_data[0] {
	case CTRL_MSG_HEARTBEAT:
		if len(ctrl_data) < 1 + 8 + 8 {
			log.error("Heartbeat message too short")
			return
		}
		data.last_heartbeat = now()

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
		if !r.ok do return
		log.infof("Node %s (id=%d) graceful disconnect: %s", data.node_name, node_id, reason)
		data.peer_initiated_disconnect = true
		close_connection(data)

	case CTRL_MSG_UDP_INFO:
		handle_udp_info(data, ctrl_data)

	case CTRL_MSG_LIFECYCLE_STREAM:
		if data.node_id != 0 && data.node_id < MAX_NODES {
			sync.atomic_store(&NODE.lifecycle_stream_peers[data.node_id], true)
			send_registry_snapshot(data)
		}

	case:
		log.warnf("Unexpected control message type %d", ctrl_data[0])
	}
}

@(private)
ring_append_ctrl :: proc(ring: ^Connection_Ring, ctrl_body: []byte) -> bool {
	if ring == nil do return false
	total := u32(4 + NETWORK_HEADER_SIZE + len(ctrl_body))
	if total > ring.usable_slot_size do return false
	dst, sid, ok := batch_reserve(ring, total)
	if !ok do return false
	_ = frame_control_message(ctrl_body, dst)
	batch_commit(ring, sid)
	return true
}

@(private)
ring_append_ctrl_retry :: proc(ring: ^Connection_Ring, ctrl_body: []byte) -> bool {
	for retry in 0 ..< RING_SEND_SPIN_RETRIES + RING_SEND_YIELD_RETRIES {
		if ring_append_ctrl(ring, ctrl_body) do return true
		ring_full_backoff(retry)
	}
	return false
}

send_heartbeat :: proc(data: ^Connection_Actor_Data) {
	body: [17]byte
	w := Ctrl_Writer {
		buf = body[:],
	}
	ctrl_put_u8(&w, CTRL_MSG_HEARTBEAT)
	ctrl_put_u64(&w, u64(time.to_unix_nanoseconds(now())))
	ctrl_put_u64(&w, 0)
	if !ring_append_ctrl_retry(data.ring, body[:]) {
		log.warnf("Heartbeat to node %d dropped, ring full", data.node_id)
	}
}

check_heartbeat_timeout :: proc(data: ^Connection_Actor_Data) {
	if data.heartbeat_timeout > 0 {
		time_since := wall_since(data.last_heartbeat)
		if time_since > data.heartbeat_timeout {
			log.warnf("Connection to node %d timed out", data.node_id)
			close_connection(data)
		}
	}
}

@(private)
send_udp_info :: proc(data: ^Connection_Actor_Data) {
	if NODE.config.network.udp_port <= 0 do return

	data.my_udp_token = generate_udp_token()

	include_seed := data.encrypted && !data.is_incoming
	if include_seed && !data.udp_seed_set {
		data.udp_seed = generate_udp_seed()
		data.udp_seed_set = true
	}

	seed_len := include_seed ? UDP_SEED_SIZE : 0
	body: [1 + 2 + 4 + 1 + UDP_SEED_SIZE]byte
	w := Ctrl_Writer {
		buf = body[:],
	}
	ctrl_put_u8(&w, CTRL_MSG_UDP_INFO)
	ctrl_put_u16(&w, u16(NODE.config.network.udp_port))
	ctrl_put_u32(&w, data.my_udp_token)
	ctrl_put_u8(&w, u8(seed_len))
	if include_seed do ctrl_put_bytes(&w, data.udp_seed[:])

	if !ring_append_ctrl_retry(data.ring, body[:w.pos]) do log.warn("Failed to send UDP lane info")
}

@(private)
handle_udp_info :: proc(data: ^Connection_Actor_Data, ctrl_data: []byte) {
	r := Ctrl_Reader {
		data = ctrl_data,
		pos  = 1,
		ok   = true,
	}
	port := ctrl_get_u16(&r)
	token := ctrl_get_u32(&r)
	seed_len := int(ctrl_get_u8(&r))
	if !r.ok {
		log.warn("Malformed UDP info message")
		return
	}
	if seed_len > 0 {
		if seed_len != UDP_SEED_SIZE {
			log.warnf("Unexpected UDP seed length %d", seed_len)
			return
		}
		seed_bytes := ctrl_get_bytes(&r, seed_len)
		if !r.ok do return
		copy(data.udp_seed[:], seed_bytes)
		data.udp_seed_set = true
	}

	data.peer_udp_port = port
	data.peer_udp_token = token
	try_activate_udp(data)
}

@(private)
try_activate_udp :: proc(data: ^Connection_Actor_Data) {
	if data.udp_activated || data.state != .Connected do return
	if !udp_local_enabled() do return
	if data.peer_udp_port == 0 || data.peer_udp_token == 0 || data.my_udp_token == 0 do return
	if data.encrypted && !data.udp_seed_set do return

	keys: Udp_Keys
	if data.encrypted do keys = derive_udp_keys(data.udp_seed[:], !data.is_incoming)

	endpoint := net.Endpoint {
		address = data.address.address,
		port    = int(data.peer_udp_port),
	}
	udp_register_peer(
		data.node_id,
		endpoint,
		data.peer_udp_token,
		data.my_udp_token,
		keys,
		data.encrypted,
	)
	data.udp_activated = true
	log.infof("UDP lane active for node %s (id=%d)", data.node_name, data.node_id)
}

broadcast_disconnect_terminations :: proc(disconnected_node_id: Node_ID) {
	if disconnected_node_id == 0 || disconnected_node_id == NODE.node_id do return

	source_name, name_ok := get_node_name(disconnected_node_id)
	if !name_ok do return
	source_info, _ := get_node_info(disconnected_node_id)

	num_items := sync.atomic_load_explicit(&NODE.actor_registry.num_items, .Acquire)

	for i in 1 ..< num_items {
		entry := &NODE.actor_registry.items[i]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 do continue

		pid := sync.atomic_load_explicit(&entry.pid, .Acquire)
		if get_node_id(pid) != disconnected_node_id do continue

		actor_name := entry.remote_name
		if at_idx := strings.index_byte(actor_name, '@'); at_idx >= 0 {
			actor_name = actor_name[:at_idx]
		}

		handle, _ := unpack_pid(pid)
		original_pid := pack_pid(handle, NODE.node_id)

		msg := Actor_Terminated_Broadcast {
			pid                      = original_pid,
			name                     = actor_name,
			reason                   = .SHUTDOWN,
			source_incarnation       = source_info.incarnation,
			ttl                      = DEFAULT_BROADCAST_TTL,
			inferred_from_disconnect = true,
			source_node_name         = source_name,
		}

		broadcast_to_others(msg, disconnected_node_id, only_stream_peers = true)
	}
}

Wire_String_Field :: struct {
	binding: ^string,
	label:   string,
}

@(private)
decode_wire_payload :: proc(
	msg: ^$T,
	payload: []byte,
	label: string,
	fields: []Wire_String_Field,
) -> bool {
	if len(payload) < size_of(T) {
		log.warnf("%s payload too short", label)
		return false
	}
	intrinsics.mem_copy_non_overlapping(msg, raw_data(payload), size_of(T))

	str_offset := size_of(T)
	for field in fields {
		str_len := len(field.binding^)
		if str_len < 0 || str_len > len(payload) - str_offset {
			log.warnf("%s payload truncated at %s", label, field.label)
			return false
		}
		if str_len > 0 {
			field.binding^ = string(payload[str_offset:str_offset + str_len])
			str_offset += str_len
		}
	}
	return true
}

handle_lifecycle_event_inline :: proc(from_node: Node_ID, type_hash: u64, payload: []byte) -> bool {
	spawned_info := get_validated_message_info_ptr(Actor_Spawned_Broadcast)
	terminated_info := get_validated_message_info_ptr(Actor_Terminated_Broadcast)

	if type_hash == spawned_info.type_hash {
		msg: Actor_Spawned_Broadcast
		fields := [?]Wire_String_Field {
			{&msg.name, "name"},
			{&msg.source_node_name, "source_node_name"},
		}
		if decode_wire_payload(&msg, payload, "Spawn broadcast", fields[:]) {
			handle_spawn_broadcast(msg, from_node)
		}
		return true
	}

	if type_hash == terminated_info.type_hash {
		msg: Actor_Terminated_Broadcast
		fields := [?]Wire_String_Field {
			{&msg.name, "name"},
			{&msg.source_node_name, "source_node_name"},
		}
		if decode_wire_payload(&msg, payload, "Terminate broadcast", fields[:]) {
			handle_terminate_broadcast(msg, from_node)
		}
		return true
	}

	if type_hash == get_validated_message_info_ptr(Subscribe_Remote).type_hash {
		if len(payload) >= size_of(Subscribe_Remote) {
			msg: Subscribe_Remote
			intrinsics.mem_copy_non_overlapping(&msg, raw_data(payload), size_of(Subscribe_Remote))
			handle_remote_subscribe(msg, from_node)
		}
		return true
	}

	if type_hash == get_validated_message_info_ptr(Unsubscribe_Remote).type_hash {
		if len(payload) >= size_of(Unsubscribe_Remote) {
			msg: Unsubscribe_Remote
			intrinsics.mem_copy_non_overlapping(
				&msg,
				raw_data(payload),
				size_of(Unsubscribe_Remote),
			)
			handle_remote_unsubscribe(msg, from_node)
		}
		return true
	}

	return false
}

handle_lifecycle_event :: proc(from_node: Node_ID, type_hash: u64, payload: []byte) {
	if handle_lifecycle_event_inline(from_node, type_hash, payload) do return

	if type_hash == get_validated_message_info_ptr(Remote_Spawn_Request).type_hash {
		handle_remote_spawn_request(from_node, payload)
	} else if type_hash == get_validated_message_info_ptr(Remote_Spawn_Response).type_hash {
		handle_remote_spawn_response(payload)
	} else {
		log.warnf("Unknown lifecycle event type hash: %x", type_hash)
	}
}

@(private)
handle_remote_spawn_request :: proc(from_node: Node_ID, payload: []byte) {
	msg: Remote_Spawn_Request
	fields := [?]Wire_String_Field{{&msg.actor_name, "actor_name"}}
	if !decode_wire_payload(&msg, payload, "Remote spawn request", fields[:]) do return

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

	parent_pid := msg.parent_pid
	if parent_pid != 0 {
		parent_handle, _ := unpack_pid(parent_pid)
		parent_pid = pack_pid(parent_handle, from_node)
	}

	pid, ok := spawn_func(msg.actor_name, parent_pid)

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
	msg: Remote_Spawn_Response
	fields := [?]Wire_String_Field{{&msg.error_msg, "error_msg"}}
	if !decode_wire_payload(&msg, payload, "Remote spawn response", fields[:]) do return

	resolve_spawn_request(msg)
}

@(private)
send_spawn_response :: proc(to_node: Node_ID, response: Remote_Spawn_Response) {
	ring := get_connection_ring(to_node)
	if ring != nil {
		send_lifecycle_message(ring, response)
	} else {
		log.warnf("Cannot send spawn response to node %d - not connected", to_node)
	}
}

@(private)
request_lifecycle_stream :: proc(data: ^Connection_Actor_Data) {
	info, ok := get_node_info(data.node_id)
	if !ok || info.origin != .Registered do return
	body := [1]u8{CTRL_MSG_LIFECYCLE_STREAM}
	if !ring_append_ctrl_retry(data.ring, body[:]) {
		log.warnf("Failed to request the lifecycle stream from node %d", data.node_id)
	}
}

send_registry_snapshot :: proc(data: ^Connection_Actor_Data) {
	from_handle, _ := unpack_pid(get_self_pid())
	num_items := sync.atomic_load_explicit(&NODE.actor_registry.num_items, .Acquire)
	sent: int

	local_info := NODE.node_registry[NODE.node_id]

	for i in 1 ..< num_items {
		entry := &NODE.actor_registry.items[i]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		if (seq & 1) == 0 do continue

		pid := sync.atomic_load_explicit(&entry.pid, .Acquire)

		if pid == NODE.pid || pid == NODE.observer_pid do continue

		actor_name := get_actor_name(pid)
		origin_name := NODE.name
		origin_port := u16(local_info.address.port)
		origin_ip := ipv4_to_u32(local_info.address.address)
		origin_incarnation := NODE.incarnation
		ttl: u8 = DEFAULT_BROADCAST_TTL

		if !is_local_pid(pid) {
			origin_id := get_node_id(pid)
			if origin_id == data.node_id do continue
			origin_info, origin_ok := get_node_info(origin_id)
			if !origin_ok || origin_info.node_name == "" do continue
			origin_name = origin_info.node_name
			origin_port = u16(origin_info.address.port)
			origin_ip = ipv4_to_u32(origin_info.address.address)
			origin_incarnation = origin_info.incarnation
			ttl = DEFAULT_BROADCAST_TTL - 1
			if at := strings.index_byte(actor_name, '@'); at >= 0 do actor_name = actor_name[:at]
		}

		msg := Actor_Spawned_Broadcast {
			pid                = pid,
			name               = actor_name,
			actor_type         = get_pid_actor_type(pid),
			parent_pid         = get_actor_parent(pid),
			source_incarnation = origin_incarnation,
			ttl                = ttl,
			source_node_name   = origin_name,
			source_port        = origin_port,
			source_ip          = origin_ip,
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
			log.warnf(
				"Registry snapshot entry for '%s' does not fit the %d byte wire buffer, the peer will not learn this actor",
				msg.name,
				len(buf),
			)
			continue
		}

		if batch_append_message_retry(data.ring, buf[:msg_len]) {
			sent += 1
		} else {
			log.warnf(
				"Registry snapshot entry for node %s dropped, ring full",
				data.node_name,
			)
		}
	}

	log.infof("Sent registry snapshot with %d actors to node %s", sent, data.node_name)
}

send_node_directory :: proc(data: ^Connection_Actor_Data) {
	entry_count: u16 = 0
	total_size := 1 + 2
	for i in 2 ..< MAX_NODES {
		info := NODE.node_registry[i]
		if info.node_name == "" do continue
		if info.node_name == NODE.name || info.node_name == data.node_name do continue
		entry_count += 1
		total_size += 2 + len(info.node_name) + 4 + 2
	}

	if entry_count == 0 do return

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

	if ring_append_ctrl_retry(data.ring, ctrl_data) {
		log.infof("Sent node directory with %d entries to node %s", entry_count, data.node_name)
	} else {
		log.warnf("Failed to send node directory to node %s", data.node_name)
	}
}

announce_node_to_peers :: proc(name: string, address: net.Endpoint, subject: Node_ID) {
	if address.port == 0 || len(name) > 255 do return
	ctrl_buf: [3 + 2 + 256 + 4 + 2]byte
	w := Ctrl_Writer {
		buf = ctrl_buf[:],
	}
	ctrl_put_u8(&w, CTRL_MSG_NODE_DIRECTORY)
	ctrl_put_u16(&w, 1)
	ctrl_put_str(&w, name)
	ctrl_put_u32(&w, ipv4_to_u32(address.address))
	ctrl_put_u16(&w, u16(address.port))

	registered_limit := int(sync.atomic_load(&NODE.next_node_id))
	for node_id in 2 ..< registered_limit {
		if Node_ID(node_id) == subject do continue
		ring := get_connection_ring(Node_ID(node_id))
		if ring == nil || sync.atomic_load(&ring.state) != .Ready do continue
		_ = ring_append_ctrl(ring, ctrl_buf[:w.pos])
	}
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
		_, ok := register_discovered_node(node_name, endpoint, .TCP_Custom_Protocol)
		if ok do registered += 1
	}

	if registered > 0 do log.infof("Registered %d nodes from node directory", registered)
}

@(private)
relayed_gossip_incarnation_stale :: proc(
	source_node_id, from_node: Node_ID,
	msg_incarnation: u64,
) -> bool {
	if from_node == source_node_id {
		if msg_incarnation != 0 {
			if info, known := get_node_info(source_node_id);
			   known && info.incarnation != msg_incarnation {
				set_node_incarnation(source_node_id, msg_incarnation)
			}
		}
		return false
	}
	info, known := get_node_info(source_node_id)
	return known && info.incarnation != 0 && msg_incarnation != 0 &&
	       msg_incarnation != info.incarnation
}

@(private)
hearsay_death_about_connected_node :: proc(
	msg: Actor_Terminated_Broadcast,
	source_node_id, from_node: Node_ID,
) -> bool {
	if !msg.inferred_from_disconnect || source_node_id == from_node do return false
	ring := get_connection_ring(source_node_id)
	return ring != nil && sync.atomic_load(&ring.state) == .Ready
}

@(private)
qualified_remote_name :: proc(buf: []byte, actor_name: string, source_name: string) -> (string, bool) {
	total := len(actor_name) + 1 + len(source_name)
	if total > len(buf) do return "", false
	copy(buf, actor_name)
	buf[len(actor_name)] = '@'
	copy(buf[len(actor_name) + 1:], source_name)
	return string(buf[:total]), true
}

@(private)
mirror_source_registered :: proc(source_node_id: Node_ID) -> bool {
	info, ok := get_node_info(source_node_id)
	return ok && info.origin == .Registered
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

	if source_name == NODE.name do return

	source_node_id, found := get_node_by_name(source_name)
	if !found {
		endpoint := build_endpoint_from_broadcast(msg)
		source_node_id, _ = register_discovered_node(source_name, endpoint, .TCP_Custom_Protocol)
		if source_node_id == 0 {
			log.warnf("Failed to register source node %s from spawn broadcast", source_name)
			return
		}
	}

	if !mirror_source_registered(source_node_id) do return

	if relayed_gossip_incarnation_stale(source_node_id, from_node, msg.source_incarnation) do return
	if from_node != source_node_id && gossip_seq_covered(source_node_id, msg.source_seq) do return

	handle, _ := unpack_pid(msg.pid)
	remapped_pid := pack_pid(handle, source_node_id)

	name_buf: [1024]byte
	qualified_name, name_fits := qualified_remote_name(name_buf[:], msg.name, source_name)
	if !name_fits {
		log.warnf(
			"Spawn broadcast for '%s' dropped, qualified name needs %d bytes",
			msg.name,
			len(msg.name) + 1 + len(source_name),
		)
		return
	}
	_, is_new := add_remote(&NODE.actor_registry, remapped_pid, qualified_name)
	gossip_seq_record(source_node_id, msg.source_seq)

	if is_new && msg.ttl > 0 {
		forward_msg := msg
		forward_msg.ttl -= 1
		relay_broadcast(forward_msg, from_node, source_node_id)
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

	if source_name == NODE.name do return

	source_node_id, found := get_node_by_name(source_name)
	if !found do return

	if !mirror_source_registered(source_node_id) do return

	if relayed_gossip_incarnation_stale(source_node_id, from_node, msg.source_incarnation) do return
	if from_node != source_node_id && gossip_seq_covered(source_node_id, msg.source_seq) do return
	if hearsay_death_about_connected_node(msg, source_node_id, from_node) do return

	handle, _ := unpack_pid(msg.pid)
	remapped_pid := pack_pid(handle, source_node_id)

	name_buf: [1024]byte
	qualified_name, _ := qualified_remote_name(name_buf[:], msg.name, source_name)
	removed := remove_remote(&NODE.actor_registry, remapped_pid, qualified_name)
	gossip_seq_record(source_node_id, msg.source_seq)

	if removed && msg.ttl > 0 {
		forward_msg := msg
		forward_msg.ttl -= 1
		relay_broadcast(forward_msg, from_node, source_node_id)
	}
}

send_disconnect_to_ring :: proc(ring: ^Connection_Ring, reason: string) {
	ctrl_buf: [256]byte
	w := Ctrl_Writer {
		buf = ctrl_buf[:],
	}
	ctrl_put_u8(&w, CTRL_MSG_DISCONNECT)
	ctrl_put_u16(&w, u16(NODE.node_id))
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
		if ring != nil && sync.atomic_load(&ring.state) == .Ready {
			send_disconnect_to_ring(ring, reason)
		}
	}
}
