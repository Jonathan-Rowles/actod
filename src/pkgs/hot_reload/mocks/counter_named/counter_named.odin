package counter_named

import shared "../shared"

PID :: distinct u64

handle_message :: proc(data: ^shared.Counter_State, from: PID, content: any) {
	switch m in content {
	case shared.Bump:
		if m.label == shared.BUMP_LABEL do data.count += m.amount
	case:
		data.count += 1000
	}
}

@(export)
hot_Counter_State_handle_message :: proc "c" () -> rawptr {return rawptr(handle_message)}
@(export)
hot_Counter_State_state_size :: proc "c" () -> int {return size_of(shared.Counter_State)}
