package actod

import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "core:thread"

registry_clear :: proc(r: ^Name_Registry($T, $N)) {
	if !sync.atomic_load(&r.initialized) {
		return
	}

	sync.lock(&r.mtx)
	defer sync.unlock(&r.mtx)

	r.count = 0
	virtual.arena_free_all(&r.arena)
	r.hash_to_idx = make(map[u64]int, N, r.allocator)
}

Test_Registry_Value :: struct {
	id:   int,
	data: f64,
}

MAX_TEST_ENTRIES :: 64

@(test)
test_registry_register_and_get_by_name :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val := Test_Registry_Value {
		id   = 1,
		data = 3.14,
	}
	idx, is_new := registry_register(&r, "test_entry", val)

	testing.expect(t, idx >= 0, "Index should be non-negative")
	testing.expect(t, is_new, "Should be newly added")

	result, found := registry_get_by_name(&r, "test_entry")
	testing.expect(t, found, "Should find entry by name")
	testing.expect(t, result.id == 1, "ID should match")
	testing.expect(t, result.data == 3.14, "Data should match")
}

@(test)
test_registry_register_and_get_by_hash :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val := Test_Registry_Value {
		id   = 42,
		data = 2.718,
	}
	registry_register(&r, "hash_entry", val)

	hash := fnv1a_hash("hash_entry")
	result, found := registry_get_by_hash(&r, hash)
	testing.expect(t, found, "Should find entry by hash")
	testing.expect(t, result.id == 42, "ID should match")
	testing.expect(t, result.data == 2.718, "Data should match")
}

@(test)
test_registry_register_and_get_by_index :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val0 := Test_Registry_Value {
		id   = 10,
		data = 1.0,
	}
	val1 := Test_Registry_Value {
		id   = 20,
		data = 2.0,
	}
	idx0, _ := registry_register(&r, "entry_0", val0)
	idx1, _ := registry_register(&r, "entry_1", val1)

	result0, found0 := registry_get_by_index(&r, idx0)
	testing.expect(t, found0, "Should find entry 0 by index")
	testing.expect(t, result0.id == 10, "Entry 0 ID should match")

	result1, found1 := registry_get_by_index(&r, idx1)
	testing.expect(t, found1, "Should find entry 1 by index")
	testing.expect(t, result1.id == 20, "Entry 1 ID should match")

	_, found_oob := registry_get_by_index(&r, 999)
	testing.expect(t, !found_oob, "Out of bounds index should not be found")
}

@(test)
test_registry_get_name_by_hash :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val := Test_Registry_Value {
		id   = 1,
		data = 0.0,
	}
	registry_register(&r, "reverse_lookup", val)

	hash := fnv1a_hash("reverse_lookup")
	name, found := registry_get_name_by_hash(&r, hash)
	testing.expect(t, found, "Should find name by hash")
	testing.expect(t, name == "reverse_lookup", "Name should match")

	_, not_found := registry_get_name_by_hash(&r, 0xDEADBEEF)
	testing.expect(t, !not_found, "Unknown hash should not be found")
}

@(test)
test_registry_duplicate_registration :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val1 := Test_Registry_Value {
		id   = 1,
		data = 1.0,
	}
	idx1, is_new1 := registry_register(&r, "duplicate", val1)
	testing.expect(t, is_new1, "First registration should be new")

	val2 := Test_Registry_Value {
		id   = 2,
		data = 2.0,
	}
	idx2, is_new2 := registry_register(&r, "duplicate", val2)
	testing.expect(t, !is_new2, "Second registration should not be new")
	testing.expect(t, idx1 == idx2, "Should return same index")

	result, _ := registry_get_by_name(&r, "duplicate")
	testing.expect(t, result.id == 1, "Original value should be preserved")

	testing.expect(t, registry_count(&r) == 1, "Count should still be 1")
}

@(test)
test_registry_full_condition :: proc(t: ^testing.T) {
	old_logger := context.logger
	context.logger = {}
	defer {context.logger = old_logger}

	SMALL :: 4
	r: Name_Registry(Test_Registry_Value, SMALL)
	defer registry_destroy(&r)

	names := [?]string{"a", "b", "c", "d"}
	for name, i in names {
		val := Test_Registry_Value {
			id   = i,
			data = 0.0,
		}
		idx, is_new := registry_register(&r, name, val)
		testing.expect(t, idx >= 0, "Should successfully register")
		testing.expect(t, is_new, "Should be new")
	}

	testing.expect(t, registry_count(&r) == SMALL, "Should be at capacity")

	val := Test_Registry_Value {
		id   = 99,
		data = 0.0,
	}
	idx, is_new := registry_register(&r, "overflow", val)
	testing.expect(t, idx == -1, "Should return -1 when full")
	testing.expect(t, !is_new, "Should not be new when full")
}

