package actod

import "../../test_harness/ti"
_ :: ti
import "base:intrinsics"
import "core:mem"

when ODIN_TEST {
	@(init)
	install_message_copier :: proc "contextless" () {
		ti.copy_message = copy_message_for_capture
	}
}

@(private)
copy_message_for_capture :: proc(content: rawptr, size: int, type_id: typeid) -> rawptr {
	info, registered := get_type_info_ptr(type_id)
	variable_size := 0
	if registered do variable_size = calculate_variable_data_size(content, info)
	owned, _ := mem.alloc(size + variable_size)
	intrinsics.mem_copy_non_overlapping(owned, content, size)
	if registered do copy_variable_data(owned, owned, content, info, size)
	return owned
}
