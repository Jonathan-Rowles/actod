#+build windows
package integration

import "../actod"
import "core:os"
import win32 "core:sys/windows"
import "core:thread"

@(private)
get_parent_pid :: proc() -> win32.DWORD {
	my_pid := win32.GetCurrentProcessId()
	snapshot := win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0)
	if snapshot == win32.INVALID_HANDLE_VALUE {
		return 0
	}
	defer win32.CloseHandle(snapshot)

	entry: win32.PROCESSENTRY32W
	entry.dwSize = size_of(win32.PROCESSENTRY32W)

	if !win32.Process32FirstW(snapshot, &entry) {
		return 0
	}

	for {
		if entry.th32ProcessID == my_pid {
			return entry.th32ParentProcessID
		}
		if !win32.Process32NextW(snapshot, &entry) {
			break
		}
	}
	return 0
}

start_parent_monitor :: proc() {
	ppid := get_parent_pid()
	if ppid == 0 {
		return
	}

	parent_handle := win32.OpenProcess(win32.SYNCHRONIZE, win32.FALSE, ppid)
	if parent_handle == nil {
		return
	}

	thread.create_and_start_with_data(rawptr(parent_handle), proc(data: rawptr) {
		handle := win32.HANDLE(data)
		win32.WaitForSingleObject(handle, win32.INFINITE)
		win32.CloseHandle(handle)
		actod.SHUTDOWN_NODE()
		os.exit(1)
	})
}
