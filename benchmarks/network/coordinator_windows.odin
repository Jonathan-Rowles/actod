#+build windows
package network_benchmark

import "core:os"

make_bench_env :: proc(test_vars: []string, allocator := context.temp_allocator) -> []string {
	sys_env, env_err := os.environ(allocator)
	if env_err != nil {
		return test_vars
	}
	merged := make([dynamic]string, 0, len(sys_env) + len(test_vars), allocator)
	strip_prefixes := [1]string{"ACTOD_BENCH_NODE="}
	for v in sys_env {
		skip := false
		for prefix in strip_prefixes {
			if len(v) >= len(prefix) && v[:len(prefix)] == prefix {
				skip = true
				break
			}
		}
		if !skip {
			append(&merged, v)
		}
	}
	for v in test_vars {
		append(&merged, v)
	}
	return merged[:]
}
