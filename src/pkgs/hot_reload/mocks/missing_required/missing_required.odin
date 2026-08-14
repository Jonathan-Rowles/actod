package missing_required

// Deliberately missing hot_Counter_State_handle_message, only exports state_size.
@(export)
hot_Counter_State_state_size :: proc "c" () -> int {return 4}
