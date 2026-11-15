package actod

import "../../test_harness/ti"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
Owned_Lines :: struct {
	owned:    string,
	seen:     int,
	previous: log.Logger,
}

@(private = "file")
owned_lines_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	lines := cast(^Owned_Lines)data
	if strings.contains(text, lines.owned) {
		lines.seen += 1
		return
	}
	lines.previous.procedure(
		lines.previous.data,
		level,
		text,
		options,
		location,
	)
}

@(private = "file")
own_lines :: proc(lines: ^Owned_Lines) -> log.Logger {
	return log.Logger {
		procedure = owned_lines_proc,
		data = lines,
		lowest_level = .Debug,
	}
}

@(private = "file")
listen_on_loopback :: proc(
	t: ^testing.T,
) -> (
	net.TCP_Socket,
	net.Endpoint,
	bool,
) {
	listener, listen_err := net.listen_tcp(
		net.Endpoint{address = net.IP4_Loopback, port = 0},
	)
	if !testing.expect(t, listen_err == nil, "the loopback listener opened") do return 0, {}, false
	endpoint, bound_err := net.bound_endpoint(listener)
	if !testing.expect(t, bound_err == nil, "the listener has a port") {
		net.close(listener)
		return 0, {}, false
	}
	return listener, endpoint, true
}

@(private = "file")
dial_with_a_failed_make :: proc(
	t: ^testing.T,
	make_name: string,
	owned_line: string,
) {
	listener, endpoint, listening := listen_on_loopback(t)
	if !listening do return
	defer net.close(listener)

	timers: [dynamic]ti.Captured_Timer
	defer delete(timers)
	intercept := ti.Test_Intercept {
		timer_capture = &timers,
		fail_make     = make_name,
	}
	lines := Owned_Lines {
		owned    = owned_line,
		previous = context.logger,
	}
	context.logger = own_lines(&lines)

	data := Connection_Actor_Data {
		node_id               = 9,
		reconnect_retry_delay = 2 * time.Second,
	}
	ti.test_intercept = &intercept
	connection_handle_message(
		&data,
		0,
		Connect_Request{node_id = 9, address = endpoint},
	)
	ti.test_intercept = nil

	testing.expect_value(t, lines.seen, 1)
	testing.expect_value(t, data.state, Connection_State.Failed)
	testing.expect_value(t, data.tcp_socket, net.TCP_Socket(0))
	if testing.expect_value(t, len(timers), 1) {
		testing.expect_value(t, timers[0].interval, 2 * time.Second)
	}
}

@(test)
a_dial_whose_hello_cannot_be_allocated_is_refused_and_retried :: proc(
	t: ^testing.T,
) {
	dial_with_a_failed_make(t, "hello", "Cannot build the HELLO for node 9")
}

@(test)
a_dial_whose_handshake_frame_cannot_be_allocated_is_refused_and_retried :: proc(
	t: ^testing.T,
) {
	dial_with_a_failed_make(
		t,
		"handshake frame",
		"Cannot send a handshake frame",
	)
}

@(private = "file")
AUTH_PEER_NAME :: "auth peer"

@(private = "file")
answer_one_hello :: proc(listener_ptr: rawptr) {
	listener := (cast(^net.TCP_Socket)listener_ptr)^
	peer, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do return
	defer net.close(peer)

	deadline := time.time_add(time.now(), HANDSHAKE_TIMEOUT)
	raw, _ := handshake_recv_ctrl(peer, CTRL_MSG_HELLO, deadline)
	if raw == nil do return
	delete(raw, actor_system_allocator)

	body: [64]byte
	w := Ctrl_Writer {
		buf = body[:],
	}
	ctrl_put_u8(&w, CTRL_MSG_HELLO)
	ctrl_put_u32(&w, WIRE_PROTOCOL_VERSION)
	ctrl_put_u8(&w, 0)
	ctrl_put_u16(&w, 0)
	ctrl_put_str(&w, AUTH_PEER_NAME)
	ctrl_put_u64(&w, 1)
	ctrl_put_u64(&w, 1)
	ctrl_put_u64(&w, 1)
	ctrl_put_u64(&w, 0)
	handshake_send_ctrl(peer, body[:w.pos])
}

