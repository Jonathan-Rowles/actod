#+build windows, freebsd, openbsd, netbsd
package footprint

MEM_STATS_AVAILABLE :: false

read_rss_kb :: proc() -> int {
	return -1
}

read_virtual_kb :: proc() -> int {
	return -1
}

read_vma_count :: proc() -> int {
	return -1
}

read_max_map_count :: proc() -> int {
	return -1
}

print_vma_breakdown :: proc(top: int) {
}

read_mapping_rss_kb :: proc(address: uintptr, size: uint) -> int {
	return -1
}
