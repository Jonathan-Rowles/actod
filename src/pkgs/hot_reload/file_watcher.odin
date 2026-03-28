package hot_reload

import "core:path/filepath"
import "core:strings"

Watch_Event_Kind :: enum {
	Modified,
	Created,
	Deleted,
}

Watch_Event :: struct {
	path:       string,
	actor_name: string,
	kind:       Watch_Event_Kind,
}

Watch_Callback :: proc(event: Watch_Event, user_data: rawptr)

should_ignore_file :: proc(file_path: string, basename: string) -> bool {
	if !strings.has_suffix(basename, ".odin") do return true
	if basename == "hot_exports.odin" do return true
	if strings.has_prefix(basename, "tmp") do return true
	if has_path_segment(file_path, "tmp") do return true
	return false
}

is_tmp_watch_path :: proc(path: string) -> bool {
	trimmed := strings.trim_right(path, "/\\")
	name := filepath.base(trimmed)
	return name == "tmp"
}

@(private)
has_path_segment :: proc(path: string, segment: string) -> bool {
	fwd := strings.concatenate({"/", segment, "/"}, context.temp_allocator)
	bck := strings.concatenate({"\\", segment, "\\"}, context.temp_allocator)
	if strings.contains(path, fwd) || strings.contains(path, bck) do return true
	fwd_prefix := strings.concatenate({segment, "/"}, context.temp_allocator)
	bck_prefix := strings.concatenate({segment, "\\"}, context.temp_allocator)
	if strings.has_prefix(path, fwd_prefix) || strings.has_prefix(path, bck_prefix) do return true
	return false
}
