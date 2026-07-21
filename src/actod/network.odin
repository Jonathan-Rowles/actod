package actod

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

RING_SEND_SPIN_RETRIES :: 64
RING_SEND_YIELD_RETRIES :: 256

generate_nonce :: proc() -> u64 {
	nonce: u64
	platform_gen_random(&nonce, size_of(u64))
	return nonce
}

generate_nonzero_nonce :: proc() -> u64 {
	nonce := generate_nonce()
	for nonce == 0 {
		nonce = generate_nonce()
	}
	return nonce
}

set_tcp_nodelay :: proc(sock: net.TCP_Socket, enabled: bool = true) -> bool {
	val: i32 = enabled ? 1 : 0
	result := platform_setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &val, size_of(i32))
	return result == 0
}

set_socket_buffers :: proc(
	sock: net.TCP_Socket,
	recv_size: int = 4 * 1024 * 1024,
	send_size: int = 4 * 1024 * 1024,
) -> bool {
	recv_val: i32 = i32(recv_size)
	send_val: i32 = i32(send_size)
	r1 := platform_setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &recv_val, size_of(i32))
	r2 := platform_setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &send_val, size_of(i32))
	return r1 == 0 && r2 == 0
}

set_recv_timeout :: proc(sock: net.TCP_Socket, seconds: i64) -> bool {
	return platform_set_recv_timeout(sock, seconds)
}

Remote_Message :: struct {
	from: PID,
	data: []byte,
}

Transport_Strategy :: enum {
	Same_Process,
	TCP_Custom_Protocol,
}

Node_Info :: struct {
	node_name: string,
	address:   net.Endpoint,
	transport: Transport_Strategy,
}

@(private)
get_auth_password :: proc() -> string {
	if SYSTEM_CONFIG.network.auth_password != "" {
		return SYSTEM_CONFIG.network.auth_password
	}
	if env_pass := os.get_env("ACTOD_AUTH_PASSWORD", context.temp_allocator); env_pass != "" {
		return env_pass
	}
	return ""
}

init_network :: proc(local_node_id: Node_ID, node_name: string, loc := #caller_location) {
	sync.rw_mutex_lock(&NODE.node_registry_lock)
	local_addr: net.Endpoint
	if SYSTEM_CONFIG.network.port > 0 {
		local_addr = net.Endpoint {
			address = net.IP4_Loopback,
			port    = SYSTEM_CONFIG.network.port,
		}
	}
	cloned_name := strings.clone(NODE.name, get_system_allocator())
	NODE.node_registry[local_node_id] = Node_Info {
		node_name = cloned_name,
		address   = local_addr,
		transport = .Same_Process,
	}
	NODE.node_name_to_id[cloned_name] = local_node_id
	sync.rw_mutex_unlock(&NODE.node_registry_lock)


	if SYSTEM_CONFIG.network.port == 0 {
		return
	}

	if !nbio_available() {
		return
	}

	if NODE.network_listener_thread != nil {
		log.warnf(
			"Network listener is already running on port %d; node_init was called twice without a matching shutdown",
			SYSTEM_CONFIG.network.port,
			location = loc,
		)
		return
	}

	Listener_Context :: struct {
		port:   int,
		logger: runtime.Logger,
		loc:    runtime.Source_Code_Location,
	}


	listener_proc :: proc(t: ^thread.Thread) {
		listener_ctx := cast(^Listener_Context)t.user_args[0]
		context.logger = listener_ctx.logger
		defer free(listener_ctx)

		endpoint := net.Endpoint {
			address = net.IP4_Any,
			port    = listener_ctx.port,
		}

		listen_sock, err := net.listen_tcp(endpoint)
		if err != nil {
			log.errorf(
				"Failed to listen on port %d: %v; another process may already hold it, change port in make_network_config",
				listener_ctx.port,
				err,
				location = listener_ctx.loc,
			)
			return
		}
		defer net.close(listen_sock)

		NODE.network_listener_socket = listen_sock

		log.infof("Node discoverable on port %d", listener_ctx.port)
		sync.atomic_store(&NODE.network_listener_running, 1)

		net.set_blocking(listen_sock, false)

		pfd := Poll_Fd {
			fd     = platform_socket_fd(listen_sock),
			events = i16(POLLIN),
		}

		for sync.atomic_load(&NODE.network_listener_running) != 0 {
			pfd.revents = 0
			rc := platform_poll(&pfd, 1, 100) // 100ms timeout, then re-check stop flag
			if rc == 0 do continue // timeout
			if rc < 0 do break // error

			client_sock, client_addr, accept_err := net.accept_tcp(listen_sock)
			if accept_err != nil {
				if accept_err == .Would_Block do continue
				break
			}

			if sync.atomic_load(&NODE.network_listener_running) == 0 {
				net.close(client_sock)
				break
			}

			if !accept_incoming_connection(client_sock, client_addr) {
				net.close(client_sock)
			}
		}

		sync.atomic_store(&NODE.network_listener_running, 0)
	}

	ctx := new(Listener_Context)
	ctx.port = SYSTEM_CONFIG.network.port
	ctx.logger = context.logger
	ctx.loc = SYSTEM_CONFIG.loc

	NODE.network_listener_thread = thread.create(listener_proc)
	if NODE.network_listener_thread != nil {
		NODE.network_listener_thread.user_args[0] = ctx
		thread.start(NODE.network_listener_thread)
	} else {
		free(ctx)
		log.errorf(
			"Failed to create the network listener thread for port %d; this node will not accept incoming connections",
			SYSTEM_CONFIG.network.port,
			location = loc,
		)
	}
}

