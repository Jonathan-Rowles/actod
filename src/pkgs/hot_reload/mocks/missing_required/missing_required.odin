package missing_required

// Deliberately missing hot_handle_message — only exports state_size.
@(export)
hot_state_size :: proc() -> int {return 4}
