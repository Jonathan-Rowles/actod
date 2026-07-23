package counter_v1

import shared "../shared"

PID :: distinct u64

handle_message :: proc(data: ^shared.Counter_State, from: PID, content: any) {
	data.count += 1
}

init :: proc(data: ^shared.Counter_State) {
	data.count = 0
}

@(export)
hot_handle_message :: proc "c" () -> rawptr {return rawptr(handle_message)}
@(export)
hot_init :: proc "c" () -> rawptr {return rawptr(init)}
@(export)
hot_state_size :: proc "c" () -> int {return size_of(shared.Counter_State)}
