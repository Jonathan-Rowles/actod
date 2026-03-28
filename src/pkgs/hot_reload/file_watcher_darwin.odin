#+build darwin
package hot_reload

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"

foreign import core_services "system:CoreServices.framework"

CFAllocatorRef :: rawptr
CFStringRef :: rawptr
CFArrayRef :: rawptr
CFArrayCallBacks :: rawptr
CFIndex :: c.long
CFStringEncoding :: u32
CFTimeInterval :: f64

FSEventStreamRef :: rawptr
FSEventStreamEventFlags :: u32
FSEventStreamEventId :: u64

FSEventStreamContext :: struct {
	version:          CFIndex,
	info:             rawptr,
	retain:           rawptr,
	release:          rawptr,
	copy_description: rawptr,
}

FSEventStreamCallback :: #type proc "c" (
	stream: FSEventStreamRef,
	info: rawptr,
	num_events: c.ulong,
	event_paths: [^]cstring,
	event_flags: [^]FSEventStreamEventFlags,
	event_ids: [^]FSEventStreamEventId,
)

dispatch_queue_t :: rawptr

kCFStringEncodingUTF8 :: CFStringEncoding(0x08000100)
kCFAllocatorDefault: CFAllocatorRef = nil

kFSEventStreamEventIdSinceNow :: FSEventStreamEventId(0xFFFFFFFFFFFFFFFF)
kFSEventStreamCreateFlagFileEvents :: u32(0x00000010)
kFSEventStreamCreateFlagNoDefer :: u32(0x00000002)

kFSEventStreamEventFlagItemCreated :: FSEventStreamEventFlags(0x00000100)
kFSEventStreamEventFlagItemRemoved :: FSEventStreamEventFlags(0x00000200)
kFSEventStreamEventFlagItemModified :: FSEventStreamEventFlags(0x00001000)
kFSEventStreamEventFlagItemRenamed :: FSEventStreamEventFlags(0x00000800)
kFSEventStreamEventFlagItemIsFile :: FSEventStreamEventFlags(0x00010000)

foreign core_services {
	CFStringCreateWithCString :: proc(alloc: CFAllocatorRef, cStr: cstring, encoding: CFStringEncoding) -> CFStringRef ---
	CFArrayCreate :: proc(alloc: CFAllocatorRef, values: [^]rawptr, numValues: CFIndex, callbacks: CFArrayCallBacks) -> CFArrayRef ---
	CFRelease :: proc(cf: rawptr) ---

	FSEventStreamCreate :: proc(
		alloc: CFAllocatorRef,
		callback: FSEventStreamCallback,
		ctx: ^FSEventStreamContext,
		pathsToWatch: CFArrayRef,
		sinceWhen: FSEventStreamEventId,
		latency: CFTimeInterval,
		flags: u32,
	) -> FSEventStreamRef ---
	FSEventStreamSetDispatchQueue :: proc(stream: FSEventStreamRef, queue: dispatch_queue_t) ---
	FSEventStreamStart :: proc(stream: FSEventStreamRef) -> bool ---
	FSEventStreamStop :: proc(stream: FSEventStreamRef) ---
	FSEventStreamInvalidate :: proc(stream: FSEventStreamRef) ---
	FSEventStreamRelease :: proc(stream: FSEventStreamRef) ---

	dispatch_queue_create :: proc(label: cstring, attr: rawptr) -> dispatch_queue_t ---
	dispatch_release :: proc(object: rawptr) ---
}

MAX_WATCHES :: 64

Watch_Entry :: struct {
	path:       string,
	actor_name: string,
}

File_Watcher :: struct {
	callback:    Watch_Callback,
	user_data:   rawptr,
	debounce_ms: int,
	should_stop: bool,
	watches:     [MAX_WATCHES]Watch_Entry,
	watch_count: int,
	stream:      FSEventStreamRef,
	queue:       dispatch_queue_t,
	started:     bool,
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

	watcher.watches[watcher.watch_count] = Watch_Entry {
		path       = path,
		actor_name = actor_name,
	}
	watcher.watch_count += 1

	if watcher.started {
		restart_stream(watcher)
	}

	return true
}

start_watcher :: proc(watcher: ^File_Watcher) {
	if watcher.queue == nil {
		watcher.queue = dispatch_queue_create("actod.fsevents", nil)
	}
	watcher.started = true

	if watcher.watch_count > 0 {
		create_stream(watcher)
	}
}

