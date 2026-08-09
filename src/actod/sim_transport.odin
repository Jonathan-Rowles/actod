package actod

import "../pkgs/coro"
import "base:builtin"
import "core:log"
import "core:nbio"
import "core:net"
import "core:sync"
import "core:time"

SIM_SOCKET_BASE :: 1 << 30

Sim_Endpoint :: struct {
	sock:        net.TCP_Socket,
	peer:        ^Sim_Endpoint,
	node:        ^Node_State,
	inbound:     [dynamic]byte,
	read_pos:    int,
	closed:      bool,
	ring:        ^Connection_Ring,
	recv_buf:    []byte,
	recv_op:     nbio.Operation,
	recv_waiter: ^Pooled_Actor_Handle,
}

Sim_Pending_Accept :: struct {
	node: ^Node_State,
	sock: net.TCP_Socket,
	addr: net.Endpoint,
}

@(private = "file")
g_sim_initialized: bool
@(private = "file")
g_sim_endpoints: [dynamic]^Sim_Endpoint
@(private = "file")
g_sim_listeners: map[int]^Node_State
@(private = "file")
g_sim_pending_accepts: [dynamic]Sim_Pending_Accept
@(private = "file")
g_sim_next_socket := net.TCP_Socket(SIM_SOCKET_BASE)
@(private = "file")
g_sim_next_ephemeral_port := 40000
@(private = "file")
g_sim_recv_chunk: int
@(private = "file")
g_sim_servicing: bool
@(private = "file")
g_sim_blocked_links: [dynamic][2]^Node_State
@(private = "file")
g_sim_thread_id: int

sim_is_socket :: #force_inline proc(sock: net.TCP_Socket) -> bool {
	return int(sock) >= SIM_SOCKET_BASE
}

sim_set_recv_chunk :: proc(max_bytes_per_delivery: int) {
	g_sim_recv_chunk = max_bytes_per_delivery
}

@(private = "file")
sim_transport_ensure :: proc() {
	if g_sim_initialized {
		return
	}
	g_sim_initialized = true
	g_sim_thread_id = sync.current_thread_id()
	g_sim_endpoints = make([dynamic]^Sim_Endpoint, get_system_allocator())
	g_sim_pending_accepts = make([dynamic]Sim_Pending_Accept, get_system_allocator())
	g_sim_listeners = make(map[int]^Node_State, get_system_allocator())
	g_sim_blocked_links = make([dynamic][2]^Node_State, get_system_allocator())
}

sim_transport_reset_counters_if_idle :: proc() {
	if g_sim_initialized && (len(g_sim_endpoints) > 0 || len(g_sim_pending_accepts) > 0) {
		return
	}
	g_sim_next_socket = net.TCP_Socket(SIM_SOCKET_BASE)
	g_sim_next_ephemeral_port = 40000
}

sim_wake_transport_waiters :: proc() {
	if !g_sim_initialized {
		return
	}
	for ep in g_sim_endpoints {
		if ep.recv_waiter != nil {
			sim_wake_waiter(ep)
		}
	}
}

sim_transport_assert_quiescent :: proc() {
	if !g_sim_initialized {
		return
	}
	assert(
		len(g_sim_endpoints) == 0 &&
		len(g_sim_pending_accepts) == 0 &&
		len(g_sim_blocked_links) == 0,
		"sim transport leaked endpoints across mesh destroy; socket/port counters cannot reset and later same-process seed replays will silently diverge",
	)
}

sim_link_blocked :: proc(a, b: ^Node_State) -> bool {
	for pair in g_sim_blocked_links {
		if (pair[0] == a && pair[1] == b) || (pair[0] == b && pair[1] == a) {
			return true
		}
	}
	return false
}

sim_block_link :: proc(a, b: ^Node_State) {
	sim_transport_ensure()
	if sim_link_blocked(a, b) {
		return
	}
	append(&g_sim_blocked_links, [2]^Node_State{a, b})
}

