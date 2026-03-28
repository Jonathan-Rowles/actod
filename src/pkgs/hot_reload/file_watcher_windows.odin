#+build windows
package hot_reload

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"
import win32 "core:sys/windows"

MAX_WATCHES :: 64

Watch_Entry :: struct {
	handle:     win32.HANDLE,
	path:       string,
	actor_name: string,
	overlapped: win32.OVERLAPPED,
	buf:        [4096]u8,
	pending:    bool,
}

File_Watcher :: struct {
	callback:       Watch_Callback,
	user_data:      rawptr,
	debounce_ms:    int,
	should_stop:    bool,
	watches:        [MAX_WATCHES]Watch_Entry,
	watch_count:    int,
	issued_count:   int,
	thread:         ^thread.Thread,
}

create_watcher :: proc(
	callback: Watch_Callback,
	user_data: rawptr,
	debounce_ms: int = 100,
) -> (
	^File_Watcher,
	bool,
) {
	w := new(File_Watcher)
	w.callback = callback
	w.user_data = user_data
	w.debounce_ms = debounce_ms
	return w, true
}

add_watch :: proc(watcher: ^File_Watcher, path: string, actor_name: string) -> bool {
	if watcher.watch_count >= MAX_WATCHES do return false

	if is_tmp_watch_path(path) do return true

	wide_path := win32.utf8_to_wstring(path)
	handle := win32.CreateFileW(
		wide_path,
		win32.FILE_LIST_DIRECTORY,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		return false
	}

	event := win32.CreateEventW(nil, win32.TRUE, win32.FALSE, nil)
	if event == nil {
		win32.CloseHandle(handle)
		return false
	}

	idx := watcher.watch_count
	watcher.watches[idx] = Watch_Entry {
		handle     = handle,
		path       = path,
		actor_name = actor_name,
	}
	watcher.watches[idx].overlapped.hEvent = event
	sync.atomic_store_explicit(&watcher.watch_count, idx + 1, .Release)
	return true
}

start_watcher :: proc(watcher: ^File_Watcher) {
	watcher_thread_proc :: proc(t: ^thread.Thread) {
		w := cast(^File_Watcher)t.user_args[0]
		if w == nil do return

		context = runtime.default_context()

		for !sync.atomic_load_explicit(&w.should_stop, .Acquire) {
			count := sync.atomic_load_explicit(&w.watch_count, .Acquire)
			for count > w.issued_count {
				issue_read(&w.watches[w.issued_count])
				w.issued_count += 1
			}

			if count == 0 {
				time.sleep(100 * time.Millisecond)
				continue
			}

			// Build event array for WaitForMultipleObjects
			events: [MAX_WATCHES]win32.HANDLE
			for wi in 0 ..< count {
				events[wi] = w.watches[wi].overlapped.hEvent
			}

			result := win32.WaitForMultipleObjects(
				win32.DWORD(count),
				&events[0],
				win32.FALSE, // wait for ANY
				500, // timeout ms
			)

			if sync.atomic_load_explicit(&w.should_stop, .Acquire) do return

			if result >= win32.WAIT_OBJECT_0 && result < win32.WAIT_OBJECT_0 + win32.DWORD(count) {
				changed_actors: [MAX_WATCHES]string
				changed_paths: [MAX_WATCHES]string
				changed_kinds: [MAX_WATCHES]Watch_Event_Kind
				changed_count: int = 0

				for wi in 0 ..< count {
					check := win32.WaitForMultipleObjects(1, &events[wi], win32.FALSE, 0)
					if check != win32.WAIT_OBJECT_0 do continue

					bytes_returned: win32.DWORD
					if win32.GetOverlappedResult(w.watches[wi].handle, &w.watches[wi].overlapped, &bytes_returned, win32.FALSE) {
						if bytes_returned > 0 {
							process_notifications(
								w.watches[wi].buf[:bytes_returned],
								&w.watches[wi],
								&changed_actors,
								&changed_paths,
								&changed_kinds,
								&changed_count,
							)
						}
					}

					win32.ResetEvent(w.watches[wi].overlapped.hEvent)
					issue_read(&w.watches[wi])
				}

				if changed_count > 0 {
					if w.debounce_ms > 0 {
						time.sleep(time.Duration(w.debounce_ms) * time.Millisecond)
					}

					if sync.atomic_load_explicit(&w.should_stop, .Acquire) do return

					for i in 0 ..< changed_count {
						w.callback(
							Watch_Event {
								path       = changed_paths[i],
								actor_name = changed_actors[i],
								kind       = changed_kinds[i],
							},
							w.user_data,
						)
					}
				}
			}
		}
	}

	t := thread.create(watcher_thread_proc)
	if t != nil {
		t.user_args[0] = rawptr(watcher)
		thread.start(t)
		watcher.thread = t
	}
}

