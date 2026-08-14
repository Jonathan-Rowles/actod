#+build linux
package footprint

import "core:os"
import "core:strconv"
import "core:strings"

MEM_STATS_AVAILABLE :: true

read_status_kb :: proc(key: string) -> int {
	data, err := os.read_entire_file_from_path("/proc/self/status", context.allocator)
	if err != nil do return -1
	defer delete(data)

	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, key) do continue
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) >= 2 do return strconv.parse_int(fields[1]) or_else -1
	}
	return -1
}

read_rss_kb :: proc() -> int {
	return read_status_kb("VmRSS:")
}

read_virtual_kb :: proc() -> int {
	return read_status_kb("VmSize:")
}

read_vma_count :: proc() -> int {
	data, err := os.read_entire_file_from_path("/proc/self/maps", context.allocator)
	if err != nil do return -1
	defer delete(data)

	count := 0
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if len(line) > 0 do count += 1
	}
	return count
}

vma_regions :: proc(visit: proc(size_kb: int, perms: string, user: rawptr), user: rawptr) {
	data, err := os.read_entire_file_from_path("/proc/self/maps", context.allocator)
	if err != nil do return
	defer delete(data)

	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) < 2 do continue

		dash := strings.index_byte(fields[0], '-')
		if dash < 0 do continue
		start := strconv.parse_u64_of_base(fields[0][:dash], 16) or_else 0
		end := strconv.parse_u64_of_base(fields[0][dash + 1:], 16) or_else 0
		if end <= start do continue

		size_kb := int((end - start) / 1024)
		visit(size_kb, fields[1], user)
	}
}

read_mapping_rss_kb :: proc(address: uintptr, size: uint) -> int {
	data, err := os.read_entire_file_from_path("/proc/self/smaps", context.allocator)
	if err != nil do return -1
	defer delete(data)

	low := u64(address)
	high := u64(address) + u64(size)
	in_range := false
	total := -1
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) == 0 do continue

		if dash := strings.index_byte(fields[0], '-'); dash > 0 && len(fields) >= 2 {
			start := strconv.parse_u64_of_base(fields[0][:dash], 16) or_else 0
			end := strconv.parse_u64_of_base(fields[0][dash + 1:], 16) or_else 0
			in_range = start < high && end > low
			continue
		}

		if in_range && fields[0] == "Rss:" && len(fields) >= 2 {
			rss := strconv.parse_int(fields[1]) or_else 0
			total = max(total, 0) + rss
		}
	}
	return total
}

read_max_map_count :: proc() -> int {
	data, err := os.read_entire_file_from_path("/proc/sys/vm/max_map_count", context.allocator)
	if err != nil do return -1
	defer delete(data)
	return strconv.parse_int(strings.trim_space(string(data))) or_else -1
}
