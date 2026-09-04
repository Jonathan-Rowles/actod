#+build windows
package actod

import "core:sync"
import win32 "core:sys/windows"
import "core:thread"
import "core:time"

@(private)
setup_signal_handler :: proc() {
	if NODE.signal_handler_installed do return
	NODE.signal_handler_installed = true

	handler :: proc "system" (ctrl_type: win32.DWORD) -> win32.BOOL {
		switch ctrl_type {
		case win32.CTRL_C_EVENT, win32.CTRL_CLOSE_EVENT, win32.CTRL_SHUTDOWN_EVENT:
			if sync.atomic_exchange(&NODE.stop_requested, true) {
				win32.SetConsoleCtrlHandler(handler, false)
				return false
			}
			sync.atomic_sema_post(&NODE.signal_wake)
			sync.atomic_sema_post(&NODE.signal_relay_wake)
			return true
		}
		return false
	}
	win32.SetConsoleCtrlHandler(handler, true)

	stdin_monitor :: proc(t: ^thread.Thread) {
		stdin_handle := win32.GetStdHandle(win32.STD_INPUT_HANDLE)
		if stdin_handle == win32.INVALID_HANDLE_VALUE || stdin_handle == nil do return

		file_type := win32.GetFileType(stdin_handle)

		switch file_type {
		case win32.FILE_TYPE_CHAR:
			return
		case win32.FILE_TYPE_PIPE:
			for {
				avail: u32
				ok := win32.PeekNamedPipe(stdin_handle, nil, 0, nil, &avail, nil)
				if !ok {
					sync.atomic_sema_post(&NODE.signal_wake)
					return
				}
				runtime_sleep(200 * time.Millisecond)
			}
		case:
			return
		}
	}
	monitor_thread := thread.create(stdin_monitor)
	if monitor_thread != nil do thread.start(monitor_thread)
}