MAX_PENDING_INCOMING_HANDSHAKES :: 32

g_pending_incoming_handshakes: i32

accept_incoming_connection :: proc(sock: net.TCP_Socket, addr: net.Endpoint) -> bool {
	pending := sync.atomic_add(&g_pending_incoming_handshakes, 1)
	if pending >= MAX_PENDING_INCOMING_HANDSHAKES {
		sync.atomic_sub(&g_pending_incoming_handshakes, 1)
		log.warnf("Rejecting connection from %v: too many pending handshakes", addr)
		return false
	}

	conn_data := Connection_Actor_Data {
		node_id                 = 0,
		state                   = .Disconnected,
		address                 = addr,
		tcp_socket              = sock,
		heartbeat_interval      = SYSTEM_CONFIG.network.heartbeat_interval,
		heartbeat_timeout       = SYSTEM_CONFIG.network.heartbeat_timeout,
		reconnect_initial_delay = SYSTEM_CONFIG.network.reconnect_initial_delay,
		reconnect_retry_delay   = SYSTEM_CONFIG.network.reconnect_retry_delay,
		auth_password           = get_auth_password(),
		is_incoming             = true,
		ring_config             = SYSTEM_CONFIG.network.connection_ring,
	}

	actor_name := fmt.tprintf("incoming_%v_%d", addr, time.to_unix_nanoseconds(time.now()))

	conn_config := make_actor_config(restart_policy = .TRANSIENT, use_dedicated_os_thread = true)

	conn_pid, ok := spawn(
		actor_name,
		conn_data,
		Connection_Actor_Behaviour,
		conn_config,
		parent_pid = NODE.pid,
	)
	if !ok {
		sync.atomic_sub(&g_pending_incoming_handshakes, 1)
		return false
	}

	send_message(conn_pid, Start_Receiving{})

	return true
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

tcp_recv_framed_message :: proc(sock: net.TCP_Socket, deadline: time.Time) -> []byte {
	size_buf: [4]byte
	if !tcp_recv_exactly(sock, size_buf[:], deadline) {
		return nil
	}

	msg_size := endian.unchecked_get_u32le(size_buf[:])
	if msg_size == 0 || msg_size > MAX_MESSAGE_SIZE {
		return nil
	}

	msg := make([]byte, msg_size, actor_system_allocator)
	if !tcp_recv_exactly(sock, msg, deadline) {
		delete(msg, actor_system_allocator)
		return nil
	}
	return msg
}

// deadline bounds the whole read, not each recv: SO_RCVTIMEO alone lets a peer
// dribble one byte per timeout window forever, so a total wall-clock deadline
// is required to defeat slowloris-style handshake stalls.
tcp_recv_exactly :: proc(sock: net.TCP_Socket, buf: []byte, deadline: time.Time) -> bool {
	total := 0
	for total < len(buf) {
		n, err := net.recv_tcp(sock, buf[total:])
		if err != nil || n == 0 {
			return false
		}
		total += n
		if total < len(buf) && time.diff(deadline, time.now()) > 0 {
			return false
		}
	}
	return true
}


stop_network_listener :: proc() {
	if NODE.network_listener_thread != nil {
		sync.atomic_store(&NODE.network_listener_running, 0)

		if NODE.network_listener_socket != 0 {
			net.close(NODE.network_listener_socket)
			NODE.network_listener_socket = 0
		}

		thread.join(NODE.network_listener_thread)
		thread.destroy(NODE.network_listener_thread)
		NODE.network_listener_thread = nil
	}
}

deliver_to_target :: #force_inline proc(
	remote_node_id: Node_ID,
	flags: Network_Message_Flags,
	type_hash: u64,
	from_handle: Handle,
	to_handle: Handle,
	to_name: string,
	payload: []byte,
) -> bool {
	if .BROADCAST in flags {
		return deliver_broadcast_locally(
			remote_node_id,
			type_hash,
			from_handle,
			to_handle,
			payload,
			flags,
		)
	}

	to_pid: PID
	if .BY_NAME in flags {
		found: bool
		to_pid, found = get_actor_pid(to_name)
		if !found {
			log.warnf("Actor '%s' not found for direct delivery", to_name)
			return false
		}
	} else {
		to_pid = pack_pid(to_handle, current_node_id)
	}

	type_info, type_ok := get_type_info_by_hash(type_hash)
	if !type_ok {
		log.warnf("Unknown message type hash: %x", type_hash)
		return false
	}

	from_pid := pack_pid(from_handle, remote_node_id)
	result := send_from_payload(to_pid, from_pid, payload, type_info, flags_to_priority(flags))
	return result == .OK
}

