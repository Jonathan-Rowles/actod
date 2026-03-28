package shared

import "../../../actod/"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

@(init)
register_shared_messages :: proc "contextless" () {
	actod.register_message_type(Two_Node_Message)
	actod.register_message_type(Two_Node_Response)
	actod.register_message_type(Network_Test_Request)
	actod.register_message_type(Network_Test_Response)
	actod.register_message_type(Network_Test_Response)
	actod.register_message_type(Distributed_Echo_Request)
	actod.register_message_type(Distributed_Echo_Response)
	actod.register_message_type(Network_Test_Request)
	actod.register_message_type(Network_Test_Response)
	actod.register_message_type(Distributed_Echo_Request)
	actod.register_message_type(Distributed_Echo_Response)
	actod.register_message_type(Supervision_Crash_Command)
	actod.register_message_type(Supervision_Ping)
	actod.register_message_type(Supervision_Pong)
	actod.register_message_type(Pubsub_Broadcast_Msg)
	actod.register_message_type(Pubsub_Broadcast_Ack)
}

Two_Node_Message :: struct {
	id:          int,
	content:     [512]u8,
	content_len: int,
	sender:      [64]u8,
	sender_len:  int,
}

Two_Node_Response :: struct {
	id:           int,
	content:      [512]u8,
	content_len:  int,
	receiver:     [64]u8,
	receiver_len: int,
}

Network_Test_Request :: struct {
	id:      int,
	message: string,
}

Network_Test_Response :: struct {
	id:        int,
	message:   string,
	from_node: string,
}

Distributed_Echo_Request :: struct {
	id:       int,
	message:  string,
	reply_to: actod.PID,
}

Distributed_Echo_Response :: struct {
	id:         int,
	message:    string,
	from_actor: string,
}

make_two_node_message :: proc(id: int, content: string, sender: string) -> Two_Node_Message {
	msg := Two_Node_Message {
		id = id,
	}

	content_bytes := transmute([]u8)content
	msg.content_len = min(len(content_bytes), len(msg.content))
	mem.copy(&msg.content[0], raw_data(content_bytes), msg.content_len)

	sender_bytes := transmute([]u8)sender
	msg.sender_len = min(len(sender_bytes), len(msg.sender))
	mem.copy(&msg.sender[0], raw_data(sender_bytes), msg.sender_len)

	return msg
}

make_two_node_response :: proc(id: int, content: string, receiver: string) -> Two_Node_Response {
	resp := Two_Node_Response {
		id = id,
	}

	content_bytes := transmute([]u8)content
	resp.content_len = min(len(content_bytes), len(resp.content))
	mem.copy(&resp.content[0], raw_data(content_bytes), resp.content_len)

	receiver_bytes := transmute([]u8)receiver
	resp.receiver_len = min(len(receiver_bytes), len(resp.receiver))
	mem.copy(&resp.receiver[0], raw_data(receiver_bytes), resp.receiver_len)

	return resp
}

get_message_content :: proc(msg: Two_Node_Message) -> string {
	m := msg
	bytes := m.content[:m.content_len]
	return strings.clone_from_bytes(bytes)
}

get_message_sender :: proc(msg: Two_Node_Message) -> string {
	m := msg
	bytes := m.sender[:m.sender_len]
	return strings.clone_from_bytes(bytes)
}

get_response_content :: proc(resp: Two_Node_Response) -> string {
	r := resp
	return string(r.content[:r.content_len])
}

get_response_receiver :: proc(resp: Two_Node_Response) -> string {
	r := resp
	return string(r.receiver[:r.receiver_len])
}

Supervision_Crash_Command :: struct {
	reason: actod.Termination_Reason,
}

Supervision_Ping :: struct {
	id: int,
}

Supervision_Pong :: struct {
	id:        int,
	from_name: string,
}

Pubsub_Broadcast_Msg :: struct {
	value:     u64,
	timestamp: u64,
}

Pubsub_Broadcast_Ack :: struct {
	subscriber_id: int,
	value:         u64,
}

check_port_available :: proc(port: int) {
	addr := net.Endpoint {
		address = net.IP4_Loopback,
		port    = port,
	}

	sock, err := net.listen_tcp(addr)
	if err == nil {
		net.close(sock)
		return
	}

	kill_port_holder(port)

	time.sleep(100 * time.Millisecond)

	retry_sock, retry_err := net.listen_tcp(addr)
	if retry_err != nil {
		panic(
			fmt.tprintf(
				"Port %d is still in use after fuser -k! Run: sudo lsof -ti:%d | xargs -r kill",
				port,
				port,
			),
		)
	}
	net.close(retry_sock)
}