@(private)
issue_read :: proc(watch: ^Watch_Entry) {
	win32.ReadDirectoryChangesW(
		watch.handle,
		&watch.buf,
		win32.DWORD(len(watch.buf)),
		win32.TRUE,
		win32.FILE_NOTIFY_CHANGE_LAST_WRITE |
		win32.FILE_NOTIFY_CHANGE_FILE_NAME |
		win32.FILE_NOTIFY_CHANGE_CREATION,
		nil,
		&watch.overlapped,
		nil,
	)
}

@(private)
process_notifications :: proc(
	buf: []u8,
	watch: ^Watch_Entry,
	actors: ^[MAX_WATCHES]string,
	paths: ^[MAX_WATCHES]string,
	kinds: ^[MAX_WATCHES]Watch_Event_Kind,
	count: ^int,
) {
	offset: u32 = 0
	for {
		if int(offset) + size_of(win32.FILE_NOTIFY_INFORMATION) > len(buf) do break

		info := cast(^win32.FILE_NOTIFY_INFORMATION)&buf[offset]

		name_wchars := int(info.file_name_length) / size_of(win32.WCHAR)
		if name_wchars > 0 {
			name_ptr := &info.file_name
			wide_slice := ([^]win32.WCHAR)(name_ptr)[:name_wchars]

			name_buf: [512]u8
			name_len := 0
			for wc in wide_slice {
				if name_len >= len(name_buf) - 1 do break
				if wc < 128 {
					name_buf[name_len] = u8(wc)
					name_len += 1
				}
			}
			file_name := string(name_buf[:name_len])

			basename := file_name
			for i := name_len - 1; i >= 0; i -= 1 {
				if name_buf[i] == '\\' || name_buf[i] == '/' {
					basename = string(name_buf[i + 1:name_len])
					break
				}
			}

			if !should_ignore_file(file_name, basename) {
				kind: Watch_Event_Kind
				switch info.action {
				case win32.FILE_ACTION_MODIFIED:
					kind = .Modified
				case win32.FILE_ACTION_ADDED, win32.FILE_ACTION_RENAMED_NEW_NAME:
					kind = .Created
				case win32.FILE_ACTION_REMOVED, win32.FILE_ACTION_RENAMED_OLD_NAME:
					kind = .Deleted
				}

				already := false
				for j in 0 ..< count^ {
					if actors[j] == watch.actor_name {
						already = true
						break
					}
				}
				if !already && count^ < MAX_WATCHES {
					actors[count^] = watch.actor_name
					paths[count^] = watch.path
					kinds[count^] = kind
					count^ += 1
				}
			}
		}

		if info.next_entry_offset == 0 do break
		offset += info.next_entry_offset
	}
}

stop_watcher :: proc(watcher: ^File_Watcher) {
	if watcher == nil do return
	sync.atomic_store_explicit(&watcher.should_stop, true, .Release)

	for i in 0 ..< watcher.watch_count {
		if watcher.watches[i].handle != nil && watcher.watches[i].handle != win32.INVALID_HANDLE_VALUE {
			win32.CancelIoEx(watcher.watches[i].handle, nil)
		}
	}

	if watcher.thread != nil {
		thread.join(watcher.thread)
		thread.destroy(watcher.thread)
		watcher.thread = nil
	}
}

destroy_watcher :: proc(watcher: ^File_Watcher) {
	if watcher == nil do return
	stop_watcher(watcher)

	for i in 0 ..< watcher.watch_count {
		if watcher.watches[i].overlapped.hEvent != nil {
			win32.CloseHandle(watcher.watches[i].overlapped.hEvent)
		}
		if watcher.watches[i].handle != nil && watcher.watches[i].handle != win32.INVALID_HANDLE_VALUE {
			win32.CloseHandle(watcher.watches[i].handle)
		}
	}

	free(watcher)
}