deliver_broadcast_locally :: proc(
	remote_node_id: Node_ID,
	type_hash: u64,
	from_handle: Handle,
	to_handle: Handle,
	payload: []byte,
	flags: Network_Message_Flags,
) -> bool {
	actor_type_hash := transmute(u64)to_handle
	local_type, type_found := get_actor_type_by_hash(actor_type_hash)
	if !type_found {
		log.warnf("Unknown actor type hash in broadcast: %x", actor_type_hash)
		return false
	}

	type_info, info_ok := get_type_info_by_hash(type_hash)
	if !info_ok {
		log.warnf("Unknown message type hash in broadcast: %x", type_hash)
		return false
	}

	from_pid := pack_pid(from_handle, remote_node_id)
	priority := flags_to_priority(flags)
	list := &type_subscribers[local_type]

	for i in 0 ..< MAX_SUBSCRIBERS_PER_TYPE {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&list.subscribers[i], .Acquire))
		if pid != 0 {
			send_from_payload(pid, from_pid, payload, type_info, priority)
		}
	}

	return true
}

send_remote :: #force_inline proc(to: PID, content: $T, loc := #caller_location) -> Send_Error {
	v := content
	return send_remote_impl(to, &v, get_validated_message_info_ptr(T), .NORMAL, loc)
}

get_or_create_connection :: proc(node_id: Node_ID) -> PID {
	if node_id == 0 || node_id >= MAX_NODES {
		return 0
	}

	if !nbio_available() {
		return 0
	}

	node_info, info_ok := get_node_info(node_id)
	if !info_ok {
		return 0
	}

	existing_pid := PID(
		sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[node_id], .Acquire),
	)

	if existing_pid != 0 {
		actor_ptr, actor_exists := get(&global_registry, existing_pid)
		if actor_exists && actor_ptr != nil {
			send_message(
				existing_pid,
				Connect_Request{node_id = node_id, address = node_info.address},
			)
			return existing_pid
		}
		sync.atomic_store_explicit(cast(^u64)&NODE.connection_actors[node_id], u64(0), .Release)
	}

	if get_or_create_node_ring(node_id, SYSTEM_CONFIG.network.connection_ring) == nil {
		return 0
	}

	conn_data := Connection_Actor_Data {
		node_id                 = node_id,
		node_name               = node_info.node_name,
		state                   = .Disconnected,
		address                 = node_info.address,
		heartbeat_interval      = SYSTEM_CONFIG.network.heartbeat_interval,
		heartbeat_timeout       = SYSTEM_CONFIG.network.heartbeat_timeout,
		reconnect_initial_delay = SYSTEM_CONFIG.network.reconnect_initial_delay,
		reconnect_retry_delay   = SYSTEM_CONFIG.network.reconnect_retry_delay,
		auth_password           = get_auth_password(),
		ring_config             = SYSTEM_CONFIG.network.connection_ring,
	}

	conn_config := make_actor_config(
		restart_policy = .PERMANENT,
		max_restarts = 5,
		restart_window = 60 * time.Second,
		use_dedicated_os_thread = true,
	)

	conn_pid, spawn_ok := spawn(
		fmt.tprintf("%s_connection_pending", node_info.node_name),
		conn_data,
		Connection_Actor_Behaviour,
		conn_config,
		parent_pid = NODE.pid,
	)
	if !spawn_ok {
		log.errorf(
			"Failed to spawn the connection actor for node '%s'; the actor registry may be full",
			node_info.node_name,
		)
		return 0
	}

	_, cas_ok := sync.atomic_compare_exchange_strong_explicit(
		cast(^u64)&NODE.connection_actors[node_id],
		u64(0),
		u64(conn_pid),
		.Acq_Rel,
		.Acquire,
	)
	if !cas_ok {
		existing := PID(
			sync.atomic_load_explicit(cast(^u64)&NODE.connection_actors[node_id], .Acquire),
		)
		terminate_actor(conn_pid, .SHUTDOWN)
		return existing
	}

	send_message(conn_pid, Connect_Request{node_id = node_id, address = node_info.address})

	return conn_pid
}

