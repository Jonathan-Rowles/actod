#+build linux
package hot_reload

import "core:c"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

foreign import libc "system:c"
foreign libc {
	@(link_name = "inotify_init1")
	_inotify_init1 :: proc(flags: c.int) -> c.int ---
	@(link_name = "inotify_add_watch")
	_inotify_add_watch :: proc(fd: c.int, pathname: cstring, mask: u32) -> c.int ---
	@(link_name = "inotify_rm_watch")
	_inotify_rm_watch :: proc(fd: c.int, wd: c.int) -> c.int ---
}

IN_MODIFY :: u32(0x00000002)
IN_CREATE :: u32(0x00000100)
IN_DELETE :: u32(0x00000200)
IN_MOVED_TO :: u32(0x00000080)

O_NONBLOCK :: c.int(2048)

Inotify_Event :: struct #packed {
	wd:     c.int,
	mask:   u32,
	cookie: u32,
	len:    u32,
}

Pollfd :: struct #packed {
	fd:      c.int,
	events:  c.short,
	revents: c.short,
}

POLLIN :: c.short(0x0001)

foreign libc {
	@(link_name = "poll")
	_poll :: proc(fds: ^Pollfd, nfds: c.ulong, timeout: c.int) -> c.int ---
}

MAX_WATCHES :: 64

Watch_Entry :: struct {
	wd:         c.int,
	path:       string,
	actor_name: string,
}

File_Watcher :: struct {
	fd:          c.int,
	callback:    Watch_Callback,
	user_data:   rawptr,
	debounce_ms: int,
	should_stop: bool,
	watches:     [MAX_WATCHES]Watch_Entry,
	watch_count: int,
	thread:      ^thread.Thread,
}

create_watcher :: proc(
	callback: Watch_Callback,
	user_data: rawptr,
	debounce_ms: int = 100,
) -> (
	^File_Watcher,
	bool,
) {
	fd := _inotify_init1(O_NONBLOCK)
	if fd < 0 {
		return nil, false
	}

	w := new(File_Watcher)
	w.fd = fd
	w.callback = callback
	w.user_data = user_data
	w.debounce_ms = debounce_ms
	return w, true
}

add_watch :: proc(watcher: ^File_Watcher, path: string, actor_name: string) -> bool {
	if watcher.watch_count >= MAX_WATCHES do return false

	if is_tmp_watch_path(path) do return true

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	mask := IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_TO
	wd := _inotify_add_watch(watcher.fd, cpath, mask)
	if wd < 0 {
		return false
	}

	watcher.watches[watcher.watch_count] = Watch_Entry {
		wd         = wd,
		path       = path,
		actor_name = actor_name,
	}
	watcher.watch_count += 1
	return true
}

start_watcher :: proc(watcher: ^File_Watcher) {
	watcher_thread_proc :: proc(t: ^thread.Thread) {
		w := cast(^File_Watcher)t.user_args[0]
		if w == nil do return

		buf: [4096]u8
		pfd := Pollfd {
			fd     = w.fd,
			events = POLLIN,
		}

		for !sync.atomic_load_explicit(&w.should_stop, .Acquire) {
			ret := _poll(&pfd, 1, 500)
			if ret <= 0 do continue

			if sync.atomic_load_explicit(&w.should_stop, .Acquire) do break

			n := posix.read(posix.FD(w.fd), raw_data(&buf), len(buf))
			if n <= 0 do continue

			changed_actors: [MAX_WATCHES]string
			changed_paths: [MAX_WATCHES]string
			changed_kinds: [MAX_WATCHES]Watch_Event_Kind
			changed_count: int = 0

			collect_events :: proc(
				buf: []u8,
				n: int,
				w: ^File_Watcher,
				actors: ^[MAX_WATCHES]string,
				paths: ^[MAX_WATCHES]string,
				kinds: ^[MAX_WATCHES]Watch_Event_Kind,
				count: ^int,
			) {
				offset: int = 0
				for offset < n {
					event := cast(^Inotify_Event)&buf[offset]
					event_size := size_of(Inotify_Event) + int(event.len)
					offset += event_size

					for i in 0 ..< w.watch_count {
						if w.watches[i].wd == event.wd {
							file_name: string
							if event.len > 0 {
								name_ptr := cast([^]u8)&buf[offset - int(event.len)]
								name_len := 0
								for name_len < int(event.len) && name_ptr[name_len] != 0 {
									name_len += 1
								}
								file_name = string(name_ptr[:name_len])
							}

							if should_ignore_file(file_name, file_name) do break

							kind: Watch_Event_Kind
							if event.mask & IN_MODIFY != 0 {
								kind = .Modified
							} else if event.mask & (IN_CREATE | IN_MOVED_TO) != 0 {
								kind = .Created
							} else if event.mask & IN_DELETE != 0 {
								kind = .Deleted
							}

							already := false
							for j in 0 ..< count^ {
								if actors[j] == w.watches[i].actor_name {
									already = true
									break
								}
							}
							if !already && count^ < MAX_WATCHES {
								actors[count^] = w.watches[i].actor_name
								paths[count^] = w.watches[i].path
								kinds[count^] = kind
								count^ += 1
							}
							break
						}
					}
				}
			}

			collect_events(
				buf[:],
				int(n),
				w,
				&changed_actors,
				&changed_paths,
				&changed_kinds,
				&changed_count,
			)

			if changed_count == 0 do continue

			if w.debounce_ms > 0 {
				time.sleep(time.Duration(w.debounce_ms) * time.Millisecond)
				for {
					drain_n := posix.read(posix.FD(w.fd), raw_data(&buf), len(buf))
					if drain_n <= 0 do break
					collect_events(
						buf[:],
						int(drain_n),
						w,
						&changed_actors,
						&changed_paths,
						&changed_kinds,
						&changed_count,
					)
				}
			}

			if sync.atomic_load_explicit(&w.should_stop, .Acquire) do break

			for i in 0 ..< changed_count {
				w.callback(
					Watch_Event {
						path = changed_paths[i],
						actor_name = changed_actors[i],
						kind = changed_kinds[i],
					},
					w.user_data,
				)
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

stop_watcher :: proc(watcher: ^File_Watcher) {
	if watcher == nil do return
	sync.atomic_store_explicit(&watcher.should_stop, true, .Release)
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
		_inotify_rm_watch(watcher.fd, watcher.watches[i].wd)
	}

	posix.close(posix.FD(watcher.fd))
	free(watcher)
}
