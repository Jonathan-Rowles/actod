#+build windows
package threads_act

import win32 "core:sys/windows"
import "core:thread"

set_thread_affinity :: proc(t: ^thread.Thread, core_id: int) -> bool {
	cpu_count := get_cpu_count()
	if core_id < 0 || core_id >= cpu_count {
		return false
	}
	mask := win32.DWORD_PTR(1) << uint(core_id)
	result := win32.SetThreadAffinityMask(t.win32_thread, mask)
	return result != 0
}
