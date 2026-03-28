package counter_v2

import shared "../shared"

PID :: distinct u64

handle_message :: proc(data: ^shared.Counter_State, from: PID, content: any) {
	data.count += 10
}

@(export)
hot_handle_message := handle_message
@(export)
hot_state_size :: proc() -> int {return size_of(shared.Counter_State)}
