package actod

import "base:intrinsics"
import "core:mem"
import "core:sync"

INLINE_MESSAGE_SIZE :: 32
INLINE_NEEDS_FIXUP :: rawptr(uintptr(1))
MAX_ALLOC_RETRIES :: 1000
DEFAULT_PAGE_SIZE :: mem.Kilobyte * 64
MAX_STATIC_MESSAGE_SIZE :: #config(ACTOD_MAX_MESSAGE_SIZE, DEFAULT_PAGE_SIZE)
@(private)
message_owns_page :: #force_inline proc "contextless" (content: rawptr) -> bool {
	return content != nil && content != INLINE_NEEDS_FIXUP
}

@(private)
pool_max_pages :: proc(mailbox_capacity: int) -> int {
	return mailbox_capacity + SYSTEM_MAILBOX_SIZE + LOCAL_MAILBOX_SIZE
}

@(private)
Message :: struct {
	from:    PID,
	content: rawptr,
	using payload: struct #raw_union {
		inline_data: [INLINE_MESSAGE_SIZE]byte,
		ask_token:   u64,
	},
	inline_type: typeid,
}

ASK_REPLY_BIT :: u64(1) << 63

@(private)
message_ask_token :: #force_inline proc "contextless" (msg: ^Message) -> (token: u64, is_reply: bool) {
	if !message_owns_page(msg.content) do return 0, false
	raw := msg.ask_token
	return raw &~ ASK_REPLY_BIT, raw & ASK_REPLY_BIT != 0
}

@(private)
Type_Header :: struct {
	type_id:    typeid,
	size:       i32,
	page_index: i32,
}

TYPE_HEADER_SIZE :: size_of(Type_Header)
#assert(TYPE_HEADER_SIZE == 16, "Type_Header must stay 16 bytes, the inline message path packs around it")

assert_message_fits_page :: #force_inline proc "contextless" ($T: typeid) {
	#assert(
		((TYPE_HEADER_SIZE + size_of(T) + CACHE_LINE_SIZE - 1) / CACHE_LINE_SIZE) *
			CACHE_LINE_SIZE <=
		MAX_STATIC_MESSAGE_SIZE,
		"message type is larger than a message pool page can ever hold, shrink it or raise -define:ACTOD_MAX_MESSAGE_SIZE and actor_config.page_size to match",
	)
}

@(private)
Pool_Entry :: struct {
	sequence:   u64,
	page_index: int,
}

@(private)
Pool_Init_State :: enum u32 {
	UNINITIALIZED = 0,
	INITIALIZING  = 1,
	READY         = 2,
}

@(private)
Pool :: struct {
	read_index:      u64,
	_pad1:           [CACHE_LINE_SIZE - size_of(u64)]byte,
	write_index:     u64,
	_pad2:           [CACHE_LINE_SIZE - size_of(u64)]byte,
	allocated_count: int,
	_pad3:           [CACHE_LINE_SIZE - size_of(int)]byte,
	ring:            [^]Pool_Entry,
	ring_mask:       u64,
	pages:           []rawptr,
	page_size:       int,
	max_pages:       int,
	allocator:       mem.Allocator,
	init_state:      Pool_Init_State,
}

@(private)
pool_init :: proc(
	pool: ^Pool,
	allocator: mem.Allocator,
	page_size: int = NODE.config.actor_config.page_size,
	max_pages: int = DEFAULT_MAIL_BOX_SIZE + SYSTEM_MAILBOX_SIZE + LOCAL_MAILBOX_SIZE,
) {
	pool.page_size = page_size
	pool.max_pages = max_pages
	pool.allocator = allocator

	sync.atomic_store_explicit(&pool.read_index, 0, .Release)
	sync.atomic_store_explicit(&pool.write_index, 0, .Release)
	sync.atomic_store_explicit(&pool.allocated_count, 0, .Release)
	sync.atomic_store_explicit(&pool.init_state, .UNINITIALIZED, .Release)
}

@(private)
pool_ensure_ready :: proc(pool: ^Pool) -> bool {
	if sync.atomic_load_explicit(&pool.init_state, .Acquire) == .READY do return true

	if _, won := sync.atomic_compare_exchange_strong_explicit(
		&pool.init_state,
		Pool_Init_State.UNINITIALIZED,
		Pool_Init_State.INITIALIZING,
		.Acquire,
		.Acquire,
	); won {
		ring_size := next_power_of_two(pool.max_pages)
		pool.pages = make([]rawptr, pool.max_pages, pool.allocator)
		pool.ring = raw_data(make([]Pool_Entry, ring_size, pool.allocator))
		pool.ring_mask = u64(ring_size - 1)

		for i in 0 ..< ring_size {
			pool.ring[i].sequence = u64(i)
			pool.ring[i].page_index = -1
		}

		sync.atomic_store_explicit(&pool.init_state, Pool_Init_State.READY, .Release)
		return true
	}

	for attempt := 0; attempt < MAX_ALLOC_RETRIES; attempt += 1 {
		if sync.atomic_load_explicit(&pool.init_state, .Acquire) == .READY do return true
		intrinsics.cpu_relax()
	}
	return false
}

