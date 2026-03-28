package actod

import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:sync"

INLINE_MESSAGE_SIZE :: 32
INLINE_NEEDS_FIXUP :: rawptr(uintptr(1)) // sentinel: inline message with string/slice pointers
MAX_ALLOC_RETRIES :: 1000
MAX_POOL_PAGES ::
	(MAILBOX_PRIORITY_COUNT * DEFAULT_MAIL_BOX_SIZE) + SYSTEM_MAILBOX_SIZE + LOCAL_MAILBOX_SIZE

@(private)
_PRV0 :: MAX_POOL_PAGES - 1
@(private)
_PRV1 :: _PRV0 | (_PRV0 >> 1)
@(private)
_PRV2 :: _PRV1 | (_PRV1 >> 2)
@(private)
_PRV3 :: _PRV2 | (_PRV2 >> 4)
@(private)
_PRV4 :: _PRV3 | (_PRV3 >> 8)
@(private)
_PRV5 :: _PRV4 | (_PRV4 >> 16)
@(private)
_PRV6 :: _PRV5 | (_PRV5 >> 32)
POOL_RING_SIZE :: _PRV6 + 1
POOL_RING_MASK :: u64(POOL_RING_SIZE - 1)
#assert(POOL_RING_SIZE >= MAX_POOL_PAGES)
#assert((POOL_RING_SIZE & (POOL_RING_SIZE - 1)) == 0)

@(private)
Message :: struct {
	from:        PID,
	content:     rawptr,
	inline_data: [INLINE_MESSAGE_SIZE]byte,
	inline_type: typeid,
}

@(private)
Type_Header :: struct {
	type_id: typeid,
	size:    int,
}

TYPE_HEADER_SIZE :: size_of(Type_Header)

@(private)
Pool_Entry :: struct {
	sequence:   u64,
	page_index: int,
}

@(private)
Pool :: struct {
	read_index:      u64,
	_pad1:           [CACHE_LINE_SIZE - size_of(u64)]byte,
	write_index:     u64,
	_pad2:           [CACHE_LINE_SIZE - size_of(u64)]byte,
	allocated_count: int,
	_pad3:           [CACHE_LINE_SIZE - size_of(int)]byte,
	ring:            ^[POOL_RING_SIZE]Pool_Entry,
	pages:           []rawptr,
	page_size:       int,
	max_pages:       int,
	allocator:       mem.Allocator,
}

@(private)
init_pool :: proc(
	pool: ^Pool,
	allocator: mem.Allocator,
	page_size: int = SYSTEM_CONFIG.actor_config.page_size,
) {
	pool.page_size = page_size
	pool.max_pages = MAX_POOL_PAGES
	pool.allocator = allocator
	pool.pages = make([]rawptr, MAX_POOL_PAGES, allocator)
	pool.ring = new([POOL_RING_SIZE]Pool_Entry, allocator)

	for i in 0 ..< POOL_RING_SIZE {
		pool.ring[i].sequence = u64(i)
		pool.ring[i].page_index = -1
	}

	sync.atomic_store_explicit(&pool.read_index, 0, .Release)
	sync.atomic_store_explicit(&pool.write_index, 0, .Release)
	sync.atomic_store_explicit(&pool.allocated_count, 0, .Release)
}

