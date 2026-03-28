#+build windows
package shared

import "core:fmt"
import "core:os"

kill_port_holder :: proc(port: int) {
	kill_desc := os.Process_Desc {
		command = []string {
			"powershell",
			"-Command",
			fmt.tprintf(
				"Get-NetTCPConnection -LocalPort %d -ErrorAction SilentlyContinue | ForEach-Object {{ Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }}",
				port,
			),
		},
	}
	kill_proc, kill_err := os.process_start(kill_desc)
	if kill_err == nil {
		_, _ = os.process_wait(kill_proc)
	}
}
