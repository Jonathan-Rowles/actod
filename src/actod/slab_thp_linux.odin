#+build linux
package actod

import "core:sys/linux"

slab_disable_transparent_hugepages :: proc(data: rawptr, size: uint) {
	_ = linux.madvise(data, size, .NOHUGEPAGE)
}
