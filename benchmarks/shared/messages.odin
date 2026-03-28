package shared

import "../../src/actod"

Message_Size :: enum {
	Empty  = 0,      // 0 bytes
	INLINE = 32,     // 32 bytes - exactly inline size
	STRING = 28,     // 28 bytes - fits in inline
	MEDIUM = 256,    // 256 bytes
	LARGE  = 1024,   // 1 KB
	XLARGE = 4096,   // 4 KB
	HUGE   = 32768,  // 32 KB
	MEGA   = 65536,  // 64 KB
	MEGA2  = 131072, // 128 KB
	MEGA4  = 262144, // 256 KB
}

Empty_Message :: struct {
}

Inline_Message :: struct {
	data: [32]byte,
}

Inline_Message_string :: struct {
	data: string,
}

Medium_Message :: struct {
	data: [256]byte,
}

Large_Message :: struct {
	data: [1024]byte,
}

XLarge_Message :: struct {
	data: [4096]byte,
}

Huge_Message :: struct {
	data: [32768]byte,
}

Mega_Message :: struct {
	data: [65536]byte,
}

Mega2_Message :: struct {
	data: [131072]byte,
}

Mega4_Message :: struct {
	data: [262144]byte,
}

Start_Test_Message :: struct {
	test_id:        int,
	message_size:   Message_Size,
	message_count:  int,
	actor_count:    int,
	sender_count:   int,
	warmup_count:   int,
	test_category:  Test_Category,
	dedicated:      bool,
}

Ready_Message :: struct {
	test_id:     int,
	actor_count: int,
}

Get_PID_Request :: struct {
	actor_name: string,
	request_id: int,
}

Get_PID_Response :: struct {
	request_id: int,
}

Test_Complete_Message :: struct {
	test_id:      int,
	sender_id:    int,
	messages_sent: u64,
}

Stats_Report_Message :: struct {
	test_id:                  int,
	messages_received:        u64,
	start_time_ns:           i64,
	end_time_ns:             i64,
	err_pool_full:           u64,
	err_mailbox_full:        u64,
	err_actor_not_found:     u64,
	err_system_shutting_down: u64,
	err_network:             u64,
	err_other:               u64,
}

Test_Category :: enum {
	BASELINE,
	FANIN,
	PARALLEL,
	STRESS,
	CONTENTION,
	BURST,
	FAIRNESS,
	SIZE_SCALING,
}

size_name :: proc(size: Message_Size) -> string {
	switch size {
	case .Empty:
		return "Empty"
	case .INLINE:
		return "32B"
	case .STRING:
		return "28B"
	case .MEDIUM:
		return "256B"
	case .LARGE:
		return "1KB"
	case .XLARGE:
		return "4KB"
	case .HUGE:
		return "32KB"
	case .MEGA:
		return "64KB"
	case .MEGA2:
		return "128KB"
	case .MEGA4:
		return "256KB"
	}
	return "?"
}

size_bytes :: proc(size: Message_Size) -> int {
	switch size {
	case .Empty:
		return 0
	case .INLINE:
		return 32
	case .STRING:
		return 28
	case .MEDIUM:
		return 256
	case .LARGE:
		return 1024
	case .XLARGE:
		return 4096
	case .HUGE:
		return 32768
	case .MEGA:
		return 65536
	case .MEGA2:
		return 131072
	case .MEGA4:
		return 262144
	}
	return 0
}

@(init)
register_shared_messages :: proc "contextless" () {
	actod.register_message_type(Empty_Message)
	actod.register_message_type(Inline_Message)
	actod.register_message_type(Inline_Message_string)
	actod.register_message_type(Medium_Message)
	actod.register_message_type(Large_Message)
	actod.register_message_type(XLarge_Message)
	actod.register_message_type(Huge_Message)
	actod.register_message_type(Mega_Message)
	actod.register_message_type(Mega2_Message)
	actod.register_message_type(Mega4_Message)
	actod.register_message_type(Start_Test_Message)
	actod.register_message_type(Ready_Message)
	actod.register_message_type(Get_PID_Request)
	actod.register_message_type(Get_PID_Response)
	actod.register_message_type(Test_Complete_Message)
	actod.register_message_type(Stats_Report_Message)
}
