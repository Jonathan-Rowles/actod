#+build darwin
package threads_act

import "core:thread"

set_thread_affinity :: proc(t: ^thread.Thread, core_id: int) -> bool {
	return false
}