sim_unblock_link :: proc(a, b: ^Node_State) {
	if !g_sim_initialized {
		return
	}
	for i in 0 ..< len(g_sim_blocked_links) {
		pair := g_sim_blocked_links[i]
		if (pair[0] == a && pair[1] == b) || (pair[0] == b && pair[1] == a) {
			ordered_remove(&g_sim_blocked_links, i)
			break
		}
	}
	for ep in g_sim_endpoints {
		if ep.closed || ep.peer == nil {
			continue
		}
		if (ep.node == a && ep.peer.node == b) || (ep.node == b && ep.peer.node == a) {
			sim_wake_waiter(ep)
		}
	}
}

sim_sever_link :: proc(a, b: ^Node_State, deliver_error: bool) {
	if !g_sim_initialized {
		return
	}
	for {
		target: ^Sim_Endpoint
		for ep in g_sim_endpoints {
			if ep.closed || ep.peer == nil || ep.peer.closed {
				continue
			}
			if (ep.node == a && ep.peer.node == b) || (ep.node == b && ep.peer.node == a) {
				target = ep
				break
			}
		}
		if target == nil {
			break
		}
		peer := target.peer
		builtin.clear(&target.inbound)
		target.read_pos = 0
		builtin.clear(&peer.inbound)
		peer.read_pos = 0
		sim_deliver_reset(target, deliver_error)
		sim_deliver_reset(peer, deliver_error)
		sim_close_socket(target.sock)
		sim_close_socket(peer.sock)
	}
}

@(private = "file")
sim_deliver_reset :: proc(ep: ^Sim_Endpoint, deliver_error: bool) {
	ring := ep.ring
	if ring == nil {
		return
	}
	previous := sim_bind_node(ep.node)
	if ring.pending_recv == &ep.recv_op {
		ep.recv_buf = nil
		ep.recv_op = {}
		ep.recv_op.type = .Recv
		if deliver_error {
			ep.recv_op.recv.err = net.TCP_Recv_Error.Connection_Closed
		}
		nbio_recv_callback(&ep.recv_op, ring)
	} else {
		notify_ring_error(ring, "connection reset by sever")
	}
	_ = sim_bind_node(previous)
}

sim_transport_drop_node :: proc(node: ^Node_State) {
	if !g_sim_initialized {
		return
	}
	for {
		removed_port := -1
		for port, owner in g_sim_listeners {
			if owner == node {
				removed_port = port
				break
			}
		}
		if removed_port < 0 {
			break
		}
		delete_key(&g_sim_listeners, removed_port)
	}
	accept_idx := 0
	for accept_idx < len(g_sim_pending_accepts) {
		if g_sim_pending_accepts[accept_idx].node == node {
			sock := g_sim_pending_accepts[accept_idx].sock
			ordered_remove(&g_sim_pending_accepts, accept_idx)
			sim_close_socket(sock)
			continue
		}
		accept_idx += 1
	}
	for {
		reopened := false
		for ep in g_sim_endpoints {
			if ep.node == node && !ep.closed {
				sim_close_socket(ep.sock)
				reopened = true
				break
			}
		}
		if !reopened {
			break
		}
	}
}

@(private = "file")
sim_endpoint_for :: proc(sock: net.TCP_Socket) -> ^Sim_Endpoint {
	if !g_sim_initialized {
		return nil
	}
	for ep in g_sim_endpoints {
		if ep.sock == sock {
			return ep
		}
	}
	return nil
}

@(private = "file")
sim_new_endpoint :: proc(node: ^Node_State) -> ^Sim_Endpoint {
	ep := new(Sim_Endpoint, get_system_allocator())
	ep.sock = g_sim_next_socket
	g_sim_next_socket += 1
	ep.node = node
	ep.inbound = make([dynamic]byte, 0, 4096, get_system_allocator())
	append(&g_sim_endpoints, ep)
	return ep
}