@(private)
message_alloc :: proc(page_pool: ^Pool, size: int) -> rawptr {
	if size > page_pool.page_size - size_of([2]int) {
		log.error("page size too small")
		return nil
	}

	for attempt := 0; attempt < MAX_ALLOC_RETRIES; attempt += 1 {
		pos := sync.atomic_load_explicit(&page_pool.read_index, .Relaxed)
		entry := &page_pool.ring[pos & POOL_RING_MASK]
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		diff := i64(seq) - i64(pos + 1)

		if diff == 0 {
			if _, ok := sync.atomic_compare_exchange_weak_explicit(
				&page_pool.read_index,
				pos,
				pos + 1,
				.Release,
				.Relaxed,
			); ok {
				page_index := entry.page_index
				sync.atomic_store_explicit(&entry.sequence, pos + POOL_RING_SIZE, .Release)

				ptr := page_pool.pages[page_index]
				metadata_ptr := cast(^[2]int)(uintptr(ptr) +
					uintptr(page_pool.page_size) -
					size_of([2]int))
				metadata_ptr[0] = page_index
				metadata_ptr[1] = size
				return ptr
			}
		} else if diff < 0 {
			slot := sync.atomic_load_explicit(&page_pool.allocated_count, .Relaxed)
			if slot >= page_pool.max_pages {
				return nil
			}

			if _, ok := sync.atomic_compare_exchange_strong_explicit(
				&page_pool.allocated_count,
				slot,
				slot + 1,
				.Release,
				.Relaxed,
			); ok {
				ptr, _ := mem.alloc(page_pool.page_size, 1, page_pool.allocator)
				if ptr == nil {
					return nil
				}
				page_pool.pages[slot] = ptr

				metadata_ptr := cast(^[2]int)(uintptr(ptr) +
					uintptr(page_pool.page_size) -
					size_of([2]int))
				metadata_ptr[0] = slot
				metadata_ptr[1] = size
				return ptr
			}
		} else {
			intrinsics.cpu_relax()
		}
	}

	return nil
}

@(private)
free_message :: proc(page_pool: ^Pool, ptr: rawptr) {
	if ptr == nil {
		return
	}

	metadata_ptr := cast(^[2]int)(uintptr(ptr) + uintptr(page_pool.page_size) - size_of([2]int))
	idx := metadata_ptr[0]

	if idx < 0 || idx >= page_pool.max_pages || page_pool.pages[idx] != ptr {
		panic("Invalid page pointer in free_page")
	}

	for {
		pos := sync.atomic_load_explicit(&page_pool.write_index, .Relaxed)
		entry := &page_pool.ring[pos & POOL_RING_MASK]
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		diff := i64(seq) - i64(pos)

		if diff == 0 {
			if _, ok := sync.atomic_compare_exchange_weak_explicit(
				&page_pool.write_index,
				pos,
				pos + 1,
				.Release,
				.Relaxed,
			); ok {
				entry.page_index = idx
				sync.atomic_store_explicit(&entry.sequence, pos + 1, .Release)
				return
			}
		} else if diff < 0 {
			intrinsics.cpu_relax()
		} else {
			intrinsics.cpu_relax()
		}
	}
}

@(private)
message_free_deferred :: #force_inline proc(buffer: ^Batch_Free_Buffer, ptr: rawptr, size: int) {
	if ptr == nil do return

	buffer.entries[buffer.count] = ptr
	buffer.sizes[buffer.count] = size
	buffer.count += 1

	if buffer.count >= FREE_BATCH_SIZE {
		flush_batch_free(buffer)
	}
}

@(private)
flush_batch_free :: #force_inline proc(buffer: ^Batch_Free_Buffer) {
	if buffer.count == 0 do return

	pool := buffer.pool

	for i := buffer.count - 1; i >= 0; i -= 1 {
		ptr := buffer.entries[i]
		if ptr == nil do continue

		metadata_ptr := cast(^[2]int)(uintptr(ptr) + uintptr(pool.page_size) - size_of([2]int))
		idx := metadata_ptr[0]

		if idx < 0 || idx >= pool.max_pages || pool.pages[idx] != ptr {
			log.panic("Invalid page pointer in batch free")
		}

		for {
			pos := sync.atomic_load_explicit(&pool.write_index, .Relaxed)
			entry := &pool.ring[pos & POOL_RING_MASK]
			seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
			diff := i64(seq) - i64(pos)

			if diff == 0 {
				if _, ok := sync.atomic_compare_exchange_weak_explicit(
					&pool.write_index,
					pos,
					pos + 1,
					.Release,
					.Relaxed,
				); ok {
					entry.page_index = idx
					sync.atomic_store_explicit(&entry.sequence, pos + 1, .Release)
					break
				}
			} else {
				intrinsics.cpu_relax()
			}
		}
	}

	buffer.count = 0
}

@(private)
Batch_Free_Buffer :: struct {
	entries: []rawptr,
	sizes:   []int,
	count:   int,
	pool:    ^Pool,
}
