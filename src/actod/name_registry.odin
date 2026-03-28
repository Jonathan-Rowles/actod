package actod

import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"

Registry_Entry :: struct($T: typeid) {
	name:      string,
	name_hash: u64,
	value:     T,
}

Name_Registry :: struct($T: typeid, $MAX_ENTRIES: int) {
	mtx:         sync.RW_Mutex,
	entries:     [MAX_ENTRIES]Registry_Entry(T),
	count:       int,
	hash_to_idx: map[u64]int,
	arena:       vmem.Arena,
	allocator:   mem.Allocator,
	initialized: bool,
}

fnv1a_hash :: #force_inline proc(s: string) -> u64 {
	hash: u64 = 14695981039346656037
	for b in s {
		hash ~= u64(b)
		hash *= 1099511628211
	}
	return hash
}

registry_verify_no_collision :: #force_inline proc(
	r: ^Name_Registry($T, $N),
	idx: int,
	name: string,
	name_hash: u64,
) {
	if r.entries[idx].name != name {
		log.panicf(
			"FATAL: Hash collision '%s' and '%s' both hash to %x",
			name,
			r.entries[idx].name,
			name_hash,
		)
	}
}

registry_ensure_init :: proc(r: ^Name_Registry($T, $N)) {
	if sync.atomic_load(&r.initialized) {
		return
	}

	sync.lock(&r.mtx)
	defer sync.unlock(&r.mtx)

	if sync.atomic_load(&r.initialized) {
		return
	}

	arena_err := vmem.arena_init_static(&r.arena)
	if arena_err != nil {
		log.panic("Failed to initialize registry arena")
	}

	r.allocator = vmem.arena_allocator(&r.arena)
	r.hash_to_idx = make(map[u64]int, N, r.allocator)
	sync.atomic_store(&r.initialized, true)
}

registry_register :: proc(r: ^Name_Registry($T, $N), name: string, value: T) -> (int, bool) {
	registry_ensure_init(r)

	name_hash := fnv1a_hash(name)

	sync.shared_lock(&r.mtx)
	if idx, exists := r.hash_to_idx[name_hash]; exists {
		registry_verify_no_collision(r, idx, name, name_hash)
		sync.shared_unlock(&r.mtx)
		return idx, false
	}
	sync.shared_unlock(&r.mtx)

	sync.lock(&r.mtx)
	defer sync.unlock(&r.mtx)

	if idx, exists := r.hash_to_idx[name_hash]; exists {
		registry_verify_no_collision(r, idx, name, name_hash)
		return idx, false
	}

	if r.count >= N {
		log.warnf("Registry full, cannot register '%s'", name)
		return -1, false
	}

	idx := r.count
	r.entries[idx] = Registry_Entry(T) {
		name      = strings.clone(name, r.allocator),
		name_hash = name_hash,
		value     = value,
	}

	r.hash_to_idx[name_hash] = idx
	r.count += 1

	return idx, true
}

registry_get_by_name :: proc(r: ^Name_Registry($T, $N), name: string) -> (^T, bool) {
	registry_ensure_init(r)

	name_hash := fnv1a_hash(name)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	if idx, exists := r.hash_to_idx[name_hash]; exists {
		return &r.entries[idx].value, true
	}
	return nil, false
}

registry_get_by_hash :: proc(r: ^Name_Registry($T, $N), hash: u64) -> (^T, bool) {
	registry_ensure_init(r)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	if idx, exists := r.hash_to_idx[hash]; exists {
		return &r.entries[idx].value, true
	}
	return nil, false
}

registry_get_by_index :: proc(r: ^Name_Registry($T, $N), idx: int) -> (^T, bool) {
	registry_ensure_init(r)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	if idx < 0 || idx >= r.count {
		return nil, false
	}
	return &r.entries[idx].value, true
}

registry_get_hash :: proc(r: ^Name_Registry($T, $N), idx: int) -> (u64, bool) {
	registry_ensure_init(r)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	if idx < 0 || idx >= r.count {
		return 0, false
	}
	return r.entries[idx].name_hash, true
}

registry_get_name :: proc(r: ^Name_Registry($T, $N), idx: int) -> (string, bool) {
	registry_ensure_init(r)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	if idx < 0 || idx >= r.count {
		return "", false
	}
	return r.entries[idx].name, true
}

registry_get_name_by_hash :: proc(r: ^Name_Registry($T, $N), hash: u64) -> (string, bool) {
	registry_ensure_init(r)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	if idx, exists := r.hash_to_idx[hash]; exists {
		return r.entries[idx].name, true
	}
	return "", false
}

registry_has :: proc(r: ^Name_Registry($T, $N), name: string) -> bool {
	registry_ensure_init(r)

	name_hash := fnv1a_hash(name)

	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)

	_, exists := r.hash_to_idx[name_hash]
	return exists
}

registry_count :: proc(r: ^Name_Registry($T, $N)) -> int {
	sync.shared_lock(&r.mtx)
	defer sync.shared_unlock(&r.mtx)
	return r.count
}


registry_destroy :: proc(r: ^Name_Registry($T, $N)) {
	if !sync.atomic_load(&r.initialized) {
		return
	}
	vmem.arena_destroy(&r.arena)
	sync.atomic_store(&r.initialized, false)
}