@(test)
a_dial_whose_auth_proof_cannot_be_allocated_is_refused_and_retried :: proc(
	t: ^testing.T,
) {
	listener, endpoint, listening := listen_on_loopback(t)
	if !listening do return
	defer net.close(listener)

	peer := thread.create_and_start_with_data(&listener, answer_one_hello)
	defer thread.destroy(peer)

	timers: [dynamic]ti.Captured_Timer
	defer delete(timers)
	intercept := ti.Test_Intercept {
		timer_capture = &timers,
		fail_make     = "auth proof",
	}
	lines := Owned_Lines {
		owned    = "Cannot send the auth proof to node " + AUTH_PEER_NAME,
		previous = context.logger,
	}
	context.logger = own_lines(&lines)

	data := Connection_Actor_Data {
		node_id               = 9,
		reconnect_retry_delay = 2 * time.Second,
		auth_password         = "auth password",
	}
	ti.test_intercept = &intercept
	connection_handle_message(
		&data,
		0,
		Connect_Request{node_id = 9, address = endpoint},
	)
	ti.test_intercept = nil
	thread.join(peer)

	testing.expect_value(t, lines.seen, 1)
	testing.expect_value(t, data.state, Connection_State.Failed)
	testing.expect_value(t, data.tcp_socket, net.TCP_Socket(0))
	if testing.expect_value(t, len(timers), 1) {
		testing.expect_value(t, timers[0].interval, 2 * time.Second)
	}
}

@(private = "file")
scale_up_ring_config :: Connection_Ring_Config {
	send_slot_count  = 4,
	send_slot_size   = 1024,
	recv_buffer_size = 4096,
	max_pool_rings   = 4,
}

@(test)
a_pool_scale_up_whose_hello_cannot_be_allocated_adds_no_ring :: proc(
	t: ^testing.T,
) {
	listener, endpoint, listening := listen_on_loopback(t)
	if !listening do return
	defer net.close(listener)

	pool := make_connection_pool(12, scale_up_ring_config)
	defer free(pool)
	ring := make_connection_ring(scale_up_ring_config)
	if !testing.expect(t, ring != nil, "could not create the ring") do return
	defer destroy_connection_ring(ring)
	ring.pool = pool
	atomic_store_ring_ptr(&pool.rings[0], ring)
	sync.atomic_store(&pool.ring_count, u32(1))

	intercept := ti.Test_Intercept {
		fail_make = "hello",
	}
	lines := Owned_Lines {
		owned    = "Pool scale-up: cannot build the HELLO for node 12",
		previous = context.logger,
	}
	context.logger = own_lines(&lines)

	data := Connection_Actor_Data {
		node_id          = 12,
		state            = .Connected,
		address          = endpoint,
		ring             = ring,
		peer_join_token  = 12345,
		peer_listen_port = u16(endpoint.port),
	}
	ti.test_intercept = &intercept
	connection_handle_message(&data, 0, Scale_Up_Request{})
	ti.test_intercept = nil

	testing.expect_value(t, lines.seen, 1)
	testing.expect_value(t, pool_active_count(pool), 1)
	testing.expect_value(t, data.state, Connection_State.Connected)
}

@(private = "file")
DIRECTORY_ENTRY_SLOT :: MAX_NODES - 1

@(test)
a_node_directory_that_cannot_be_allocated_is_not_sent :: proc(t: ^testing.T) {
	sync.rw_mutex_lock(&NODE.node_registry_lock)
	saved := NODE.node_registry[DIRECTORY_ENTRY_SLOT]
	NODE.node_registry[DIRECTORY_ENTRY_SLOT] = Node_Info {
		node_name = "directory entry",
		address = net.Endpoint{address = net.IP4_Loopback, port = 1},
	}
	sync.rw_mutex_unlock(&NODE.node_registry_lock)
	defer {
		sync.rw_mutex_lock(&NODE.node_registry_lock)
		NODE.node_registry[DIRECTORY_ENTRY_SLOT] = saved
		sync.rw_mutex_unlock(&NODE.node_registry_lock)
	}

	intercept := ti.Test_Intercept {
		fail_make = "node directory",
	}
	lines := Owned_Lines {
		owned    = "Cannot send the node directory to node directory peer",
		previous = context.logger,
	}
	context.logger = own_lines(&lines)

	data := Connection_Actor_Data {
		node_id   = 13,
		node_name = "directory peer",
	}
	ti.test_intercept = &intercept
	send_node_directory(&data)
	ti.test_intercept = nil

	testing.expect_value(t, lines.seen, 1)
}
