package mpmc

import "base:intrinsics"
import "core:sync"

// Might have this as config multi actors single q???
MPMC_Queue :: struct($T: typeid, $N: int) where N > 0 && (N & (N - 1)) == 0 {
	_pad0:       [64]byte,
	write_index: u64,
	_pad1:       [64]byte,
	read_index:  u64,
	_pad2:       [64]byte,
	buffer:      [N]Entry(T),
}

CACHE_LINE_SIZE :: 64

Entry :: struct($T: typeid) {
	sequence: u64,
	data:     T,
	_padding: [CACHE_LINE_SIZE - size_of(u64) - size_of(T)]byte,
}

mpmc_init :: proc(q: ^MPMC_Queue($T, $N)) {
	q.write_index = 0
	q.read_index = 0

	for i in 0 ..< N {
		q.buffer[i].sequence = u64(i)
	}

	sync.atomic_thread_fence(.Release)
}

mpmc_push :: proc(q: ^MPMC_Queue($T, $N), data: T) -> bool {
	mask := u64(N - 1)
	backoff := 1

	for {
		pos := sync.atomic_load_explicit(&q.write_index, .Relaxed)

		entry := &q.buffer[pos & mask]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		diff := i64(seq) - i64(pos)

		if diff == 0 {
			_, ok := sync.atomic_compare_exchange_weak_explicit(
				&q.write_index,
				pos,
				pos + 1,
				.Relaxed,
				.Relaxed,
			)

			if ok {
				entry.data = data

				sync.atomic_store_explicit(&entry.sequence, pos + 1, .Release)
				return true
			}
			backoff = 1

		} else if diff < 0 {
			return false

		} else {
			for i := 0; i < backoff; i += 1 {
				intrinsics.cpu_relax()
			}
			backoff = min(backoff * 2, 32)
		}
	}
}

mpmc_pop :: proc(q: ^MPMC_Queue($T, $N), data: ^T) -> bool {
	mask := u64(N - 1)
	backoff := 1

	for {
		pos := sync.atomic_load_explicit(&q.read_index, .Relaxed)

		entry := &q.buffer[pos & mask]

		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)

		diff := i64(seq) - i64(pos + 1)

		if diff == 0 {
			_, ok := sync.atomic_compare_exchange_weak_explicit(
				&q.read_index,
				pos,
				pos + 1,
				.Relaxed,
				.Relaxed,
			)

			if ok {
				data^ = entry.data

				sync.atomic_store_explicit(&entry.sequence, pos + u64(N), .Release)
				return true
			}
			backoff = 1

		} else if diff < 0 {
			return false

		} else {
			for i := 0; i < backoff; i += 1 {
				intrinsics.cpu_relax()
			}
			backoff = min(backoff * 2, 32)
		}
	}
}

mpmc_try_push :: proc(q: ^MPMC_Queue($T, $N), data: T, max_spins: int = 100) -> bool {
	mask := u64(N - 1)

	for spin := 0; spin < max_spins; spin += 1 {
		pos := sync.atomic_load_explicit(&q.write_index, .Relaxed)
		entry := &q.buffer[pos & mask]
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		diff := i64(seq) - i64(pos)

		if diff == 0 {
			_, ok := sync.atomic_compare_exchange_weak_explicit(
				&q.write_index,
				pos,
				pos + 1,
				.Relaxed,
				.Relaxed,
			)

			if ok {
				entry.data = data
				sync.atomic_store_explicit(&entry.sequence, pos + 1, .Release)
				return true
			}
		} else if diff < 0 {
			intrinsics.cpu_relax()
		}
	}

	return false
}

mpmc_try_pop :: proc(q: ^MPMC_Queue($T, $N), data: ^T, max_spins: int = 100) -> bool {
	mask := u64(N - 1)

	for spin := 0; spin < max_spins; spin += 1 {
		pos := sync.atomic_load_explicit(&q.read_index, .Relaxed)
		entry := &q.buffer[pos & mask]
		seq := sync.atomic_load_explicit(&entry.sequence, .Acquire)
		diff := i64(seq) - i64(pos + 1)

		if diff == 0 {
			_, ok := sync.atomic_compare_exchange_weak_explicit(
				&q.read_index,
				pos,
				pos + 1,
				.Relaxed,
				.Relaxed,
			)

			if ok {
				data^ = entry.data
				sync.atomic_store_explicit(&entry.sequence, pos + u64(N), .Release)
				return true
			}
		} else if diff < 0 {
			intrinsics.cpu_relax()
		}
	}

	return false
}

mpmc_size :: proc(q: ^MPMC_Queue($T, $N)) -> int {
	write_idx := sync.atomic_load_explicit(&q.write_index, .Relaxed)
	read_idx := sync.atomic_load_explicit(&q.read_index, .Relaxed)

	size := i64(write_idx) - i64(read_idx)
	if size < 0 {
		return 0
	}
	if size > i64(N) {
		return N
	}
	return int(size)
}

mpmc_is_empty :: proc(q: ^MPMC_Queue($T, $N)) -> bool {
	return mpmc_size(q) == 0
}