@(private = "file")
sim_free_endpoint :: proc(ep: ^Sim_Endpoint) {
	for i in 0 ..< len(g_sim_endpoints) {
		if g_sim_endpoints[i] == ep {
			ordered_remove(&g_sim_endpoints, i)
			break
		}
	}
	if ep.peer != nil {
		ep.peer.peer = nil
	}
	delete(ep.inbound)
	free(ep, get_system_allocator())
}

@(private = "file")
sim_inbound_len :: proc(ep: ^Sim_Endpoint) -> int {
	return len(ep.inbound) - ep.read_pos
}

@(private = "file")
sim_inbound_take :: proc(ep: ^Sim_Endpoint, dst: []byte) -> int {
	n := min(len(dst), sim_inbound_len(ep))
	if n > 0 {
		copy(dst[:n], ep.inbound[ep.read_pos:ep.read_pos + n])
		ep.read_pos += n
		if ep.read_pos == len(ep.inbound) {
			builtin.clear(&ep.inbound)
			ep.read_pos = 0
		}
	}
	return n
}

@(private = "file")
sim_wake_waiter :: proc(ep: ^Sim_Endpoint) {
	if ep.recv_waiter == nil {
		return
	}
	handle := ep.recv_waiter
	ep.recv_waiter = nil
	handle.transport_parked = false
	wake_pooled_actor(handle)
}

sim_listen :: proc(port: int) {
	sim_transport_ensure()
	if existing, taken := g_sim_listeners[port]; taken && existing != NODE {
		log.warnf("sim: virtual port %d already claimed by another node, replacing", port)
	}
	g_sim_listeners[port] = NODE
	log.infof("Sim node listening on virtual port %d", port)
}

sim_stop_listening :: proc(port: int) {
	if !g_sim_initialized {
		return
	}
	if g_sim_listeners[port] == NODE {
		delete_key(&g_sim_listeners, port)
	}
	accept_idx := 0
	for accept_idx < len(g_sim_pending_accepts) {
		if g_sim_pending_accepts[accept_idx].node == NODE {
			sock := g_sim_pending_accepts[accept_idx].sock
			ordered_remove(&g_sim_pending_accepts, accept_idx)
			sim_close_socket(sock)
			continue
		}
		accept_idx += 1
	}
}

runtime_dial_tcp :: proc(endpoint: net.Endpoint) -> (net.TCP_Socket, net.Network_Error) {
	if NODE.config.sim_mode {
		return sim_dial(endpoint)
	}
	return net.dial_tcp(endpoint)
}

@(private = "file")
sim_dial :: proc(endpoint: net.Endpoint) -> (net.TCP_Socket, net.Network_Error) {
	sim_transport_ensure()
	listener := g_sim_listeners[endpoint.port]
	if listener == nil {
		return 0, net.Dial_Error.Refused
	}
	if sim_link_blocked(NODE, listener) {
		return 0, net.Dial_Error.Timeout
	}
	client := sim_new_endpoint(NODE)
	server := sim_new_endpoint(listener)
	client.peer = server
	server.peer = client
	g_sim_next_ephemeral_port += 1
	append(
		&g_sim_pending_accepts,
		Sim_Pending_Accept {
			node = listener,
			sock = server.sock,
			addr = net.Endpoint{address = net.IP4_Loopback, port = g_sim_next_ephemeral_port},
		},
	)
	return client.sock, nil
}

close_tcp :: proc(sock: net.TCP_Socket) {
	if sim_is_socket(sock) {
		sim_close_socket(sock)
		return
	}
	net.close(sock)
}

