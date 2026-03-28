#+build linux, darwin, freebsd, openbsd, netbsd
package actod

import "core:sync"
import "core:sys/posix"

@(private)
setup_signal_handler :: proc() {
	signal_handler :: proc "c" (sig: posix.Signal) {
		sync.atomic_sema_post(&signal_wake)
	}

	sa_int: posix.sigaction_t
	sa_int.sa_handler = signal_handler
	posix.sigemptyset(&sa_int.sa_mask)
	sa_int.sa_flags = {}
	posix.sigaction(.SIGINT, &sa_int, nil)

	sa_term: posix.sigaction_t
	sa_term.sa_handler = signal_handler
	posix.sigemptyset(&sa_term.sa_mask)
	sa_term.sa_flags = {}
	posix.sigaction(.SIGTERM, &sa_term, nil)
}
