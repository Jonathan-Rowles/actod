#+build darwin
package shared

import "core:fmt"
import "core:os"

kill_port_holder :: proc(port: int) {
	kill_desc := os.Process_Desc {
		command = []string {
			"bash",
			"-c",
			fmt.tprintf("lsof -ti:%d | xargs kill -9 2>/dev/null", port),
		},
	}
	kill_proc, kill_err := os.process_start(kill_desc)
	if kill_err == nil {
		_, _ = os.process_wait(kill_proc)
	}
}
