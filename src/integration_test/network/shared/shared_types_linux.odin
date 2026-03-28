#+build linux, freebsd, openbsd, netbsd
package shared

import "core:fmt"
import "core:os"

kill_port_holder :: proc(port: int) {
	fuser_desc := os.Process_Desc {
		command = []string{"fuser", "-k", fmt.tprintf("%d/tcp", port)},
	}
	fuser_proc, fuser_err := os.process_start(fuser_desc)
	if fuser_err == nil {
		_, _ = os.process_wait(fuser_proc)
	}
}
