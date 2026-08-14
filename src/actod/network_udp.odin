package actod

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"
import "core:log"
import "core:net"
import "core:sync"
import "core:thread"

UDP_MAX_DATAGRAM_HARD :: 65507
UDP_FRAME_BUFFER :: 2048
UDP_HEADER_PLAIN :: 4
UDP_HEADER_SEALED :: 4 + 8
UDP_RECV_TIMEOUT_SECS :: 1
UDP_SNAPSHOT_RETRIES :: 8

Udp_Peer :: struct {
	generation: u32,
	active:     bool,
	encrypted:  bool,
	endpoint:   net.Endpoint,
	token_out:  u32,
	token_in:   u32,
	seq_out:    u64,
	keys:       Udp_Keys,
}

@(private)
Udp_State :: struct {
	enabled:     bool,
	recv_socket: net.UDP_Socket,
	send_socket: net.UDP_Socket,
	recv_thread: ^thread.Thread,
	recv_ctx:    ^Udp_Recv_Context,
	running:     i32,
	peers:       [MAX_NODES]Udp_Peer,
}

@(private)
Udp_Recv_Context :: struct {
	allocator: runtime.Allocator,
	logger:    runtime.Logger,
}

udp_local_enabled :: #force_inline proc() -> bool {
	return NODE.udp.enabled
}

udp_max_frame_bytes :: proc() -> int {
	if !NODE.udp.enabled do return 0
	limit := NODE.config.network.udp_max_datagram
	if limit <= 0 || limit > UDP_MAX_DATAGRAM_HARD do limit = UDP_MAX_DATAGRAM_HARD
	overhead := UDP_HEADER_PLAIN
	if NODE.config.network.enable_encryption do overhead = UDP_HEADER_SEALED + UDP_TAG_SIZE
	return min(limit - overhead, UDP_FRAME_BUFFER)
}

init_udp :: proc(loc := #caller_location) -> bool {
	port := NODE.config.network.udp_port
	if port <= 0 || NODE.config.sim_mode do return true

	if !NODE.config.network.enable_encryption {
		log.warnf(
			"UDP lane on port %d disabled: enable_encryption is required (plaintext UDP is unauthenticated); set enable_encryption = true in make_network_config or send_unreliable will fall back to TCP",
			port,
			location = loc,
		)
		return true
	}

	bind_addr, _ := parse_bind_address(NODE.config.network.bind_address)
	recv_sock, recv_err := net.make_bound_udp_socket(bind_addr, port)
	if recv_err != nil {
		log.errorf(
			"Failed to bind UDP port %d: %v; another process may already hold it, change udp_port in make_network_config",
			port,
			recv_err,
			location = loc,
		)
		return false
	}

	send_sock, send_err := net.make_unbound_udp_socket(.IP4)
	if send_err != nil {
		log.errorf(
			"Failed to create the UDP send socket for port %d: %v; the UDP lane will be unavailable",
			port,
			send_err,
			location = loc,
		)
		net.close(recv_sock)
		return false
	}
	net.set_blocking(send_sock, false)

	platform_set_recv_timeout(
		net.TCP_Socket(net.Socket(recv_sock)),
		UDP_RECV_TIMEOUT_SECS,
	)

	ctx := new(Udp_Recv_Context, get_system_allocator())
	ctx.allocator = get_system_allocator()
	ctx.logger = context.logger

	prev_allocator := context.allocator
	context.allocator = get_system_allocator()
	t := thread.create(udp_recv_loop)
	context.allocator = prev_allocator
	if t == nil {
		log.errorf(
			"Failed to create the UDP recv thread for port %d; the UDP lane will be unavailable",
			port,
			location = loc,
		)
		free(ctx, get_system_allocator())
		net.close(recv_sock)
		net.close(send_sock)
		return false
	}

	NODE.udp.recv_socket = recv_sock
	NODE.udp.send_socket = send_sock
	NODE.udp.recv_ctx = ctx
	sync.atomic_store(&NODE.udp.running, 1)
	NODE.udp.enabled = true

	t.user_args[0] = ctx
	NODE.udp.recv_thread = t
	thread.start(t)

	log.infof("UDP lane listening on port %d", port)
	return true
}

