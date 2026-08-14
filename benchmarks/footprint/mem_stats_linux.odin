#+build linux
package footprint

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

MEM_STATS_AVAILABLE :: true

read_status_kb :: proc(key: string) -> int {
	data, err := os.read_entire_file_from_path("/proc/self/status", context.allocator)
	if err != nil {
		return -1
	}
	defer delete(data)

	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, key) {
			continue
		}
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) >= 2 {
			return strconv.parse_int(fields[1]) or_else -1
		}
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
	if err != nil {
		return -1
	}
	defer delete(data)

	count := 0
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if len(line) > 0 {
			count += 1
		}
	}
	return count
}

Vma_Bucket :: struct {
	size_kb: int,
	perms:   string,
	count:   int,
}

print_vma_breakdown :: proc(top: int) {
	data, err := os.read_entire_file_from_path("/proc/self/maps", context.allocator)
	if err != nil {
		return
	}
	defer delete(data)

	buckets := make([dynamic]Vma_Bucket)
	defer delete(buckets)

	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) < 2 {
			continue
		}

		dash := strings.index_byte(fields[0], '-')
		if dash < 0 {
			continue
		}
		start := strconv.parse_u64_of_base(fields[0][:dash], 16) or_else 0
		end := strconv.parse_u64_of_base(fields[0][dash + 1:], 16) or_else 0
		if end <= start {
			continue
		}

		size_kb := int((end - start) / 1024)
		found := false
		for &b in buckets {
			if b.size_kb == size_kb && b.perms == fields[1] {
				b.count += 1
				found = true
				break
			}
		}
		if !found {
			append(&buckets, Vma_Bucket{size_kb = size_kb, perms = fields[1], count = 1})
		}
	}

	slice.sort_by(buckets[:], proc(a: Vma_Bucket, b: Vma_Bucket) -> bool {
		return a.count > b.count
	})

	fmt.println()
	fmt.println("--- VMA breakdown (top buckets by count) ---")
	shown := min(top, len(buckets))
	for i in 0 ..< shown {
		b := buckets[i]
		fmt.printf("%8d x %8d KB  %s\n", b.count, b.size_kb, b.perms)
	}
}

read_mapping_rss_kb :: proc(address: uintptr, size: uint) -> int {
	data, err := os.read_entire_file_from_path("/proc/self/smaps", context.allocator)
	if err != nil {
		return -1
	}
	defer delete(data)

	low := u64(address)
	high := u64(address) + u64(size)
	in_range := false
	total := -1
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line)
		defer delete(fields)
		if len(fields) == 0 {
			continue
		}

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
	if err != nil {
		return -1
	}
	defer delete(data)
	return strconv.parse_int(strings.trim_space(string(data))) or_else -1
}