@(private)
Alloc_Error :: enum {
	OK = 0,
	SIZE_EXCEEDS_PAGE,
	POOL_EXHAUSTED,
	OUT_OF_MEMORY,
	ALLOC_CONTENDED,
	MALFORMED_PAYLOAD,
}

@(private)
message_alloc :: proc(page_pool: ^Pool, size: int) -> (rawptr, Alloc_Error) {
	if size > page_pool.page_size do return nil, .SIZE_EXCEEDS_PAGE

	if !pool_ensure_ready(page_pool) do return nil, .ALLOC_CONTENDED

	for attempt := 0; attempt < MAX_ALLOC_RETRIES; attempt += 1 {
		pos := sync.atomic_load_explicit(&page_pool.read_index, .Relaxed)
		entry := &page_pool.ring[pos & page_pool.ring_mask]
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
				sync.atomic_store_explicit(&entry.sequence, pos + page_pool.ring_mask + 1, .Release)

				ptr := page_pool.pages[page_index]
				(cast(^Type_Header)ptr).page_index = i32(page_index)
				return ptr, .OK
			}
		} else if diff < 0 {
			slot := sync.atomic_load_explicit(&page_pool.allocated_count, .Relaxed)
			if slot >= page_pool.max_pages do return nil, .POOL_EXHAUSTED

			if _, ok := sync.atomic_compare_exchange_strong_explicit(
				&page_pool.allocated_count,
				slot,
				slot + 1,
				.Release,
				.Relaxed,
			); ok {
				ptr, _ := mem.alloc(page_pool.page_size, CACHE_LINE_SIZE, page_pool.allocator)
				if ptr == nil {
					sync.atomic_compare_exchange_strong_explicit(
						&page_pool.allocated_count,
						slot + 1,
						slot,
						.Release,
						.Relaxed,
					)
					return nil, .OUT_OF_MEMORY
				}
				page_pool.pages[slot] = ptr

				(cast(^Type_Header)ptr).page_index = i32(slot)
				return ptr, .OK
			}
		} else {
			intrinsics.cpu_relax()
		}
	}

	return nil, .ALLOC_CONTENDED
}

@(private)
return_page_to_ring :: #force_inline proc(page_pool: ^Pool, idx: int) {
	for {
		pos := sync.atomic_load_explicit(&page_pool.write_index, .Relaxed)
		entry := &page_pool.ring[pos & page_pool.ring_mask]
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
		}

		intrinsics.cpu_relax()
	}
}

@(private)
free_message :: proc(page_pool: ^Pool, ptr: rawptr, loc := #caller_location) {
	if ptr == nil do return

	idx := int((cast(^Type_Header)ptr).page_index)

	if idx < 0 || idx >= page_pool.max_pages || page_pool.pages[idx] != ptr {
		panic_at(
			loc,
			"free_message: invalid page pointer %p, its header says page index %d (valid range is 0 to %d), the page was double freed or its header was overwritten",
			ptr,
			idx,
			page_pool.max_pages - 1,
		)
	}

	return_page_to_ring(page_pool, idx)
}

@(private)
message_free_deferred :: #force_inline proc(buffer: ^Batch_Free_Buffer, ptr: rawptr) {
	if ptr == nil do return

	buffer.entries[buffer.count] = ptr
	buffer.count += 1

	if buffer.count >= FREE_BATCH_SIZE do flush_batch_free(buffer)
}

@(private)
flush_batch_free :: #force_inline proc(buffer: ^Batch_Free_Buffer, loc := #caller_location) {
	if buffer.count == 0 do return

	pool := buffer.pool

	for i := buffer.count - 1; i >= 0; i -= 1 {
		ptr := buffer.entries[i]
		if ptr == nil do continue

		idx := int((cast(^Type_Header)ptr).page_index)

		if idx < 0 || idx >= pool.max_pages || pool.pages[idx] != ptr {
			panic_at(
				loc,
				"flush_batch_free: invalid page pointer %p at batch slot %d, its header says page index %d (valid range is 0 to %d), the page was double freed or its header was overwritten",
				ptr,
				i,
				idx,
				pool.max_pages - 1,
			)
		}

		return_page_to_ring(pool, idx)
	}

	buffer.count = 0
}

@(private)
Batch_Free_Buffer :: struct {
	entries: []rawptr,
	count:   int,
	pool:    ^Pool,
}
