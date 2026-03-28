#+build windows
package integration

import "core:os"

make_test_env :: proc(test_vars: []string, allocator := context.temp_allocator) -> []string {
	sys_env, env_err := os.environ(allocator)
	if env_err != nil {
		return test_vars
	}
	override_keys: [32]string
	override_count := 0
	for v in test_vars {
		for i in 0 ..< len(v) {
			if v[i] == '=' {
				if override_count < len(override_keys) {
					override_keys[override_count] = v[:i + 1]
					override_count += 1
				}
				break
			}
		}
	}
	merged := make([dynamic]string, 0, len(sys_env) + len(test_vars), allocator)
	strip_prefixes := [2]string{"ACTOD_TEST_RUN=", "ACTOD_TEST_NODE="}
	for v in sys_env {
		skip := false
		for k in 0 ..< override_count {
			if len(v) >= len(override_keys[k]) && v[:len(override_keys[k])] == override_keys[k] {
				skip = true
				break
			}
		}
		if !skip {
			for prefix in strip_prefixes {
				if len(v) >= len(prefix) && v[:len(prefix)] == prefix {
					skip = true
					break
				}
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
