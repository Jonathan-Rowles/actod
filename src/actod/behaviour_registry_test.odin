package actod

import "core:sync"
import "core:testing"

@(private)
test_spawn_funcs_registered := false
@(private)
test_spawn_func_mutex: sync.Mutex

@(private)
test_spawn_func_a :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	return 1, true
}

@(private)
test_spawn_func_b :: proc(name: string, parent_pid: PID) -> (PID, bool) {
	return 2, true
}

@(private)
register_test_spawn_funcs :: proc() {
	sync.lock(&test_spawn_func_mutex)
	defer sync.unlock(&test_spawn_func_mutex)

	if test_spawn_funcs_registered {
		return
	}

	register_spawn_func("test_spawn_a", test_spawn_func_a)
	register_spawn_func("test_spawn_b", test_spawn_func_b)

	test_spawn_funcs_registered = true
}

@(test)
test_register_and_get_spawn_func :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	func, found := get_spawn_func("test_spawn_a")
	testing.expect(t, found, "Should find registered spawn function")
	testing.expect(t, func != nil, "Spawn function should not be nil")
}

@(test)
test_register_spawn_func_duplicate :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	ok := register_spawn_func("test_spawn_a", test_spawn_func_a)
	testing.expect(t, ok, "Duplicate registration should succeed (returns existing index)")
}

@(test)
test_get_nonexistent_spawn_func :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	_, found := get_spawn_func("does_not_exist")
	testing.expect(t, !found, "Should not find unregistered spawn function")
}

@(test)
test_has_spawn_func :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	testing.expect(t, has_spawn_func("test_spawn_a"), "Should find registered function")
	testing.expect(t, !has_spawn_func("test_missing"), "Should not find unregistered function")
}

@(test)
test_get_spawn_func_hash_value :: proc(t: ^testing.T) {
	hash := get_spawn_func_hash("worker")
	expected := fnv1a_hash("worker")
	testing.expect(t, hash == expected, "Hash should match fnv1a_hash")
}

@(test)
test_get_spawn_func_by_hash :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	hash := get_spawn_func_hash("test_spawn_a")

	func, found := get_spawn_func_by_hash(hash)
	testing.expect(t, found, "Should find spawn function by hash")
	testing.expect(t, func != nil, "Function should not be nil")

	_, not_found := get_spawn_func_by_hash(12345)
	testing.expect(t, !not_found, "Should not find unknown hash")
}

@(test)
test_get_spawn_func_name_by_hash :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	hash := get_spawn_func_hash("test_spawn_b")

	name, found := get_spawn_func_name_by_hash(hash)
	testing.expect(t, found, "Should find name by hash")
	testing.expect(t, name == "test_spawn_b", "Name should match")

	_, not_found := get_spawn_func_name_by_hash(99999)
	testing.expect(t, !not_found, "Should not find unknown hash")
}

@(test)
test_get_registered_spawn_funcs :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	names := get_registered_spawn_funcs()
	defer delete(names)

	testing.expect(t, len(names) >= 2, "Should have at least 2 registered functions")

	found_a := false
	found_b := false
	for name in names {
		if name == "test_spawn_a" do found_a = true
		if name == "test_spawn_b" do found_b = true
	}
	testing.expect(t, found_a, "Should contain test_spawn_a")
	testing.expect(t, found_b, "Should contain test_spawn_b")
}

@(test)
test_spawn_by_name_invalid :: proc(t: ^testing.T) {
	register_test_spawn_funcs()

	old_logger := context.logger
	context.logger = {}
	defer {context.logger = old_logger}

	pid, ok := spawn_by_name("nonexistent", "actor_name")
	testing.expect(t, !ok, "spawn_by_name with invalid function should fail")
	testing.expect(t, pid == 0, "PID should be 0 on failure")
}
