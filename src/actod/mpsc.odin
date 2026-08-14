package actod

import "base:intrinsics"
import "core:sync"

@(private)
Entry :: struct($T: typeid) #align (CACHE_LINE_SIZE) {
	sequence: u64,
	data:     T,
	_pad:     [CACHE_LINE_SIZE - size_of(u64) - size_of(T)]byte,
}

@(private)
MPSC_Queue :: struct($T: typeid, $N: int) where N >= 0, (N & (N - 1)) == 0 {
	_pad0:       [CACHE_LINE_SIZE]byte,
	write_index: u64,
	w_mask:      u64,
	w_entries:   [^]Entry(T),
	_pad1:       [CACHE_LINE_SIZE - 2 * size_of(u64) - size_of(rawptr)]byte,
	read_index:  u64,
	r_mask:      u64,
	r_entries:   [^]Entry(T),
	_pad2:       [CACHE_LINE_SIZE - 2 * size_of(u64) - size_of(rawptr)]byte,
	buffer:      [N]Entry(T),
}

@(private)
mpsc_init :: proc(q: ^MPSC_Queue($T, $N)) {
	#assert(N > 0, "mpsc_init needs an embedded buffer, use mpsc_init_external for N == 0")
	mpsc_init_external(q, q.buffer[:])
}

@(private)
mpsc_init_external :: proc(q: ^MPSC_Queue($T, $N), entries: []Entry(T)) {
	assert(len(entries) > 0 && (len(entries) & (len(entries) - 1)) == 0)

	q.write_index = 0
	q.read_index = 0
	q.w_mask = u64(len(entries) - 1)
	q.r_mask = u64(len(entries) - 1)
	q.w_entries = raw_data(entries)
	q.r_entries = raw_data(entries)

	for i in 0 ..< len(entries) {
		q.w_entries[i].sequence = u64(i)
	}

	sync.atomic_thread_fence(.Release)
}

// Push - thread safe
@(private)
mpsc_push :: proc(q: ^MPSC_Queue($T, $N), data: T) -> bool {
	mask := q.w_mask
	entries := q.w_entries

	for {
		pos := sync.atomic_load_explicit(&q.write_index, .Relaxed)

		entry := &entries[pos & mask]

		intrinsics.prefetch_write_data(entry, 3)
		next_entry := &entries[(pos + 1) & mask]
		intrinsics.prefetch_write_data(next_entry, 2)

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		diff := i64(seq) - i64(pos)

		if diff == 0 {
			_, ok := sync.atomic_compare_exchange_weak_explicit(
				&q.write_index,
				pos,
				pos + 1,
				.Release,
				.Relaxed,
			)

			if ok {
				entry.data = data

				sync.atomic_store_explicit(&entry.sequence, pos + 1, .Release)
				return true
			}

		} else if diff < 0 {
			return false

		} else {
			intrinsics.cpu_relax()
		}
	}
}

// Pop batch - single consumer, deferred sequence release
@(private)
mpsc_pop_batch :: proc(q: ^MPSC_Queue($T, $N), items: []T) -> int {
	mask := q.r_mask
	entries := q.r_entries
	count := 0
	max_count := len(items)
	start_pos := q.read_index

	for count < max_count {
		pos := start_pos + u64(count)
		entry := &entries[pos & mask]

		if count + 3 < max_count do intrinsics.prefetch_read_data(&entries[(pos + 1) & mask], 3)

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		if seq != pos + 1 do break

		items[count] = entry.data
		count += 1
	}

	if count == 0 do return 0

	sync.atomic_store_explicit(&q.read_index, start_pos + u64(count), .Relaxed)

	sync.atomic_thread_fence(.Release)
	for i in 0 ..< count {
		pos := start_pos + u64(i)
		sync.atomic_store_explicit(&entries[pos & mask].sequence, pos + mask + 1, .Relaxed)
	}

	return count
}

mpsc_size :: proc(q: ^MPSC_Queue($T, $N)) -> int {
	write_idx := sync.atomic_load_explicit(&q.write_index, .Relaxed)
	read_idx := q.read_index

	size := i64(write_idx) - i64(read_idx)
	if size < 0 do return 0
	capacity := i64(q.r_mask) + 1
	if size > capacity do return int(capacity)
	return int(size)
}

mpsc_is_empty_relaxed :: proc(q: ^MPSC_Queue($T, $N)) -> bool {
	pos := q.read_index
	mask := q.r_mask
	entry := &q.r_entries[pos & mask]
	seq := sync.atomic_load_explicit(&entry.sequence, .Relaxed)
	return seq != pos + 1
}

mpsc_has_ready_acquire :: proc(q: ^MPSC_Queue($T, $N)) -> bool {
	pos := q.read_index
	mask := q.r_mask
	entry := &q.r_entries[pos & mask]
	return sync.atomic_load_explicit(&entry.sequence, .Acquire) == pos + 1
}

mpsc_peek :: proc(q: ^MPSC_Queue($T, $N), data: ^T) -> bool {
	mask := q.r_mask
	pos := q.read_index
	entry := &q.r_entries[pos & mask]
	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

	if seq == pos + 1 {
		data^ = entry.data
		return true
	}

	return false
}
