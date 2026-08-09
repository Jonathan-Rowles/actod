package actod

import "core:encoding/endian"
import "core:sync"

_ :: endian

FRAME_TAP_ANY :: u64(0)
FRAME_TAP_HANDSHAKE :: u64(1)

MAX_FRAME_FAULTS :: 16

Frame_Dir :: enum u8 {
	Out,
	In,
}

Frame_Fault_Action :: enum u8 {
	Drop,
	Duplicate,
	Corrupt,
}

Frame_Fault_Rule :: struct {
	dir:       Frame_Dir,
	action:    Frame_Fault_Action,
	type_hash: u64,
	node:      ^Node_State,
	peer:      Node_ID,
	count:     int,
	fired:     int,
}

@(private = "file")
g_frame_faults: [MAX_FRAME_FAULTS]Frame_Fault_Rule
@(private = "file")
g_frame_fault_count: int
@(private = "file")
g_frame_fault_mutex: sync.Mutex

frame_tap_add :: proc(rule: Frame_Fault_Rule) {
	assert(
		!(rule.dir == .In && rule.type_hash == FRAME_TAP_HANDSHAKE && rule.action == .Duplicate),
		"frame_tap: Duplicate is not implementable on the inbound handshake path (exactly one frame is returned to the caller); use Drop or Corrupt",
	)
	sync.mutex_lock(&g_frame_fault_mutex)
	defer sync.mutex_unlock(&g_frame_fault_mutex)
	count := sync.atomic_load_explicit(&g_frame_fault_count, .Relaxed)
	assert(count < MAX_FRAME_FAULTS, "frame_tap: too many fault rules")
	g_frame_faults[count] = rule
	sync.atomic_store_explicit(&g_frame_fault_count, count + 1, .Release)
}

frame_tap_clear :: proc() {
	sync.mutex_lock(&g_frame_fault_mutex)
	defer sync.mutex_unlock(&g_frame_fault_mutex)
	sync.atomic_store_explicit(&g_frame_fault_count, 0, .Release)
}

frame_tap_fired :: proc() -> int {
	sync.mutex_lock(&g_frame_fault_mutex)
	defer sync.mutex_unlock(&g_frame_fault_mutex)
	total := 0
	for i in 0 ..< sync.atomic_load_explicit(&g_frame_fault_count, .Relaxed) {
		total += g_frame_faults[i].fired
	}
	return total
}

frame_tap :: proc(
	dir: Frame_Dir,
	type_hash: u64,
	frame: []byte,
	peer: Node_ID = 0,
) -> (
	drop: bool,
	dup: bool,
	corrupt: bool,
) {
	if sync.atomic_load_explicit(&g_frame_fault_count, .Relaxed) == 0 {
		return false, false, false
	}
	sync.mutex_lock(&g_frame_fault_mutex)
	defer sync.mutex_unlock(&g_frame_fault_mutex)
	for i in 0 ..< sync.atomic_load_explicit(&g_frame_fault_count, .Relaxed) {
		rule := &g_frame_faults[i]
		if rule.dir != dir do continue
		if rule.type_hash != FRAME_TAP_ANY && rule.type_hash != type_hash do continue
		if rule.node != nil && rule.node != NODE do continue
		if rule.peer != 0 && (peer == 0 || rule.peer != peer) do continue
		if rule.count > 0 && rule.fired >= rule.count do continue
		rule.fired += 1
		switch rule.action {
		case .Drop:
			return true, false, false
		case .Duplicate:
			return false, true, false
		case .Corrupt:
			if len(frame) > 0 {
				frame[len(frame) - 1] ~= 0xFF
			}
			return false, false, true
		}
	}
	return false, false, false
}

WIRE_TYPE_HASH_OFFSET :: 2
WIRE_SIZE_PREFIX_SIZE :: 4

frame_tap_type_hash :: proc($T: typeid) -> u64 {
	return get_validated_message_info_ptr(T).type_hash
}

frame_tap_out_hash :: #force_inline proc(msg_data: []byte) -> u64 {
	return frame_tap_hash_at(msg_data, WIRE_SIZE_PREFIX_SIZE + WIRE_TYPE_HASH_OFFSET)
}

frame_tap_in_hash :: #force_inline proc(msg_data: []byte) -> u64 {
	return frame_tap_hash_at(msg_data, WIRE_TYPE_HASH_OFFSET)
}

@(private = "file")
frame_tap_hash_at :: #force_inline proc(msg_data: []byte, offset: int) -> u64 {
	if len(msg_data) < offset + 8 do return FRAME_TAP_ANY
	return endian.unchecked_get_u64le(msg_data[offset:offset + 8])
}