shutdown_udp :: proc() {
	if !NODE.udp.enabled do return
	NODE.udp.enabled = false
	sync.atomic_store(&NODE.udp.running, 0)

	net.close(NODE.udp.recv_socket)
	if NODE.udp.recv_thread != nil {
		thread.join(NODE.udp.recv_thread)
		prev_allocator := context.allocator
		context.allocator = get_system_allocator()
		thread.destroy(NODE.udp.recv_thread)
		context.allocator = prev_allocator
		NODE.udp.recv_thread = nil
	}
	if NODE.udp.recv_ctx != nil {
		free(NODE.udp.recv_ctx, get_system_allocator())
		NODE.udp.recv_ctx = nil
	}
	net.close(NODE.udp.send_socket)
	NODE.udp.recv_socket = {}
	NODE.udp.send_socket = {}

	for i in 0 ..< MAX_NODES {
		NODE.udp.peers[i] = {}
	}
}

udp_register_peer :: proc(
	node_id: Node_ID,
	endpoint: net.Endpoint,
	token_out: u32,
	token_in: u32,
	keys: Udp_Keys,
	encrypted: bool,
) {
	if node_id == 0 || node_id >= MAX_NODES do return
	peer := &NODE.udp.peers[node_id]
	gen := sync.atomic_load(&peer.generation)
	sync.atomic_store_explicit(&peer.generation, gen + 1, .Release)

	peer.endpoint = endpoint
	peer.token_out = token_out
	peer.token_in = token_in
	peer.keys = keys
	peer.encrypted = encrypted
	sync.atomic_store(&peer.seq_out, 0)
	peer.active = true

	sync.atomic_store_explicit(&peer.generation, gen + 2, .Release)
}

udp_clear_peer :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id >= MAX_NODES do return
	peer := &NODE.udp.peers[node_id]
	if !peer.active do return
	gen := sync.atomic_load(&peer.generation)
	sync.atomic_store_explicit(&peer.generation, gen + 1, .Release)

	peer.active = false
	peer.endpoint = {}
	peer.token_out = 0
	peer.token_in = 0
	peer.keys = {}

	sync.atomic_store_explicit(&peer.generation, gen + 2, .Release)
}

// Safe from any producer thread. A sequence number consumed under a torn
// generation is discarded, never sent, so (key, nonce) pairs are never reused.
udp_try_send :: proc(node_id: Node_ID, frame_with_size: []byte) -> bool {
	if !NODE.udp.enabled || node_id == 0 || node_id >= MAX_NODES do return false
	if len(frame_with_size) > UDP_FRAME_BUFFER do return false

	peer := &NODE.udp.peers[node_id]

	for _ in 0 ..< UDP_SNAPSHOT_RETRIES {
		g1 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 & 1 != 0 {
			intrinsics.cpu_relax()
			continue
		}
		if !peer.active do return false

		endpoint := peer.endpoint
		token := peer.token_out
		encrypted := peer.encrypted
		key: [UDP_KEY_SIZE]byte
		seq: u64
		if encrypted {
			key = peer.keys.send_key
			seq = sync.atomic_add(&peer.seq_out, 1) + 1
		}

		g2 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 != g2 {
			intrinsics.cpu_relax()
			continue
		}

		out: [UDP_HEADER_SEALED + UDP_FRAME_BUFFER + UDP_TAG_SIZE]byte
		endian.put_u32(out[0:4], .Little, token)

		total: int
		if encrypted {
			endian.put_u64(out[4:12], .Little, seq)
			sealed_len, sealed := udp_seal(
				key[:],
				seq,
				out[:UDP_HEADER_SEALED],
				frame_with_size,
				out[UDP_HEADER_SEALED:],
			)
			if !sealed {
				log.errorf(
					"Failed to seal a %d byte UDP frame for node %d; falling back to TCP",
					len(frame_with_size),
					node_id,
				)
				return false
			}
			total = UDP_HEADER_SEALED + sealed_len
		} else {
			copy(out[UDP_HEADER_PLAIN:], frame_with_size)
			total = UDP_HEADER_PLAIN + len(frame_with_size)
		}

		_, err := net.send_udp(NODE.udp.send_socket, out[:total], endpoint)
		return err == nil
	}

	return false
}