@(private = "file")
sim_close_socket :: proc(sock: net.TCP_Socket) {
	ep := sim_endpoint_for(sock)
	if ep == nil || ep.closed {
		return
	}
	ep.closed = true
	if ep.ring != nil && ep.ring.pending_recv == &ep.recv_op {
		ep.ring.pending_recv = nil
	}
	ep.ring = nil
	ep.recv_buf = nil
	sim_wake_waiter(ep)
	peer := ep.peer
	if peer != nil && !peer.closed {
		sim_wake_waiter(peer)
		return
	}
	if peer != nil {
		sim_free_endpoint(peer)
	}
	sim_free_endpoint(ep)
}

sim_stream_write :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	ep := sim_endpoint_for(sock)
	if ep == nil || ep.closed || ep.peer == nil || ep.peer.closed {
		return false
	}
	append(&ep.peer.inbound, ..data)
	sim_wake_waiter(ep.peer)
	return true
}

sim_stream_read_exactly :: proc(sock: net.TCP_Socket, buf: []byte, deadline: time.Time) -> bool {
	total := 0
	for total < len(buf) {
		ep := sim_endpoint_for(sock)
		if ep == nil || ep.closed {
			return false
		}
		blocked := ep.peer != nil && sim_link_blocked(ep.node, ep.peer.node)
		if !blocked {
			total += sim_inbound_take(ep, buf[total:])
			if total == len(buf) {
				return true
			}
			if ep.peer == nil || ep.peer.closed {
				return false
			}
		}
		if time.diff(deadline, now()) > 0 {
			return false
		}
		co := coro.running()
		if co != nil {
			handle := cast(^Pooled_Actor_Handle)coro.get_user_data(co)
			handle.transport_parked = true
			ep.recv_waiter = handle
			coro.yield(co)
			handle.transport_parked = false
			if live := sim_endpoint_for(sock); live != nil && live.recv_waiter == handle {
				live.recv_waiter = nil
			}
		} else if !sim_pump() {
			return false
		}
	}
	return true
}

sim_start_connection_io :: proc(data: ^Connection_Actor_Data) -> bool {
	ring := data.ring
	ep := sim_endpoint_for(ring.tcp_socket)
	if ep == nil {
		log.error("sim: no virtual endpoint for connection ring socket")
		return false
	}
	if !ring_io_attach(ring, get_self_pid()) {
		return false
	}
	sync.atomic_store(&ring.io_stop, 0)
	ep.ring = ring
	ring.pending_recv = nil
	ring.send_in_flight = false
	ring.recv_write_pos = 0
	return true
}

sim_attach_pool_ring :: proc(ring: ^Connection_Ring, owner: PID) -> bool {
	ep := sim_endpoint_for(ring.tcp_socket)
	if ep == nil {
		return false
	}
	sync.atomic_store_explicit(&ring.io_owner, u64(owner), .Release)
	sync.atomic_store(&ring.io_stop, 0)
	ep.ring = ring
	ring.pending_recv = nil
	ring.send_in_flight = false
	ring.recv_write_pos = 0
	return true
}

@(private = "file")
sim_detach_ring :: proc(ring: ^Connection_Ring) {
	if g_sim_initialized {
		for ep in g_sim_endpoints {
			if ep.ring == ring {
				ep.ring = nil
				ep.recv_buf = nil
			}
		}
	}
	ring.pending_recv = nil
	sync.atomic_store_explicit(&ring.state, Connection_Ring_State.Buffering, .Release)
	ring_io_release(ring)
}

sim_stop_connection_io :: proc(ring: ^Connection_Ring) {
	sim_detach_ring(ring)
	pool := ring.pool
	if pool == nil {
		return
	}
	count := sync.atomic_load_explicit(&pool.ring_count, .Acquire)
	for i in 1 ..< count {
		pool_ring := atomic_load_ring_ptr(&pool.rings[i])
		if pool_ring != nil && pool_ring != ring {
			sim_detach_ring(pool_ring)
		}
	}
}

