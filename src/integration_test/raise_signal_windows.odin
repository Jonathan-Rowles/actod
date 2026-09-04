#+build windows
package integration

import "core:time"

raise_sigint_to_self :: proc() {}

raise_sigint_to_self_after :: proc(delay: time.Duration) {}