@(test)
test_registry_clear :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val := Test_Registry_Value {
		id   = 1,
		data = 1.0,
	}
	registry_register(&r, "to_clear", val)
	testing.expect(t, registry_count(&r) == 1, "Should have 1 entry")
	testing.expect(t, registry_has(&r, "to_clear"), "Should find entry")

	registry_clear(&r)

	testing.expect(t, registry_count(&r) == 0, "Count should be 0 after clear")
	testing.expect(t, !registry_has(&r, "to_clear"), "Should not find entry after clear")

	val2 := Test_Registry_Value {
		id   = 2,
		data = 2.0,
	}
	idx, is_new := registry_register(&r, "after_clear", val2)
	testing.expect(t, idx >= 0, "Should register after clear")
	testing.expect(t, is_new, "Should be new after clear")
}

@(test)
test_registry_get_hash_and_name :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	val := Test_Registry_Value {
		id   = 5,
		data = 5.0,
	}
	idx, _ := registry_register(&r, "hash_name_test", val)

	hash, hash_ok := registry_get_hash(&r, idx)
	testing.expect(t, hash_ok, "Should get hash by index")
	testing.expect(t, hash == fnv1a_hash("hash_name_test"), "Hash should match fnv1a")

	name, name_ok := registry_get_name(&r, idx)
	testing.expect(t, name_ok, "Should get name by index")
	testing.expect(t, name == "hash_name_test", "Name should match")

	_, bad_hash := registry_get_hash(&r, -1)
	testing.expect(t, !bad_hash, "Negative index should fail")

	_, bad_name := registry_get_name(&r, 999)
	testing.expect(t, !bad_name, "Out of bounds index should fail")
}

@(test)
test_registry_has :: proc(t: ^testing.T) {
	r: Name_Registry(Test_Registry_Value, MAX_TEST_ENTRIES)
	defer registry_destroy(&r)

	testing.expect(t, !registry_has(&r, "missing"), "Should not have unregistered name")

	val := Test_Registry_Value {
		id   = 1,
		data = 0.0,
	}
	registry_register(&r, "exists", val)

	testing.expect(t, registry_has(&r, "exists"), "Should have registered name")
	testing.expect(t, !registry_has(&r, "still_missing"), "Should not have other name")
}

NAME_REG_CONCURRENT_THREADS :: 8
NAME_REG_OPS_PER_THREAD :: 30

@(test)
test_registry_concurrent_registration :: proc(t: ^testing.T) {
	r: Name_Registry(int, 256)
	defer registry_destroy(&r)

	errors: u64

	Thread_Ctx :: struct {
		registry: ^Name_Registry(int, 256),
		errors:   ^u64,
		id:       int,
	}

	worker := proc(data: rawptr) {
		ctx := cast(^Thread_Ctx)data

		buf: [64]byte
		for i in 0 ..< NAME_REG_OPS_PER_THREAD {
			n := write_thread_key(buf[:], ctx.id, i)
			name := string(buf[:n])

			idx, _ := registry_register(ctx.registry, name, ctx.id * 10000 + i)
			if idx < 0 {
				sync.atomic_add(ctx.errors, 1)
				continue
			}

			val, found := registry_get_by_name(ctx.registry, name)
			if !found || val^ != ctx.id * 10000 + i {
				if !found {
					sync.atomic_add(ctx.errors, 1)
				}
			}
		}
	}

	contexts: [NAME_REG_CONCURRENT_THREADS]Thread_Ctx
	threads: [NAME_REG_CONCURRENT_THREADS]^thread.Thread

	for i in 0 ..< NAME_REG_CONCURRENT_THREADS {
		contexts[i] = {
			registry = &r,
			errors   = &errors,
			id       = i,
		}
		threads[i] = thread.create_and_start_with_data(&contexts[i], worker)
	}

	for i in 0 ..< NAME_REG_CONCURRENT_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	testing.expect(t, sync.atomic_load(&errors) == 0, "No errors during concurrent registration")
	testing.expect(
		t,
		registry_count(&r) == NAME_REG_CONCURRENT_THREADS * NAME_REG_OPS_PER_THREAD,
		"All unique entries should be registered",
	)
}

