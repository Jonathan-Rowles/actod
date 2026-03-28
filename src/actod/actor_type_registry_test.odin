package actod

import "core:sync"
import "core:testing"
import "core:thread"

@(private)
test_actor_types_registered := false
@(private)
test_actor_type_mutex: sync.Mutex

@(private)
TEST_WORKER_TYPE: Actor_Type
@(private)
TEST_AGGREGATOR_TYPE: Actor_Type

@(private)
register_test_actor_types :: proc() {
	sync.lock(&test_actor_type_mutex)
	defer sync.unlock(&test_actor_type_mutex)

	if test_actor_types_registered {
		return
	}

	TEST_WORKER_TYPE, _ = register_actor_type("test_worker")
	TEST_AGGREGATOR_TYPE, _ = register_actor_type("test_aggregator")

	test_actor_types_registered = true
}

@(test)
test_register_actor_type :: proc(t: ^testing.T) {
	register_test_actor_types()

	testing.expect(t, TEST_WORKER_TYPE != ACTOR_TYPE_UNTYPED, "Should not be untyped")
	testing.expect(t, TEST_AGGREGATOR_TYPE != ACTOR_TYPE_UNTYPED, "Should not be untyped")
	testing.expect(t, TEST_AGGREGATOR_TYPE != TEST_WORKER_TYPE, "Types should be different")
}

@(test)
test_register_actor_type_duplicate :: proc(t: ^testing.T) {
	register_test_actor_types()

	second, ok := register_actor_type("test_worker")
	testing.expect(t, ok, "Duplicate registration should succeed")
	testing.expect(t, second == TEST_WORKER_TYPE, "Duplicate should return same ID")
}

@(test)
test_get_actor_type_name :: proc(t: ^testing.T) {
	register_test_actor_types()

	name, found := get_actor_type_name(TEST_WORKER_TYPE)
	testing.expect(t, found, "Should find registered type name")
	testing.expect(t, name == "test_worker", "Name should match")

	_, not_found := get_actor_type_name(Actor_Type(99))
	testing.expect(t, !not_found, "Should not find unregistered type")
}

@(test)
test_get_actor_type_by_name :: proc(t: ^testing.T) {
	register_test_actor_types()

	got, found := get_actor_type_by_name("test_aggregator")
	testing.expect(t, found)
	testing.expect(t, got == TEST_AGGREGATOR_TYPE, "Type ID should match")

	_, not_found := get_actor_type_by_name("nonexistent")
	testing.expect(t, !not_found, "Should not find unregistered name")
}

@(test)
test_actor_type_hash_consistency :: proc(t: ^testing.T) {
	register_test_actor_types()

	hash1, ok1 := get_actor_type_hash(TEST_WORKER_TYPE)
	hash2, ok2 := get_actor_type_hash(TEST_WORKER_TYPE)
	testing.expect(t, ok1 && ok2, "Should find hash")
	testing.expect(t, hash1 == hash2, "Same type should produce same hash")
	testing.expect(t, hash1 == fnv1a_hash("test_worker"), "Hash should match name hash")
}

@(test)
test_actor_type_by_hash :: proc(t: ^testing.T) {
	register_test_actor_types()

	hash, hash_ok := get_actor_type_hash(TEST_WORKER_TYPE)
	testing.expect(t, hash_ok, "Should find hash for registered type")

	got, found := get_actor_type_by_hash(hash)
	testing.expect(t, found, "Should find type by hash")
	testing.expect(t, got == TEST_WORKER_TYPE, "Type should match")

	_, not_found := get_actor_type_by_hash(12345)
	testing.expect(t, !not_found, "Should not find unknown hash")
}

@(test)
test_actor_type_registry_concurrent :: proc(t: ^testing.T) {
	NUM_THREADS :: 8

	Thread_Context :: struct {
		thread_id: int,
		results:   [2]Actor_Type,
		ok:        [2]bool,
	}

	worker := proc(data: rawptr) {
		ctx := cast(^Thread_Context)data
		ctx.results[0], ctx.ok[0] = register_actor_type("concurrent_type_a")
		ctx.results[1], ctx.ok[1] = register_actor_type("concurrent_type_b")
	}

	contexts: [NUM_THREADS]Thread_Context
	threads: [NUM_THREADS]^thread.Thread

	for i in 0 ..< NUM_THREADS {
		contexts[i] = Thread_Context {
			thread_id = i,
		}
		threads[i] = thread.create_and_start_with_data(&contexts[i], worker)
	}

	for i in 0 ..< NUM_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	for i in 1 ..< NUM_THREADS {
		testing.expect(
			t,
			contexts[i].ok[0] && contexts[i].ok[1],
			"All registrations should succeed",
		)
		testing.expect(
			t,
			contexts[i].results[0] == contexts[0].results[0],
			"All threads should get same ID for type a",
		)
		testing.expect(
			t,
			contexts[i].results[1] == contexts[0].results[1],
			"All threads should get same ID for type b",
		)
	}

	testing.expect(
		t,
		contexts[0].results[0] != contexts[0].results[1],
		"Type a and type b should have different IDs",
	)
}
