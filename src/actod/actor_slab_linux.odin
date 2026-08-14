#+build linux
package actod

import "core:mem"
import "core:sys/linux"

SLAB_COMMIT_ON_DEMAND :: false

slab_reserve :: proc(size: uint) -> ([]byte, bool) {
	total := size + uint(mem.PAGE_SIZE)
	addr, errno := linux.mmap(0, total, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .NORESERVE})
	if errno != .NONE {
		return nil, false
	}
	_ = linux.mprotect(rawptr(uintptr(addr) + uintptr(size)), uint(mem.PAGE_SIZE), {})
	return (cast([^]byte)addr)[:size], true
}

slab_commit :: proc(data: rawptr, size: uint) -> bool {
	return true
}

slab_release :: proc(data: []byte) {
	if len(data) > 0 {
		_ = linux.munmap(raw_data(data), uint(len(data)) + uint(mem.PAGE_SIZE))
	}
}