@(private)
create_stream :: proc(watcher: ^File_Watcher) {
	if watcher.watch_count == 0 || watcher.queue == nil do return

	unique_paths: [MAX_WATCHES]string
	unique_count: int
	for i in 0 ..< watcher.watch_count {
		already := false
		for j in 0 ..< unique_count {
			if unique_paths[j] == watcher.watches[i].path {
				already = true
				break
			}
		}
		if !already {
			unique_paths[unique_count] = watcher.watches[i].path
			unique_count += 1
		}
	}

	cf_strings: [MAX_WATCHES]rawptr
	for i in 0 ..< unique_count {
		cpath := strings.clone_to_cstring(unique_paths[i], context.temp_allocator)
		cf_strings[i] = CFStringCreateWithCString(kCFAllocatorDefault, cpath, kCFStringEncodingUTF8)
	}

	paths_array := CFArrayCreate(kCFAllocatorDefault, raw_data(&cf_strings), CFIndex(unique_count), nil)

	ctx := FSEventStreamContext {
		version = 0,
		info    = rawptr(watcher),
	}

	latency := CFTimeInterval(watcher.debounce_ms) / 1000.0
	flags := kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer

	watcher.stream = FSEventStreamCreate(
		kCFAllocatorDefault,
		fsevents_callback,
		&ctx,
		paths_array,
		kFSEventStreamEventIdSinceNow,
		latency,
		flags,
	)

	CFRelease(paths_array)
	for i in 0 ..< unique_count {
		CFRelease(cf_strings[i])
	}

	if watcher.stream != nil {
		FSEventStreamSetDispatchQueue(watcher.stream, watcher.queue)
		FSEventStreamStart(watcher.stream)
	}
}

@(private)
restart_stream :: proc(watcher: ^File_Watcher) {
	if watcher.stream != nil {
		FSEventStreamStop(watcher.stream)
		FSEventStreamInvalidate(watcher.stream)
		FSEventStreamRelease(watcher.stream)
		watcher.stream = nil
	}
	create_stream(watcher)
}

fsevents_callback :: proc "c" (
	stream: FSEventStreamRef,
	info: rawptr,
	num_events: c.ulong,
	event_paths: [^]cstring,
	event_flags: [^]FSEventStreamEventFlags,
	event_ids: [^]FSEventStreamEventId,
) {
	context = runtime.default_context()

	w := cast(^File_Watcher)info
	if w == nil do return
	if sync.atomic_load_explicit(&w.should_stop, .Acquire) do return

	changed_actors: [MAX_WATCHES]string
	changed_paths: [MAX_WATCHES]string
	changed_kinds: [MAX_WATCHES]Watch_Event_Kind
	changed_count: int

	for i in 0 ..< int(num_events) {
		flags := event_flags[i]

		if flags & kFSEventStreamEventFlagItemIsFile == 0 do continue

		file_path := string(event_paths[i])

		basename := file_path
		if last_slash := strings.last_index_byte(file_path, '/'); last_slash >= 0 {
			basename = file_path[last_slash + 1:]
		}

		if should_ignore_file(file_path, basename) do continue

		kind: Watch_Event_Kind
		if flags & kFSEventStreamEventFlagItemModified != 0 {
			kind = .Modified
		} else if flags & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0 {
			kind = .Created
		} else if flags & kFSEventStreamEventFlagItemRemoved != 0 {
			kind = .Deleted
		}

		dir_path := file_path
		if last_slash := strings.last_index_byte(file_path, '/'); last_slash >= 0 {
			dir_path = file_path[:last_slash]
		}

		for j in 0 ..< w.watch_count {
			if w.watches[j].path == dir_path || strings.has_prefix(dir_path, w.watches[j].path) {
				already := false
				for k in 0 ..< changed_count {
					if changed_actors[k] == w.watches[j].actor_name {
						already = true
						break
					}
				}
				if !already && changed_count < MAX_WATCHES {
					changed_actors[changed_count] = w.watches[j].actor_name
					changed_paths[changed_count] = w.watches[j].path
					changed_kinds[changed_count] = kind
					changed_count += 1
				}
				break
			}
		}
	}

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

stop_watcher :: proc(watcher: ^File_Watcher) {
	if watcher == nil do return
	sync.atomic_store_explicit(&watcher.should_stop, true, .Release)

	if watcher.stream != nil {
		FSEventStreamStop(watcher.stream)
		FSEventStreamInvalidate(watcher.stream)
		FSEventStreamRelease(watcher.stream)
		watcher.stream = nil
	}
}

destroy_watcher :: proc(watcher: ^File_Watcher) {
	if watcher == nil do return
	stop_watcher(watcher)

	if watcher.queue != nil {
		dispatch_release(watcher.queue)
		watcher.queue = nil
	}

	free(watcher)
}