@(private)
udp_snapshot_for_recv :: proc(
	token: u32,
) -> (
	node_id: Node_ID,
	generation: u32,
	encrypted: bool,
	recv_key: [UDP_KEY_SIZE]byte,
	found: bool,
) {
	for i in 1 ..< MAX_NODES {
		peer := &NODE.udp.peers[i]
		g1 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 & 1 != 0 || !peer.active || peer.token_in != token do continue
		enc := peer.encrypted
		key := peer.keys.recv_key
		g2 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 != g2 do continue
		return Node_ID(i), g1, enc, key, true
	}
	return 0, 0, false, {}, false
}

@(private)
udp_dispatch_frames :: proc(node_id: Node_ID, frames: []byte) {
	offset := 0
	for offset + 4 <= len(frames) {
		msg_size := int(endian.unchecked_get_u32le(frames[offset:]))
		if msg_size == 0 || offset + 4 + msg_size > len(frames) {
			log.warn("Malformed frame inside UDP datagram")
			return
		}

		frame := frames[offset + 4:offset + 4 + msg_size]
		header, ok := parse_network_header(frame)
		if ok {
			if .CONTROL in header.flags || .LIFECYCLE_EVENT in header.flags {
				log.warn("Dropping control frame received over UDP")
			} else {
				deliver_to_target(
					node_id,
					header.flags,
					header.type_hash,
					header.from_handle,
					header.to_handle,
					header.to_name,
					header.payload,
					header.ask_token,
				)
			}
		}
		offset += 4 + msg_size
	}
}

udp_recv_loop :: proc(t: ^thread.Thread) {
	ctx := cast(^Udp_Recv_Context)t.user_args[0]
	if ctx == nil do return

	context.allocator = ctx.allocator
	context.logger = ctx.logger

	recv_buf: [65536]byte
	open_buf: [65536]byte
	replay_windows: [MAX_NODES]Replay_Window
	replay_gens: [MAX_NODES]u32

	for sync.atomic_load(&NODE.udp.running) != 0 {
		n, _, err := net.recv_udp(NODE.udp.recv_socket, recv_buf[:])
		if err != nil {
			if sync.atomic_load(&NODE.udp.running) == 0 do break
			continue
		}
		if n < UDP_HEADER_PLAIN + 1 do continue

		datagram := recv_buf[:n]
		token := endian.unchecked_get_u32le(datagram)

		node_id, generation, encrypted, recv_key, found := udp_snapshot_for_recv(token)
		if !found do continue

		if !encrypted {
			udp_dispatch_frames(node_id, datagram[UDP_HEADER_PLAIN:])
			continue
		}

		if n < UDP_HEADER_SEALED + UDP_TAG_SIZE + 1 do continue

		window := &replay_windows[node_id]
		if replay_gens[node_id] != generation {
			replay_gens[node_id] = generation
			window^ = {}
		}

		seq := endian.unchecked_get_u64le(datagram[4:])
		if !replay_check(window, seq) do continue

		plaintext, opened := udp_open(
			recv_key[:],
			seq,
			datagram[:UDP_HEADER_SEALED],
			datagram[UDP_HEADER_SEALED:],
			open_buf[:],
		)
		if !opened do continue

		replay_commit(window, seq)
		udp_dispatch_frames(node_id, plaintext)
	}
}
