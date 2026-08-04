package actod

import "base:intrinsics"
import "base:runtime"
import "core:testing"

forge_spawn_response_payload :: proc(error_msg_len: int) -> []byte {
	msg: Remote_Spawn_Response
	msg.error_msg = transmute(string)runtime.Raw_String{data = nil, len = error_msg_len}

	payload := make([]byte, size_of(Remote_Spawn_Response))
	intrinsics.mem_copy_non_overlapping(raw_data(payload), &msg, size_of(Remote_Spawn_Response))
	return payload
}

@(test)
test_spawn_response_rejects_overflowing_string_length :: proc(t: ^testing.T) {
	payload := forge_spawn_response_payload(max(int) - 8)
	defer delete(payload)

	handle_remote_spawn_response(payload)
}

@(test)
test_spawn_response_rejects_negative_string_length :: proc(t: ^testing.T) {
	payload := forge_spawn_response_payload(-1)
	defer delete(payload)

	handle_remote_spawn_response(payload)
}
