#+build linux, darwin, freebsd, openbsd, netbsd
package integration

import "../actod"
import "core:os"
import "core:sys/posix"
import "core:thread"
import "core:time"

start_parent_monitor :: proc() {
	original_ppid := posix.getppid()

	thread.create_and_start_with_data(rawptr(uintptr(original_ppid)), proc(data: rawptr) {
		ppid := posix.pid_t(uintptr(data))
		for {
			time.sleep(500 * time.Millisecond)
			if posix.getppid() != ppid {
				actod.SHUTDOWN_NODE()
				os.exit(1)
			}
		}
	})
}
