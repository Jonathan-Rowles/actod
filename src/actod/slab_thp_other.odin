#+build !linux
package actod

slab_disable_transparent_hugepages :: proc(data: rawptr, size: uint) {
}
