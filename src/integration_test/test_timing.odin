package integration

import "../pkgs/threads_act"
import "core:time"

TIMING_REFERENCE_CORES :: 8

@(private)
cached_timeout_scale: int

timeout_scale :: proc() -> int {
	if cached_timeout_scale == 0 {
		cores := max(threads_act.get_cpu_count(), 1)
		cached_timeout_scale = max(1, (TIMING_REFERENCE_CORES + cores - 1) / cores)
	}
	return cached_timeout_scale
}

scaled_timeout_ms :: proc(ms: int) -> int {
	return ms * timeout_scale()
}

scaled_timeout :: proc(d: time.Duration) -> time.Duration {
	return d * time.Duration(timeout_scale())
}

scaled_attempts :: proc(attempts: int) -> int {
	return attempts * timeout_scale()
}