sim_ring_send :: proc(ring: ^Connection_Ring, batch_count: u32) {
	ep := sim_endpoint_for(ring.tcp_socket)
	op: nbio.Operation
	op.type = .Send
	if ep == nil || ep.closed || ep.peer == nil || ep.peer.closed {
		op.send.err = net.TCP_Send_Error.Connection_Closed
	} else {
		for buf in ring.send_bufs[:batch_count] {
			append(&ep.peer.inbound, ..buf)
		}
		sim_wake_waiter(ep.peer)
	}
	ring.send_in_flight = true
	nbio_send_callback(&op, ring, batch_count)
}

sim_ring_post_recv :: proc(ring: ^Connection_Ring, recv_buf: []byte) -> ^nbio.Operation {
	ep := sim_endpoint_for(ring.tcp_socket)
	if ep == nil {
		return nil
	}
	ep.recv_buf = recv_buf
	return &ep.recv_op
}

@(private = "file")
sim_deliver_recv :: proc(ep: ^Sim_Endpoint) -> bool {
	ring := ep.ring
	if ring == nil || ring.pending_recv != &ep.recv_op || ep.recv_buf == nil {
		return false
	}
	if ep.peer != nil && sim_link_blocked(ep.node, ep.peer.node) {
		return false
	}
	received := 0
	available := sim_inbound_len(ep)
	if available > 0 {
		limit := len(ep.recv_buf)
		if g_sim_recv_chunk > 0 && g_sim_recv_chunk < limit {
			limit = g_sim_recv_chunk
		}
		received = sim_inbound_take(ep, ep.recv_buf[:limit])
	} else if ep.peer != nil && !ep.peer.closed {
		return false
	}
	ep.recv_buf = nil
	ep.recv_op = {}
	ep.recv_op.type = .Recv
	ep.recv_op.recv.received = received
	sim_trace_record(.Wire_Deliver, u64(ep.sock) - SIM_SOCKET_BASE, u64(received))
	nbio_recv_callback(&ep.recv_op, ring)
	return true
}

sim_service_transport :: proc() -> bool {
	if !g_sim_initialized || g_sim_servicing {
		return false
	}
	assert(
		sync.current_thread_id() == g_sim_thread_id,
		"sim transport touched from a second thread; the sim is single-threaded by design",
	)
	g_sim_servicing = true
	defer g_sim_servicing = false

	progress := false

	accept_idx := 0
	for accept_idx < len(g_sim_pending_accepts) {
		pending := g_sim_pending_accepts[accept_idx]
		if pending.node != NODE {
			accept_idx += 1
			continue
		}
		ordered_remove(&g_sim_pending_accepts, accept_idx)
		if !accept_incoming_connection(pending.sock, pending.addr) {
			sim_close_socket(pending.sock)
		}
		progress = true
	}

	for i := 0; i < len(g_sim_endpoints); i += 1 {
		ep := g_sim_endpoints[i]
		if ep.node != NODE || ep.ring == nil || ep.closed {
			continue
		}
		ring := ep.ring
		if sync.atomic_load(&ring.io_stop) != 0 {
			continue
		}
		if sync.atomic_load_explicit(&ring.state, .Acquire) != .Ready {
			sync.atomic_store_explicit(&ring.state, Connection_Ring_State.Ready, .Release)
			progress = true
		}
		park := sync.atomic_load(&ring.park_state)
		if park == .Park_Asked {
			sim_detach_ring(ring)
			sync.atomic_store(&ring.park_state, Ring_Park_State.Park_Acked)
			progress = true
			continue
		}
		if park != .Active {
			continue
		}
		if sync.atomic_exchange(&ring.batch_pending, 0) != 0 {
			batch_flush(ring)
		}
		submitted_before := ring.send_submit_idx
		submit_nbio_sends(ring)
		if ring.send_submit_idx != submitted_before {
			progress = true
		}
		if ring.pending_recv == nil && ep.peer != nil && !ep.peer.closed {
			submit_nbio_recv(ring)
		}
		if sim_deliver_recv(ep) {
			progress = true
		}
	}

	return progress
}
