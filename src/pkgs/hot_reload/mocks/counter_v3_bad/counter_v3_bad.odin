package counter_v3_bad

Big_State :: struct {
	count: i32,
	extra: i32,
}

PID :: distinct u64

handle_message :: proc(data: ^Big_State, from: PID, content: any) {
	data.count += 1
}

@(export) hot_handle_message := handle_message
@(export) hot_state_size :: proc() -> int { return size_of(Big_State) }
