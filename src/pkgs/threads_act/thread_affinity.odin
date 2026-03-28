package threads_act

import "core:os"

get_cpu_count :: proc() -> int {
	return os.get_processor_core_count()
}