@(test)
test_registry_concurrent_lookup_during_registration :: proc(t: ^testing.T) {
	r: Name_Registry(int, 256)
	defer registry_destroy(&r)

	buf: [64]byte
	for i in 0 ..< 50 {
		n := write_thread_key(buf[:], 0, i)
		registry_register(&r, string(buf[:n]), i)
	}

	errors: u64

	Reader_Ctx :: struct {
		registry: ^Name_Registry(int, 256),
		errors:   ^u64,
	}

	Writer_Ctx :: struct {
		registry: ^Name_Registry(int, 256),
		errors:   ^u64,
		id:       int,
	}

	reader_worker := proc(data: rawptr) {
		ctx := cast(^Reader_Ctx)data
		lbuf: [64]byte

		for _ in 0 ..< 100 {
			for i in 0 ..< 50 {
				n := write_thread_key(lbuf[:], 0, i)
				_, found := registry_get_by_name(ctx.registry, string(lbuf[:n]))
				if !found {
					sync.atomic_add(ctx.errors, 1)
				}
			}
			thread.yield()
		}
	}

	writer_worker := proc(data: rawptr) {
		ctx := cast(^Writer_Ctx)data
		lbuf: [64]byte

		for i in 50 ..< 100 {
			n := write_thread_key(lbuf[:], ctx.id, i)
			idx, _ := registry_register(ctx.registry, string(lbuf[:n]), i)
			if idx < 0 {
				sync.atomic_add(ctx.errors, 1)
			}
			thread.yield()
		}
	}

	READERS :: 4
	WRITERS :: 2
	reader_contexts: [READERS]Reader_Ctx
	writer_contexts: [WRITERS]Writer_Ctx
	reader_threads: [READERS]^thread.Thread
	writer_threads: [WRITERS]^thread.Thread

	for i in 0 ..< READERS {
		reader_contexts[i] = {
			registry = &r,
			errors   = &errors,
		}
		reader_threads[i] = thread.create_and_start_with_data(&reader_contexts[i], reader_worker)
	}

	for i in 0 ..< WRITERS {
		writer_contexts[i] = {
			registry = &r,
			errors   = &errors,
			id       = i + 1,
		}
		writer_threads[i] = thread.create_and_start_with_data(&writer_contexts[i], writer_worker)
	}

	for i in 0 ..< WRITERS {
		thread.join(writer_threads[i])
		thread.destroy(writer_threads[i])
	}

	for i in 0 ..< READERS {
		thread.join(reader_threads[i])
		thread.destroy(reader_threads[i])
	}

	testing.expect(
		t,
		sync.atomic_load(&errors) == 0,
		"No errors during concurrent lookup and registration",
	)
}

@(test)
test_fnv1a_hash_consistency :: proc(t: ^testing.T) {
	h1 := fnv1a_hash("test_string")
	h2 := fnv1a_hash("test_string")
	testing.expect(t, h1 == h2, "Same string should produce same hash")

	h3 := fnv1a_hash("different_string")
	testing.expect(t, h1 != h3, "Different strings should produce different hashes")

	h4 := fnv1a_hash("")
	testing.expect(t, h4 == 14695981039346656037, "Empty string should return FNV offset basis")
}

@(private)
write_thread_key :: proc(buf: []byte, id: int, i: int) -> int {
	n := 0
	buf[n] = 't'
	n += 1
	n += write_int(buf[n:], id)
	buf[n] = '_'
	n += 1
	n += write_int(buf[n:], i)
	return n
}

@(private)
write_int :: proc(buf: []byte, val: int) -> int {
	if val == 0 {
		buf[0] = '0'
		return 1
	}
	v := val
	if v < 0 {
		buf[0] = '-'
		v = -v
		n := 1
		digits: [20]byte
		d := 0
		for v > 0 {
			digits[d] = byte(v % 10) + '0'
			v /= 10
			d += 1
		}
		for j := d - 1; j >= 0; j -= 1 {
			buf[n] = digits[j]
			n += 1
		}
		return n
	}
	digits: [20]byte
	d := 0
	for v > 0 {
		digits[d] = byte(v % 10) + '0'
		v /= 10
		d += 1
	}
	n := 0
	for j := d - 1; j >= 0; j -= 1 {
		buf[n] = digits[j]
		n += 1
	}
	return n
}