ipv4_to_u32 :: proc(addr: net.Address) -> u32 {
	ip4: net.IP4_Address
	switch a in addr {
	case net.IP4_Address:
		ip4 = a
	case net.IP6_Address:
		return 0
	}
	return u32(ip4[0]) << 24 | u32(ip4[1]) << 16 | u32(ip4[2]) << 8 | u32(ip4[3])
}

u32_to_ipv4 :: proc(ip: u32) -> net.IP4_Address {
	return net.IP4_Address{u8(ip >> 24), u8(ip >> 16 & 0xFF), u8(ip >> 8 & 0xFF), u8(ip & 0xFF)}
}

build_endpoint_from_broadcast :: proc(msg: Actor_Spawned_Broadcast) -> net.Endpoint {
	if msg.source_port == 0 {
		return {}
	}
	return net.Endpoint{address = u32_to_ipv4(msg.source_ip), port = int(msg.source_port)}
}

DEFAULT_BROADCAST_TTL :: 3

broadcast_actor_spawned :: proc(pid: PID, name: string, actor_type: Actor_Type, parent_pid: PID) {
	if NODE.shutting_down {
		return
	}

	if pid == NODE.pid || pid == OBSERVER_PID {
		return
	}

	local_info := NODE.node_registry[current_node_id]

	msg := Actor_Spawned_Broadcast {
		pid              = pid,
		name             = name,
		actor_type       = actor_type,
		parent_pid       = parent_pid,
		ttl              = DEFAULT_BROADCAST_TTL,
		source_node_name = NODE.name,
		source_port      = u16(local_info.address.port),
		source_ip        = ipv4_to_u32(local_info.address.address),
	}

	broadcast_to_all_nodes(msg)
}

broadcast_actor_terminated :: proc(pid: PID, name: string, reason: Termination_Reason) {
	if NODE.shutting_down {
		return
	}

	if pid == NODE.pid || pid == OBSERVER_PID {
		return
	}

	msg := Actor_Terminated_Broadcast {
		pid              = pid,
		name             = name,
		reason           = reason,
		ttl              = DEFAULT_BROADCAST_TTL,
		source_node_name = NODE.name,
	}

	broadcast_to_all_nodes(msg)
}

// Gossip goes only to live connections; reconnecting peers re-sync via the
// registry snapshot exchanged on handshake.
broadcast_to_all_nodes :: proc(msg: $T) {
	for node_id in 2 ..< MAX_NODES {
		ring := get_connection_ring(Node_ID(node_id))
		if ring != nil && sync.atomic_load(&ring.state) == .Ready {
			send_lifecycle_message(ring, msg)
		}
	}
}

broadcast_to_others :: proc(msg: $T, except: Node_ID) {
	for node_id in 2 ..< MAX_NODES {
		if Node_ID(node_id) == except {
			continue
		}
		ring := get_connection_ring(Node_ID(node_id))
		if ring != nil && sync.atomic_load(&ring.state) == .Ready {
			send_lifecycle_message(ring, msg)
		}
	}
}

send_lifecycle_message :: proc(ring: ^Connection_Ring, msg: $T) {
	if ring == nil {
		return
	}

	from_handle, _ := unpack_pid(get_self_pid())

	buf: [((size_of(T) + WIRE_FORMAT_OVERHEAD + 63) / 64) * 64]byte

	msg_len := build_wire_format_into_buffer(
		buf[:],
		msg,
		Handle{},
		from_handle,
		{.LIFECYCLE_EVENT},
		"",
	)
	if msg_len == 0 {
		log.warn("Failed to build lifecycle message wire format")
		return
	}

	if !batch_append_message_retry(ring, buf[:msg_len]) {
		log.warnf("Failed to append lifecycle message to ring for node %d", ring.node_id)
	}
}

get_node_name :: proc(node_id: Node_ID) -> (string, bool) {
	info, ok := get_node_info(node_id)
	if !ok {
		return "", false
	}
	return info.node_name, true
}

