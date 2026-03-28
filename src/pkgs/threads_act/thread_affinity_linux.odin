#+build linux
package threads_act

import "core:thread"

CPU_SETSIZE :: 1024
cpu_set_t :: struct {
	bits: [CPU_SETSIZE / 64]u64,
}

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	pthread_setaffinity_np :: proc(thread: posix_pthread_t, cpusetsize: uint, cpuset: ^cpu_set_t) -> i32 ---
}

// Match Odin's posix pthread type
posix_pthread_t :: distinct u64

set_thread_affinity :: proc(t: ^thread.Thread, core_id: int) -> bool {
	cpu_count := get_cpu_count()
	if core_id < 0 || core_id >= cpu_count {
		return false
	}

	cpuset: cpu_set_t
	word := uint(core_id) / 64
	bit := uint(core_id) % 64
	cpuset.bits[word] = 1 << bit

	pthread := (cast(^posix_pthread_t)&t.unix_thread)^
	return pthread_setaffinity_np(pthread, size_of(cpu_set_t), &cpuset) == 0
}
