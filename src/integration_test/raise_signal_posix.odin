#+build linux, darwin, freebsd, openbsd, netbsd
package integration

import "core:sys/posix"
import "core:thread"
import "core:time"

raise_sigint_to_self :: proc() {
	posix.raise(.SIGINT)
}

raise_sigint_to_self_after :: proc(delay: time.Duration) {
	thread.create_and_start_with_data(rawptr(uintptr(delay)), proc(data: rawptr) {
		time.sleep(time.Duration(uintptr(data)))
		posix.kill(posix.getpid(), .SIGINT)
	})
}
