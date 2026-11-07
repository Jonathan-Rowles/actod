package actod

import "base:runtime"
_ :: runtime
import "core:sync"
_ :: sync

when ODIN_TEST {
	@(private)
	counted_system_backing: runtime.Allocator

	@(private)
	counted_system_live_allocations: int

	@(private)
	counted_system_allocator :: proc(backing: runtime.Allocator) -> runtime.Allocator {
		counted_system_backing = backing
		return runtime.Allocator{procedure = counted_system_allocator_proc}
	}

	@(private)
	counted_system_allocator_proc :: proc(
		allocator_data: rawptr,
		mode: runtime.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		location := #caller_location,
	) -> (
		[]byte,
		runtime.Allocator_Error,
	) {
		result, err := counted_system_backing.procedure(
			counted_system_backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			location,
		)
		if err != .None do return result, err
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			if result != nil do sync.atomic_add(&counted_system_live_allocations, 1)
		case .Free:
			if old_memory != nil do sync.atomic_sub(&counted_system_live_allocations, 1)
		case .Resize, .Resize_Non_Zeroed:
			if old_memory == nil && result != nil do sync.atomic_add(&counted_system_live_allocations, 1)
			if old_memory != nil && size == 0 do sync.atomic_sub(&counted_system_live_allocations, 1)
		}
		return result, err
	}

	system_allocator_live_allocations :: proc() -> int {
		return sync.atomic_load(&counted_system_live_allocations)
	}
}
