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
MPSC_Queue :: struct($T: typeid, $N: int) where N > 0, (N & (N - 1)) == 0 {
	_pad0:       [CACHE_LINE_SIZE]byte,
	write_index: u64,
	_pad1:       [CACHE_LINE_SIZE]byte,
	read_index:  u64,
	_pad2:       [CACHE_LINE_SIZE]byte,
	buffer:      [N]Entry(T),
}

@(private)
init_mpsc :: proc(q: ^MPSC_Queue($T, $N)) {
	q.write_index = 0
	q.read_index = 0

	for i in 0 ..< N {
		q.buffer[i].sequence = u64(i)
	}

	sync.atomic_thread_fence(.Release)
}

// Push - thread safe
@(private)
mpsc_push :: proc(q: ^MPSC_Queue($T, $N), data: T) -> bool {
	mask := u64(N - 1)

	for {
		pos := sync.atomic_load_explicit(&q.write_index, .Relaxed)

		entry := &q.buffer[pos & mask]

		intrinsics.prefetch_write_data(entry, 3)
		next_entry := &q.buffer[(pos + 1) & mask]
		intrinsics.prefetch_write_data(next_entry, 2)

		seq := sync.atomic_load_explicit(&entry.sequence, .Relaxed)

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

@(private)
mpsc_try_push :: #force_inline proc(q: ^MPSC_Queue($T, $N), data: T) -> bool {
	mask := u64(N - 1)

	pos := sync.atomic_load_explicit(&q.write_index, .Relaxed)
	entry := &q.buffer[pos & mask]
	seq := sync.atomic_load_explicit(&entry.sequence, .Relaxed)

	diff := i64(seq) - i64(pos)
	if diff != 0 {
		return false
	}

	_, ok := sync.atomic_compare_exchange_weak_explicit(
		&q.write_index,
		pos,
		pos + 1,
		.Release,
		.Relaxed,
	)
	if !ok {
		return false
	}

	entry.data = data
	sync.atomic_store_explicit(&entry.sequence, pos + 1, .Release)
	return true
}

// Pop - single consumer
@(private)
mpsc_pop :: proc(q: ^MPSC_Queue($T, $N), data: ^T) -> bool {
	mask := u64(N - 1)

	pos := q.read_index
	entry := &q.buffer[pos & mask]
	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

	if seq != pos + 1 {
		return false
	}

	data^ = entry.data

	sync.atomic_store_explicit(&entry.sequence, pos + u64(N), .Release)

	q.read_index = pos + 1

	return true
}

// Push batch - thread safe TODO: actually batch
@(private)
mpsc_push_batch :: proc(q: ^MPSC_Queue($T, $N), items: []T) -> int {
	count := 0
	for item in items {
		if !mpsc_push(q, item) {
			break
		}
		count += 1
	}
	return count
}

// Pop batch - single consumer, deferred sequence release
@(private)
mpsc_pop_batch :: proc(q: ^MPSC_Queue($T, $N), items: []T) -> int {
	mask := u64(N - 1)
	count := 0
	max_count := len(items)
	start_pos := q.read_index

	for count < max_count {
		pos := start_pos + u64(count)
		entry := &q.buffer[pos & mask]

		if count + 1 < max_count {
			intrinsics.prefetch_read_data(&q.buffer[(pos + 1) & mask], 3)
		}

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		if seq != pos + 1 {
			break
		}

		items[count] = entry.data
		count += 1
	}

	if count == 0 {
		return 0
	}

	q.read_index = start_pos + u64(count)

	sync.atomic_thread_fence(.Release)
	for i in 0 ..< count {
		pos := start_pos + u64(i)
		q.buffer[pos & mask].sequence = pos + u64(N)
	}

	return count
}

mpsc_size :: proc(q: ^MPSC_Queue($T, $N)) -> int {
	write_idx := sync.atomic_load_explicit(&q.write_index, .Relaxed)
	read_idx := q.read_index

	size := i64(write_idx) - i64(read_idx)
	if size < 0 {
		return 0
	}
	if size > i64(N) {
		return N
	}
	return int(size)
}

mpsc_is_empty :: proc(q: ^MPSC_Queue($T, $N)) -> bool {
	pos := q.read_index
	mask := u64(N - 1)
	entry := &q.buffer[pos & mask]
	seq := sync.atomic_load_explicit(&entry.sequence, .Relaxed)
	return seq != pos + 1
}

mpsc_peek :: proc(q: ^MPSC_Queue($T, $N), data: ^T) -> bool {
	mask := u64(N - 1)
	pos := q.read_index
	entry := &q.buffer[pos & mask]
	seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

	if seq == pos + 1 {
		data^ = entry.data
		return true
	}

	return false
}
