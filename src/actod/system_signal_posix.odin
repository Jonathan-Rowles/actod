#+build linux, darwin, freebsd, openbsd, netbsd
package actod

import "core:sync"
import "core:sys/posix"

@(private)
setup_signal_handler :: proc() {
	if NODE.signal_handler_installed do return
	NODE.signal_handler_installed = true

	signal_handler :: proc "c" (sig: posix.Signal) {
		if sync.atomic_exchange(&NODE.stop_requested, true) {
			install_signal_action(.SIGINT, cast(proc "c" (_: posix.Signal))posix.SIG_DFL)
			install_signal_action(.SIGTERM, cast(proc "c" (_: posix.Signal))posix.SIG_DFL)
			posix.raise(sig)
			return
		}
		sync.atomic_sema_post(&NODE.signal_wake)
		sync.atomic_sema_post(&NODE.signal_relay_wake)
	}

	install_signal_action(.SIGINT, signal_handler)
	install_signal_action(.SIGTERM, signal_handler)
}

@(private)
install_signal_action :: proc "contextless" (
	sig: posix.Signal,
	handler: proc "c" (_: posix.Signal),
) {
	action: posix.sigaction_t
	action.sa_handler = handler
	posix.sigemptyset(&action.sa_mask)
	action.sa_flags = {}
	posix.sigaction(sig, &action, nil)
}
