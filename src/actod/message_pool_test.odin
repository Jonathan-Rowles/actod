package actod

import "core:fmt"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

TEST_ITERATIONS :: 5000
STRESS_THREADS :: 16
MESSAGES_PER_BATCH :: 1000

TEST_DEFAULT_ARENA_SIZE :: mem.Megabyte

Test_Message :: struct {
	id:        u64,
	data:      [64]byte,
	timestamp: time.Time,
}

@(test)
test_pool_init :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	testing.expect(t, pool.pages != nil, "Page pool pages should be allocated")
	testing.expect(
		t,
		len(pool.pages) == pool.max_pages,
		fmt.tprintf("Expected %d pages, got %d", pool.max_pages, len(pool.pages)),
	)
}

@(test)
test_basic_alloc_free :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	size := 256
	ptr := message_alloc(&pool, size)
	testing.expect(t, ptr != nil, "Pointer should not be nil")

	data := cast([^]byte)ptr
	for i in 0 ..< size {
		data[i] = byte(i & 0xFF)
	}

	for i in 0 ..< size {
		testing.expect(t, data[i] == byte(i & 0xFF), fmt.tprintf("Data mismatch at offset %d", i))
	}

	free_message(&pool, ptr)
}

@(test)
test_multiple_allocations :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	sizes := []int{64, 256, 1024, 2048, 3000}
	ptrs := make([]rawptr, len(sizes))
	defer delete(ptrs)

	for i in 0 ..< len(sizes) {
		ptr := message_alloc(&pool, sizes[i])
		testing.expect(t, ptr != nil, "Pointer should not be nil")
		ptrs[i] = ptr
	}

	for i in 0 ..< len(ptrs) {
		free_message(&pool, ptrs[i])
	}
}

@(test)
test_large_allocation :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	size := pool.page_size - size_of([2]int)
	ptr := message_alloc(&pool, size)
	testing.expect(t, ptr != nil, "Pointer should not be nil")

	old_logger := context.logger
	context.logger = {}
	defer {context.logger = old_logger}

	size = pool.page_size + 1
	ptr = message_alloc(&pool, size)
	testing.expect(t, ptr == nil, "Pointer should be nil for failed allocation")
}

@(test)
test_concurrent_allocations :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	num_threads :: 8
	allocations_per_thread :: 100
	allocation_size :: 1024

	wg: sync.Wait_Group
	sync.wait_group_add(&wg, num_threads)

	Worker_Data :: struct {
		pool: ^Pool,
		wg:   ^sync.Wait_Group,
		id:   int,
	}

	worker :: proc(data: rawptr) {
		work_data := cast(^Worker_Data)data
		defer sync.wait_group_done(work_data.wg)

		ptrs := make([]rawptr, allocations_per_thread)
		defer delete(ptrs)

		for i in 0 ..< allocations_per_thread {
			ptr := message_alloc(work_data.pool, allocation_size)
			if ptr != nil {
				ptrs[i] = ptr
				data := cast([^]byte)ptr
				for j in 0 ..< min(16, allocation_size) {
					data[j] = byte(work_data.id)
				}
			}
		}

		for ptr in ptrs {
			if ptr != nil {
				free_message(work_data.pool, ptr)
			}
		}
	}

	worker_datas := make([]Worker_Data, num_threads)
	threads := make([]^thread.Thread, num_threads)
	defer delete(worker_datas)
	defer delete(threads)

	for i in 0 ..< num_threads {
		worker_datas[i] = Worker_Data {
			pool = &pool,
			wg   = &wg,
			id   = i,
		}
		threads[i] = thread.create_and_start_with_data(&worker_datas[i], worker)
	}

	sync.wait_group_wait(&wg)

	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

@(test)
test_batch_free :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	buffer: Batch_Free_Buffer
	buffer.entries = make([]rawptr, FREE_BATCH_SIZE)
	buffer.sizes = make([]int, FREE_BATCH_SIZE)
	buffer.pool = &pool
	defer delete(buffer.entries)
	defer delete(buffer.sizes)

	size := 512
	for i in 0 ..< FREE_BATCH_SIZE - 1 {
		ptr := message_alloc(&pool, size)
		testing.expect(t, ptr != nil, fmt.tprintf("Allocation %d should succeed", i))
		if ptr != nil {
			message_free_deferred(&buffer, ptr, size)
		}
	}

	testing.expect(t, buffer.count == FREE_BATCH_SIZE - 1, "Buffer should not be flushed yet")

	ptr := message_alloc(&pool, size)
	testing.expect(t, ptr != nil, "Final allocation should succeed")
	if ptr != nil {
		message_free_deferred(&buffer, ptr, size)
	}

	testing.expect(t, buffer.count == 0, "Buffer should be flushed")
}

@(test)
test_pool_exhaustion :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	ptrs := make([]rawptr, pool.max_pages + 10)
	defer delete(ptrs)

	size := pool.page_size / 2
	successful_allocs := 0

	for i in 0 ..< len(ptrs) {
		ptr := message_alloc(&pool, size)
		if ptr != nil {
			ptrs[i] = ptr
			successful_allocs += 1
		} else {
			testing.expect(
				t,
				successful_allocs == pool.max_pages,
				fmt.tprintf(
					"Expected %d successful allocations, got %d",
					pool.max_pages,
					successful_allocs,
				),
			)
			break
		}
	}

	for i := 0; i < successful_allocs; i += 2 {
		if ptrs[i] != nil {
			free_message(&pool, ptrs[i])
			ptrs[i] = nil
		}
	}

	ptr := message_alloc(&pool, size)
	testing.expect(t, ptr != nil, "Should be able to allocate after freeing")

	for p in ptrs {
		if p != nil {
			free_message(&pool, p)
		}
	}
}

@(test)
test_message_reuse :: proc(t: ^testing.T) {
	pool: Pool
	init_pool(&pool, context.allocator)
	defer cleanup_pool(&pool)

	size := 1024
	iterations :: 100

	seen_ptrs := make(map[rawptr]bool)
	defer delete(seen_ptrs)

	for i in 0 ..< iterations {
		ptr := message_alloc(&pool, size)
		testing.expect(t, ptr != nil, fmt.tprintf("Allocation %d should succeed", i))

		if ptr != nil {
			if _, exists := seen_ptrs[ptr]; exists {
				delete_key(&seen_ptrs, ptr)
			} else {
				seen_ptrs[ptr] = true
			}

			data := cast([^]u64)ptr
			for j in 0 ..< size / size_of(u64) {
				data[j] = u64(i) << 32 | u64(j)
			}

			free_message(&pool, ptr)
		}
	}

	testing.expect(
		t,
		len(seen_ptrs) < iterations,
		fmt.tprintf(
			"Expected memory reuse, but used %d unique pointers for %d iterations",
			len(seen_ptrs),
			iterations,
		),
	)
}


@(private)
cleanup_pool :: proc(pool: ^Pool) {
	if pool.ring != nil {
		free(pool.ring, pool.allocator)
	}
	if pool.pages != nil {
		for i in 0 ..< pool.max_pages {
			if pool.pages[i] != nil {
				mem.free(pool.pages[i])
			}
		}
		delete(pool.pages)
	}
}
