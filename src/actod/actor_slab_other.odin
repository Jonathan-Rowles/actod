#+build !linux
package actod

import vmem "core:mem/virtual"

SLAB_COMMIT_ON_DEMAND :: true

slab_reserve :: proc(size: uint) -> ([]byte, bool) {
	data, err := vmem.reserve(size)
	if err != nil {
		return nil, false
	}
	return data, true
}

slab_commit :: proc(data: rawptr, size: uint) -> bool {
	return vmem.commit(data, size) == nil
}

slab_release :: proc(data: []byte) {
	if len(data) > 0 {
		vmem.release(raw_data(data), uint(len(data)))
	}
}