send_remote_by_name :: #force_inline proc(
	node_name: string,
	actor_name: string,
	content: $T,
	loc := #caller_location,
) -> Send_Error {
	v := content
	return send_remote_by_name_impl(
		node_name,
		actor_name,
		&v,
		get_validated_message_info_ptr(T),
		loc,
	)
}

MAX_PENDING_SPAWNS :: 64
SPAWN_REMOTE_TIMEOUT :: 5 * time.Second

@(private)
Pending_Spawn :: struct {
	sema:     sync.Atomic_Sema,
	response: Remote_Spawn_Response,
	active:   bool,
}

@(private)
g_pending_spawns: [MAX_PENDING_SPAWNS]Pending_Spawn
@(private)
g_pending_spawn_ids: [MAX_PENDING_SPAWNS]u64
@(private)
g_spawn_request_counter: u64

spawn_remote :: proc(
	spawn_func_name: string,
	actor_name: string,
	target_node: string,
	parent_pid: PID = 0,
	timeout: time.Duration = SPAWN_REMOTE_TIMEOUT,
	loc := #caller_location,
) -> (
	PID,
	bool,
) {
	context.logger = diagnostic_logger(context.logger)
	_, registered := get_spawn_func_by_hash(fnv1a_hash(spawn_func_name))
	if !registered {
		log.errorf(
			"Spawn function '%s' is not registered locally, it likely won't exist on node '%s' either; register it with the same name on both nodes",
			spawn_func_name,
			target_node,
			location = loc,
		)
	}

	node_id, ok := get_node_by_name(target_node)
	if !ok {
		log.errorf(
			"Cannot spawn '%s' remotely: node '%s' is not known; check the spelling and register it with register_node first",
			actor_name,
			target_node,
			location = loc,
		)
		return 0, false
	}

	request_id := sync.atomic_add(&g_spawn_request_counter, 1) + 1
	slot_idx := -1
	for i in 0 ..< MAX_PENDING_SPAWNS {
		_, exchanged := sync.atomic_compare_exchange_strong_explicit(
			&g_pending_spawn_ids[i],
			0,
			request_id,
			.Acquire,
			.Relaxed,
		)
		if exchanged {
			slot_idx = i
			break
		}
	}
	if slot_idx == -1 {
		log.errorf(
			"Cannot spawn '%s' on node '%s': all %d remote spawn slots are in flight; wait for outstanding spawn_remote calls to finish",
			actor_name,
			target_node,
			MAX_PENDING_SPAWNS,
			location = loc,
		)
		return 0, false
	}

	pending := &g_pending_spawns[slot_idx]
	pending.active = true
	pending.response = {}

	request := Remote_Spawn_Request {
		request_id           = request_id,
		parent_pid           = parent_pid,
		spawn_func_name_hash = fnv1a_hash(spawn_func_name),
		actor_name           = actor_name,
	}

	ring := ensure_ring_for_node(node_id)
	if ring == nil {
		sync.atomic_store_explicit(&g_pending_spawn_ids[slot_idx], 0, .Release)
		log.errorf(
			"Cannot spawn '%s' on node '%s': no connection to that node could be established; check it is running and reachable",
			actor_name,
			target_node,
			location = loc,
		)
		return 0, false
	}
	send_lifecycle_message(ring, request)

	if !sync.atomic_sema_wait_with_timeout(&pending.sema, timeout) {
		log.errorf(
			"Remote spawn of '%s' via '%s' on node '%s' timed out after %v; the node may be unreachable or not draining its ring",
			actor_name,
			spawn_func_name,
			target_node,
			timeout,
			location = loc,
		)
		sync.atomic_store_explicit(&g_pending_spawn_ids[slot_idx], 0, .Release)
		return 0, false
	}

	response := pending.response
	sync.atomic_store_explicit(&g_pending_spawn_ids[slot_idx], 0, .Release)

	if !response.success {
		log.errorf(
			"Remote spawn of '%s' via '%s' failed on node '%s': %s",
			actor_name,
			spawn_func_name,
			target_node,
			response.error_msg,
			location = loc,
		)
		return 0, false
	}

	return response.pid, true
}

@(private)
resolve_spawn_request :: proc(response: Remote_Spawn_Response) {
	for i in 0 ..< MAX_PENDING_SPAWNS {
		if sync.atomic_load_explicit(&g_pending_spawn_ids[i], .Acquire) == response.request_id {
			g_pending_spawns[i].response = response
			sync.atomic_sema_post(&g_pending_spawns[i].sema)
			return
		}
	}
	log.warnf("Received Remote_Spawn_Response for unknown request_id %d", response.request_id)
}
