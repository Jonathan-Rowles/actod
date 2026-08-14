#+build darwin
package footprint

import "core:fmt"
import "core:sys/darwin"
import "core:sys/posix"

MEM_STATS_AVAILABLE :: true

task_info :: proc() -> (darwin.proc_taskinfo, bool) {
	info: darwin.proc_taskinfo
	written := darwin.proc_pidinfo(
		posix.getpid(),
		.TASKINFO,
		0,
		&info,
		i32(size_of(darwin.proc_taskinfo)),
	)
	return info, written == i32(size_of(darwin.proc_taskinfo))
}

read_rss_kb :: proc() -> int {
	info, ok := task_info()
	if !ok do return -1
	return int(info.pti_resident_size / 1024)
}

read_virtual_kb :: proc() -> int {
	info, ok := task_info()
	if !ok do return -1
	return int(info.pti_virtual_size / 1024)
}

Vm_Region_Submap_Info_64 :: struct #packed {
	protection:               i32,
	max_protection:           i32,
	inheritance:              u32,
	offset:                   u64,
	user_tag:                 u32,
	pages_resident:           u32,
	pages_shared_now_private: u32,
	pages_swapped_out:        u32,
	pages_dirtied:            u32,
	ref_count:                u32,
	shadow_depth:             u16,
	external_pager:           u8,
	share_mode:               u8,
	is_submap:                b32,
	behavior:                 i32,
	object_id:                u32,
	user_wired_count:         u16,
	_pad:                     u16,
	pages_reusable:           u32,
	object_id_full:           u64,
}

#assert(size_of(Vm_Region_Submap_Info_64) == 76)

Region :: struct {
	address:         u64,
	size:            u64,
	protection:      i32,
	pages_resident:  u32,
}

next_region :: proc(address: u64) -> (Region, bool) {
	info: Vm_Region_Submap_Info_64
	region_address := address
	region_size: u64
	depth: u32 = 0
	count := u32(size_of(Vm_Region_Submap_Info_64) / size_of(u32))

	for {
		result := darwin.mach_vm_region_recurse(
			darwin.mach_task_self(),
			&region_address,
			&region_size,
			&depth,
			darwin.vm_region_recurse_info_t(&info),
			&count,
		)
		if result != .Success {
			return {}, false
		}
		if !info.is_submap do break
		depth += 1
	}

	return Region {
			address = region_address,
			size = region_size,
			protection = info.protection,
			pages_resident = info.pages_resident,
		},
		true
}

walk_regions :: proc(visit: proc(region: Region, user: rawptr), user: rawptr) {
	address: u64 = 0
	for {
		region, ok := next_region(address)
		if !ok do return
		visit(region, user)
		next := region.address + region.size
		if next <= address do return
		address = next
	}
}

read_vma_count :: proc() -> int {
	count := 0
	walk_regions(proc(region: Region, user: rawptr) {
		(cast(^int)user)^ += 1
	}, &count)
	return count
}

read_max_map_count :: proc() -> int {
	return -1
}

read_mapping_rss_kb :: proc(address: uintptr, size: uint) -> int {
	page_size := u64(posix.sysconf(._PAGESIZE))
	if page_size == 0 do return -1

	resident_pages: u64 = 0
	cursor := u64(address)
	limit := u64(address) + u64(size)
	for cursor < limit {
		region, ok := next_region(cursor)
		if !ok || region.address >= limit do break
		resident_pages += u64(region.pages_resident)
		next := region.address + region.size
		if next <= cursor do break
		cursor = next
	}
	return int(resident_pages * page_size / 1024)
}

Vma_Visit_Ctx :: struct {
	visit: proc(size_kb: int, perms: string, user: rawptr),
	user:  rawptr,
}

vma_regions :: proc(visit: proc(size_kb: int, perms: string, user: rawptr), user: rawptr) {
	ctx := Vma_Visit_Ctx{visit, user}
	walk_regions(proc(region: Region, user: rawptr) {
		ctx := cast(^Vma_Visit_Ctx)user
		size_kb := int(region.size / 1024)
		ctx.visit(size_kb, protection_string(region.protection), ctx.user)
	}, &ctx)
}

protection_string :: proc(protection: i32) -> string {
	VM_PROT_READ :: 1
	VM_PROT_WRITE :: 2
	VM_PROT_EXECUTE :: 4
	return fmt.tprintf(
		"%c%c%c",
		protection & VM_PROT_READ != 0 ? 'r' : '-',
		protection & VM_PROT_WRITE != 0 ? 'w' : '-',
		protection & VM_PROT_EXECUTE != 0 ? 'x' : '-',
	)
}
