package integration

import "core:os"
import "core:strings"

TEST_ENV_STRIP_PREFIXES :: [2]string{"ACTOD_TEST_RUN=", "ACTOD_TEST_NODE="}

make_test_env :: proc(test_vars: []string, allocator := context.temp_allocator) -> []string {
	sys_env, env_err := os.environ(allocator)
	if env_err != nil {
		return test_vars
	}

	overridden := make([dynamic]string, 0, len(test_vars), allocator)
	for v in test_vars {
		if eq := strings.index_byte(v, '='); eq >= 0 {
			append(&overridden, v[:eq + 1])
		}
	}

	strip_prefixes := TEST_ENV_STRIP_PREFIXES
	merged := make([dynamic]string, 0, len(sys_env) + len(test_vars), allocator)
	for v in sys_env {
		skip := false
		for key in overridden {
			if strings.has_prefix(v, key) {
				skip = true
				break
			}
		}
		if !skip {
			for prefix in strip_prefixes {
				if strings.has_prefix(v, prefix) {
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
