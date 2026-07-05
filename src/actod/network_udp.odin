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
g_udp: Udp_State

@(private)
Udp_Recv_Context :: struct {
	allocator: runtime.Allocator,
	logger:    runtime.Logger,
}

udp_local_enabled :: #force_inline proc() -> bool {
	return g_udp.enabled
}

udp_max_frame_bytes :: proc() -> int {
	if !g_udp.enabled {
		return 0
	}
	limit := SYSTEM_CONFIG.network.udp_max_datagram
	if limit <= 0 || limit > UDP_MAX_DATAGRAM_HARD {
		limit = UDP_MAX_DATAGRAM_HARD
	}
	overhead := UDP_HEADER_PLAIN
	if SYSTEM_CONFIG.network.enable_encryption {
		overhead = UDP_HEADER_SEALED + UDP_TAG_SIZE
	}
	return min(limit - overhead, UDP_FRAME_BUFFER)
}

init_udp :: proc() -> bool {
	port := SYSTEM_CONFIG.network.udp_port
	if port <= 0 {
		return true
	}

	if !SYSTEM_CONFIG.network.enable_encryption {
		log.warnf(
			"UDP lane on port %d disabled: enable_encryption is required (plaintext UDP is unauthenticated); send_unreliable will use TCP",
			port,
		)
		return true
	}

	recv_sock, recv_err := net.make_bound_udp_socket(net.IP4_Any, port)
	if recv_err != nil {
		log.errorf("Failed to bind UDP port %d: %v", port, recv_err)
		return false
	}

	send_sock, send_err := net.make_unbound_udp_socket(.IP4)
	if send_err != nil {
		log.errorf("Failed to create UDP send socket: %v", send_err)
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
		log.error("Failed to create UDP recv thread")
		free(ctx, get_system_allocator())
		net.close(recv_sock)
		net.close(send_sock)
		return false
	}

	g_udp.recv_socket = recv_sock
	g_udp.send_socket = send_sock
	g_udp.recv_ctx = ctx
	sync.atomic_store(&g_udp.running, 1)
	g_udp.enabled = true

	t.user_args[0] = ctx
	g_udp.recv_thread = t
	thread.start(t)

	log.infof("UDP lane listening on port %d", port)
	return true
}

shutdown_udp :: proc() {
	if !g_udp.enabled {
		return
	}
	g_udp.enabled = false
	sync.atomic_store(&g_udp.running, 0)

	net.close(g_udp.recv_socket)
	if g_udp.recv_thread != nil {
		thread.join(g_udp.recv_thread)
		prev_allocator := context.allocator
		context.allocator = get_system_allocator()
		thread.destroy(g_udp.recv_thread)
		context.allocator = prev_allocator
		g_udp.recv_thread = nil
	}
	if g_udp.recv_ctx != nil {
		free(g_udp.recv_ctx, get_system_allocator())
		g_udp.recv_ctx = nil
	}
	net.close(g_udp.send_socket)
	g_udp.recv_socket = {}
	g_udp.send_socket = {}

	for i in 0 ..< MAX_NODES {
		g_udp.peers[i] = {}
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
	if node_id == 0 || node_id >= MAX_NODES {
		return
	}
	peer := &g_udp.peers[node_id]
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
	if node_id == 0 || node_id >= MAX_NODES {
		return
	}
	peer := &g_udp.peers[node_id]
	if !peer.active {
		return
	}
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
	if !g_udp.enabled || node_id == 0 || node_id >= MAX_NODES {
		return false
	}
	if len(frame_with_size) > UDP_FRAME_BUFFER {
		return false
	}

	peer := &g_udp.peers[node_id]

	for _ in 0 ..< UDP_SNAPSHOT_RETRIES {
		g1 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 & 1 != 0 {
			intrinsics.cpu_relax()
			continue
		}
		if !peer.active {
			return false
		}

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
				return false
			}
			total = UDP_HEADER_SEALED + sealed_len
		} else {
			copy(out[UDP_HEADER_PLAIN:], frame_with_size)
			total = UDP_HEADER_PLAIN + len(frame_with_size)
		}

		_, err := net.send_udp(g_udp.send_socket, out[:total], endpoint)
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
		peer := &g_udp.peers[i]
		g1 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 & 1 != 0 || !peer.active || peer.token_in != token {
			continue
		}
		enc := peer.encrypted
		key := peer.keys.recv_key
		g2 := sync.atomic_load_explicit(&peer.generation, .Acquire)
		if g1 != g2 {
			continue
		}
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
				)
			}
		}
		offset += 4 + msg_size
	}
}

udp_recv_loop :: proc(t: ^thread.Thread) {
	ctx := cast(^Udp_Recv_Context)t.user_args[0]
	if ctx == nil {
		return
	}

	context.allocator = ctx.allocator
	context.logger = ctx.logger

	recv_buf: [65536]byte
	open_buf: [65536]byte
	replay_windows: [MAX_NODES]Replay_Window
	replay_gens: [MAX_NODES]u32

	for sync.atomic_load(&g_udp.running) != 0 {
		n, _, err := net.recv_udp(g_udp.recv_socket, recv_buf[:])
		if err != nil {
			if sync.atomic_load(&g_udp.running) == 0 {
				break
			}
			continue
		}
		if n < UDP_HEADER_PLAIN + 1 {
			continue
		}

		datagram := recv_buf[:n]
		token := endian.unchecked_get_u32le(datagram)

		node_id, generation, encrypted, recv_key, found := udp_snapshot_for_recv(token)
		if !found {
			continue
		}

		if !encrypted {
			udp_dispatch_frames(node_id, datagram[UDP_HEADER_PLAIN:])
			continue
		}

		if n < UDP_HEADER_SEALED + UDP_TAG_SIZE + 1 {
			continue
		}

		window := &replay_windows[node_id]
		if replay_gens[node_id] != generation {
			replay_gens[node_id] = generation
			window^ = {}
		}

		seq := endian.unchecked_get_u64le(datagram[4:])
		if !replay_check(window, seq) {
			continue
		}

		plaintext, opened := udp_open(
			recv_key[:],
			seq,
			datagram[:UDP_HEADER_SEALED],
			datagram[UDP_HEADER_SEALED:],
			open_buf[:],
		)
		if !opened {
			continue
		}

		replay_commit(window, seq)
		udp_dispatch_frames(node_id, plaintext)
	}
}
