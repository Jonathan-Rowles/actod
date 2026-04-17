package actod

import "core:fmt"
import "core:math/rand"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
global_registry_swap_mutex: sync.Mutex

CONCURRENT_THREADS :: 20
OPS_PER_THREAD :: 10000
REUSE_TEST_CYCLES :: 100
TEST_REGISTRY_SIZE :: 2048

make_test_registry :: proc() -> ^PID_Map(rawptr, PID) {
	reg := new(PID_Map(rawptr, PID))
	init_pid_map(reg, TEST_REGISTRY_SIZE, context.allocator)
	return reg
}

Test_Stats_Registry :: struct {
	adds_attempted:     u64,
	adds_successful:    u64,
	removes_attempted:  u64,
	removes_successful: u64,
	gets_attempted:     u64,
	gets_successful:    u64,
	ghost_entries:      u64,
	zombie_entries:     u64,
	validation_errors:  u64,
	race_conditions:    u64,
}

@(test)
concurrent_slot_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)

	stats := Test_Stats_Registry{}
	pid_pool: [dynamic]PID
	pool_mutex: sync.Mutex

	worker := proc(data: rawptr) {
		ctx := cast(^struct {
			id:       int,
			registry: ^PID_Map(rawptr, PID),
			stats:    ^Test_Stats_Registry,
			pool:     ^[dynamic]PID,
			mutex:    ^sync.Mutex,
		})data

		for i in 0 ..< OPS_PER_THREAD {
			op := rand.int31_max(2)

			if op == 0 {
				sync.atomic_add(&ctx.stats.adds_attempted, 1)
				test_data := rawptr(uintptr(i * 1000 + ctx.id))
				name := fmt.tprintf("actor_%d_%d", ctx.id, i)
				pid, ok := add(ctx.registry, test_data, name)

				if ok {
					sync.atomic_add(&ctx.stats.adds_successful, 1)

					retrieved, active := get(ctx.registry, pid)
					if !active || retrieved != test_data {
						sync.atomic_add(&ctx.stats.race_conditions, 1)
					}

					sync.mutex_lock(ctx.mutex)
					append(ctx.pool, pid)
					sync.mutex_unlock(ctx.mutex)
				}

			} else {
				sync.mutex_lock(ctx.mutex)
				if len(ctx.pool^) > 0 {
					idx := rand.int31_max(i32(len(ctx.pool^)))
					pid := ctx.pool[idx]
					ordered_remove(ctx.pool, int(idx))
					sync.mutex_unlock(ctx.mutex)

					sync.atomic_add(&ctx.stats.removes_attempted, 1)

					was_valid := valid(ctx.registry, pid)
					remove(ctx.registry, pid)

					if was_valid {
						sync.atomic_add(&ctx.stats.removes_successful, 1)

						_, still_active := get(ctx.registry, pid)
						if still_active {
							sync.atomic_add(&ctx.stats.race_conditions, 1)
						}
					}
				} else {
					sync.mutex_unlock(ctx.mutex)
				}
			}

			if i % 100 == 0 {
				thread.yield()
			}
		}
	}

	threads := make([]^thread.Thread, CONCURRENT_THREADS)
	thread_contexts := make([]struct {
			id:       int,
			registry: ^PID_Map(rawptr, PID),
			stats:    ^Test_Stats_Registry,
			pool:     ^[dynamic]PID,
			mutex:    ^sync.Mutex,
		}, CONCURRENT_THREADS)
	defer delete(threads)
	defer delete(thread_contexts)

	for i in 0 ..< CONCURRENT_THREADS {
		thread_contexts[i] = {
			id       = i,
			registry = test_registry,
			stats    = &stats,
			pool     = &pid_pool,
			mutex    = &pool_mutex,
		}
		threads[i] = thread.create_and_start_with_data(&thread_contexts[i], worker)
	}

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	testing.expect(t, sync.atomic_load(&stats.race_conditions) == 0)
	delete(pid_pool)
}

@(test)
rapid_reuse_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	errors := 0
	pids_seen := make(map[PID]bool)
	defer delete(pids_seen)

	for cycle in 0 ..< REUSE_TEST_CYCLES {
		batch_pids := make([dynamic]PID)
		defer delete(batch_pids)

		for i in 0 ..< 100 {
			data := rawptr(uintptr(cycle * 1000 + i))
			name := fmt.tprintf("reuse_%d_%d", cycle, i)
			pid, ok := add(test_registry, data, name)
			if ok {
				pids_seen[pid] = true
				append(&batch_pids, pid)

				retrieved, active := get(test_registry, pid)
				if !active || retrieved != data {
					errors += 1
				}
			}
		}

		for pid in batch_pids {
			remove(test_registry, pid)

			_, active := get(test_registry, pid)
			if active {
				errors += 1
			}
		}
	}

	testing.expect(t, errors == 0)
	testing.expect(t, num_used(test_registry) == 0)
}

@(test)
zombie_detection_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pids := make([dynamic]PID)
	defer delete(pids)

	for i in 0 ..< 1000 {
		data := rawptr(uintptr(i))
		name := fmt.tprintf("zombie_%d", i)
		pid, ok := add(test_registry, data, name)
		if ok {
			append(&pids, pid)
		}
	}

	for i := 0; i < len(pids); i += 2 {
		remove(test_registry, pids[i])
	}

	zombies := 0
	ghosts := 0

	for i := u32(0); i < sync.atomic_load(&test_registry.num_items); i += 1 {
		entry := &test_registry.items[i]
		seq := sync.atomic_load(&entry.sequence)
		data := entry.data

		if i == 0 {
			continue
		}

		is_active := (seq & 1) != 0

		if !is_active && data != nil {
			zombies += 1
		}

		if is_active && data == nil {
			ghosts += 1
		}
	}

	testing.expect(t, zombies == 0)
	testing.expect(t, ghosts == 0)

	manual_count := 0
	for i := u32(1); i < sync.atomic_load(&test_registry.num_items); i += 1 {
		entry := &test_registry.items[i]
		seq := sync.atomic_load(&entry.sequence)
		if (seq & 1) != 0 {
			manual_count += 1
		}
	}

	testing.expect(t, manual_count == num_used(test_registry))
}

@(test)
unused_list_integrity_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pids := make([dynamic]PID)
	defer delete(pids)

	for i in 0 ..< 100 {
		name := fmt.tprintf("unused_%d", i)
		pid, ok := add(test_registry, rawptr(uintptr(i)), name)
		if ok {
			append(&pids, pid)
		}
	}

	for pid in pids {
		remove(test_registry, pid)
	}

	next := sync.atomic_load(&test_registry.next_unused)
	visited := make(map[u32]bool)
	defer delete(visited)

	count := 0
	has_cycle := false

	for next != 0 && count < 200 {
		if next in visited {
			has_cycle = true
			break
		}

		visited[next] = true
		next = test_registry.unused_items[next]
		count += 1
	}

	testing.expect(t, !has_cycle)
	testing.expect(t, count == int(sync.atomic_load(&test_registry.num_unused)))
}

@(test)
iterator_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	expected_data := make(map[rawptr]PID)
	defer delete(expected_data)

	for i in 0 ..< 50 {
		data := rawptr(uintptr(i + 100))
		name := fmt.tprintf("iter_%d", i)
		pid, ok := add(test_registry, data, name)
		if ok {
			expected_data[data] = pid
		}
	}

	found_data := make(map[rawptr]PID)
	defer delete(found_data)

	it := make_iter(test_registry)
	for {
		data, pid, ok := iter(&it)
		if !ok {
			break
		}
		found_data[data] = pid
	}

	testing.expect(t, len(found_data) == len(expected_data))

	for data, pid in expected_data {
		found_pid, ok := found_data[data]
		testing.expect(t, ok)
		testing.expect(t, found_pid == pid)
	}
}

@(test)
capacity_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	initial_capacity := cap(test_registry)
	testing.expect(t, initial_capacity == TEST_REGISTRY_SIZE)

	successful_adds := 0
	max_attempts := TEST_REGISTRY_SIZE + 100

	for i in 0 ..< max_attempts {
		data := rawptr(uintptr(i))
		name := fmt.tprintf("cap_%d", i)
		_, ok := add(test_registry, data, name)
		if ok {
			successful_adds += 1
		}
	}

	final_capacity := cap(test_registry)
	testing.expect(
		t,
		successful_adds > TEST_REGISTRY_SIZE,
		"Registry should grow beyond initial capacity",
	)
	testing.expect(t, final_capacity > initial_capacity, "Capacity should have increased")
	testing.expect(t, successful_adds == num_used(test_registry))
}

@(test)
stress_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	STRESS_THREADS :: 32
	STRESS_OPS :: 5000

	stop_flag := false
	total_ops := u64(0)

	Thread_Context :: struct {
		registry:  ^PID_Map(rawptr, PID),
		stop:      ^bool,
		total_ops: ^u64,
		thread_id: int,
	}

	worker := proc(data: rawptr) {
		ctx := cast(^Thread_Context)data
		local_pids := make([dynamic]PID)
		defer delete(local_pids)

		for i in 0 ..< STRESS_OPS {
			if sync.atomic_load(ctx.stop) {
				break
			}

			action := rand.int31_max(100)

			if action < 60 {
				test_data := rawptr(uintptr(ctx.thread_id * 100000 + i))
				name := fmt.tprintf("stress_%d_%d", ctx.thread_id, i)
				pid, ok := add(ctx.registry, test_data, name)
				if ok {
					append(&local_pids, pid)
					sync.atomic_add(ctx.total_ops, 1)
				}
			} else if action < 80 && len(local_pids) > 0 {
				idx := rand.int31_max(i32(len(local_pids)))
				pid := local_pids[idx]
				remove(ctx.registry, pid)
				ordered_remove(&local_pids, int(idx))
				sync.atomic_add(ctx.total_ops, 1)
			} else if len(local_pids) > 0 {
				idx := rand.int31_max(i32(len(local_pids)))
				pid := local_pids[idx]
				_, ok := get(ctx.registry, pid)
				if ok {
					sync.atomic_add(ctx.total_ops, 1)
				}
			}

			if i % 100 == 0 {
				thread.yield()
			}
		}

		for pid in local_pids {
			remove(ctx.registry, pid)
		}
	}

	contexts: [STRESS_THREADS]Thread_Context
	threads: [STRESS_THREADS]^thread.Thread

	for i in 0 ..< STRESS_THREADS {
		contexts[i] = {
			registry  = test_registry,
			stop      = &stop_flag,
			total_ops = &total_ops,
			thread_id = i,
		}
		threads[i] = thread.create_and_start_with_data(&contexts[i], worker)
	}

	time.sleep(50 * time.Millisecond)
	sync.atomic_store(&stop_flag, true)

	for i in 0 ..< STRESS_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	thread.yield()

	ops := sync.atomic_load(&total_ops)
	remaining := num_used(test_registry)

	testing.expect(t, ops > 0)
	testing.expect(t, remaining <= STRESS_THREADS)
}

@(test)
name_lookup_basic_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	data := rawptr(uintptr(42))
	pid, ok := add(test_registry, data, "my_actor")
	testing.expect(t, ok)

	found_pid, found := get_by_name(test_registry, "my_actor")
	testing.expect(t, found)
	testing.expect(t, found_pid == pid)

	_, not_found := get_by_name(test_registry, "no_such_actor")
	testing.expect(t, !not_found)
}

@(test)
name_lookup_multiple_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pids := make(map[string]PID)
	defer delete(pids)

	for i in 0 ..< 50 {
		name := fmt.tprintf("actor_%d", i)
		data := rawptr(uintptr(i + 1))
		pid, ok := add(test_registry, data, name)
		if ok {
			pids[name] = pid
		}
	}

	for name, expected_pid in pids {
		found_pid, found := get_by_name(test_registry, name)
		testing.expect(t, found)
		testing.expect(t, found_pid == expected_pid)
	}
}

@(test)
name_lookup_after_remove_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pid, ok := add(test_registry, rawptr(uintptr(1)), "removable")
	testing.expect(t, ok)

	_, found := get_by_name(test_registry, "removable")
	testing.expect(t, found)

	remove(test_registry, pid)

	_, found_after := get_by_name(test_registry, "removable")
	testing.expect(t, !found_after)
}

@(test)
name_lookup_rename_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pid, ok := add(test_registry, rawptr(uintptr(1)), "old_name")
	testing.expect(t, ok)

	renamed := pid_map_rename(test_registry, pid, "new_name")
	testing.expect(t, renamed)

	_, found_old := get_by_name(test_registry, "old_name")
	testing.expect(t, !found_old)

	found_pid, found_new := get_by_name(test_registry, "new_name")
	testing.expect(t, found_new)
	testing.expect(t, found_pid == pid)
}

@(test)
name_lookup_clear_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	add(test_registry, rawptr(uintptr(1)), "actor_a")
	add(test_registry, rawptr(uintptr(2)), "actor_b")

	clear(test_registry)

	_, found_a := get_by_name(test_registry, "actor_a")
	_, found_b := get_by_name(test_registry, "actor_b")
	testing.expect(t, !found_a)
	testing.expect(t, !found_b)
}

@(test)
name_lookup_many_collisions_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pids := make(map[string]PID)
	defer delete(pids)

	for i in 0 ..< 200 {
		name := fmt.tprintf("collision_test_actor_%d", i)
		data := rawptr(uintptr(i + 1))
		pid, ok := add(test_registry, data, name)
		if ok {
			pids[name] = pid
		}
	}

	errors := 0
	for name, expected_pid in pids {
		found_pid, found := get_by_name(test_registry, name)
		if !found || found_pid != expected_pid {
			errors += 1
		}
	}
	testing.expect(t, errors == 0)
}

@(test)
add_remote_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	remote_handle := Handle {
		idx        = 5,
		gen        = 1,
		actor_type = 0,
	}
	remote_pid := pack_pid(remote_handle, Node_ID(3))

	ok, is_new := add_remote(test_registry, remote_pid, "remote_actor@node3")
	testing.expect(t, ok)
	testing.expect(t, is_new)

	found_pid, found := get_by_name(test_registry, "remote_actor@node3")
	testing.expect(t, found)
	testing.expect(t, found_pid == remote_pid)

	testing.expect(t, !is_local_pid(found_pid))
}

@(test)
add_remote_dedup_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	remote_handle := Handle {
		idx        = 5,
		gen        = 1,
		actor_type = 0,
	}
	remote_pid := pack_pid(remote_handle, Node_ID(3))

	ok1, is_new1 := add_remote(test_registry, remote_pid, "dedup_actor@node3")
	testing.expect(t, ok1)
	testing.expect(t, is_new1)

	ok2, is_new2 := add_remote(test_registry, remote_pid, "dedup_actor@node3")
	testing.expect(t, ok2)
	testing.expect(t, !is_new2)
}

@(test)
remove_remote_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	remote_handle := Handle {
		idx        = 7,
		gen        = 2,
		actor_type = 0,
	}
	remote_pid := pack_pid(remote_handle, Node_ID(4))

	add_remote(test_registry, remote_pid, "temp_remote@node4")

	_, found := get_by_name(test_registry, "temp_remote@node4")
	testing.expect(t, found)

	removed := remove_remote(test_registry, remote_pid)
	testing.expect(t, removed)

	_, found_after := get_by_name(test_registry, "temp_remote@node4")
	testing.expect(t, !found_after)
}

@(test)
remote_data_is_nil_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	remote_handle := Handle {
		idx        = 1,
		gen        = 1,
		actor_type = 0,
	}
	remote_pid := pack_pid(remote_handle, Node_ID(2))

	add_remote(test_registry, remote_pid, "nil_data@node2")

	found_pid, found := get_by_name(test_registry, "nil_data@node2")
	testing.expect(t, found)
	testing.expect(t, found_pid == remote_pid)
}

@(test)
name_lookup_add_remove_reuse_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	pid1, ok1 := add(test_registry, rawptr(uintptr(1)), "reusable")
	testing.expect(t, ok1)

	remove(test_registry, pid1)

	pid2, ok2 := add(test_registry, rawptr(uintptr(2)), "reusable")
	testing.expect(t, ok2)

	found_pid, found := get_by_name(test_registry, "reusable")
	testing.expect(t, found)
	testing.expect(t, found_pid == pid2)
	testing.expect(t, found_pid != pid1)
}

@(test)
get_node_id_local_test :: proc(t: ^testing.T) {
	handle := Handle {
		idx        = 1,
		gen        = 1,
		actor_type = 0,
	}
	pid := pack_pid(handle, current_node_id)

	testing.expect(t, get_node_id(pid) == current_node_id)
	testing.expect(t, is_local_pid(pid))
}

@(test)
get_node_id_remote_test :: proc(t: ^testing.T) {
	handle := Handle {
		idx        = 5,
		gen        = 2,
		actor_type = 0,
	}
	remote_node := Node_ID(7)
	pid := pack_pid(handle, remote_node)

	testing.expect(t, get_node_id(pid) == remote_node)
	testing.expect(t, !is_local_pid(pid))
}

@(test)
get_node_id_consistency_test :: proc(t: ^testing.T) {
	handle := Handle {
		idx        = 10,
		gen        = 3,
		actor_type = Actor_Type(2),
	}
	node := Node_ID(42)
	pid := pack_pid(handle, node)

	unpacked_handle, unpacked_node := unpack_pid(pid)
	testing.expect(t, get_node_id(pid) == unpacked_node)
	testing.expect(t, get_node_id(pid) == node)
	testing.expect(t, unpacked_handle.idx == handle.idx)
	testing.expect(t, unpacked_handle.gen == handle.gen)
}

@(test)
handle_node_disconnect_removes_remote_actors_test :: proc(t: ^testing.T) {
	sync.lock(&global_registry_swap_mutex)
	defer sync.unlock(&global_registry_swap_mutex)

	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	saved := global_registry
	global_registry = test_registry^
	defer {
		global_registry = saved
	}

	remote_node := Node_ID(5)

	for i in 0 ..< 3 {
		handle := Handle {
			idx        = u32(i + 1),
			gen        = 1,
			actor_type = 0,
		}
		pid := pack_pid(handle, remote_node)
		name := fmt.tprintf("actor_%d@node5", i)
		add_remote(&global_registry, pid, name)
	}

	other_handle := Handle {
		idx        = 10,
		gen        = 1,
		actor_type = 0,
	}
	other_pid := pack_pid(other_handle, Node_ID(6))
	add_remote(&global_registry, other_pid, "other@node6")

	_, found0 := get_by_name(&global_registry, "actor_0@node5")
	_, found1 := get_by_name(&global_registry, "actor_1@node5")
	_, found2 := get_by_name(&global_registry, "actor_2@node5")
	_, found_other := get_by_name(&global_registry, "other@node6")
	testing.expect(t, found0)
	testing.expect(t, found1)
	testing.expect(t, found2)
	testing.expect(t, found_other)

	handle_node_disconnect(remote_node)

	_, gone0 := get_by_name(&global_registry, "actor_0@node5")
	_, gone1 := get_by_name(&global_registry, "actor_1@node5")
	_, gone2 := get_by_name(&global_registry, "actor_2@node5")
	testing.expect(t, !gone0)
	testing.expect(t, !gone1)
	testing.expect(t, !gone2)

	_, still_there := get_by_name(&global_registry, "other@node6")
	testing.expect(t, still_there)
}

@(test)
handle_node_disconnect_ignores_local_node_test :: proc(t: ^testing.T) {
	handle_node_disconnect(Node_ID(0))
	handle_node_disconnect(current_node_id)
}

@(test)
handle_node_disconnect_empty_registry_test :: proc(t: ^testing.T) {
	sync.lock(&global_registry_swap_mutex)
	defer sync.unlock(&global_registry_swap_mutex)

	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	saved := global_registry
	global_registry = test_registry^
	defer {
		global_registry = saved
	}

	handle_node_disconnect(Node_ID(99))
}

@(test)
add_remote_concurrent_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	NUM_THREADS :: 8
	ENTRIES_PER_THREAD :: 10

	Thread_Context :: struct {
		registry:  ^PID_Map(rawptr, PID),
		thread_id: int,
		successes: int,
	}

	worker := proc(data: rawptr) {
		ctx := cast(^Thread_Context)data
		for i in 0 ..< ENTRIES_PER_THREAD {
			handle := Handle {
				idx        = u32(ctx.thread_id * 100 + i + 1),
				gen        = 1,
				actor_type = 0,
			}
			pid := pack_pid(handle, Node_ID(ctx.thread_id + 2))
			name := fmt.tprintf("concurrent_%d_%d@node%d", ctx.thread_id, i, ctx.thread_id + 2)
			ok, _ := add_remote(ctx.registry, pid, name)
			if ok {
				ctx.successes += 1
			}
		}
	}

	contexts: [NUM_THREADS]Thread_Context
	threads: [NUM_THREADS]^thread.Thread

	for i in 0 ..< NUM_THREADS {
		contexts[i] = Thread_Context {
			registry  = test_registry,
			thread_id = i,
		}
		threads[i] = thread.create_and_start_with_data(&contexts[i], worker)
	}

	for i in 0 ..< NUM_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	total_successes := 0
	for i in 0 ..< NUM_THREADS {
		total_successes += contexts[i].successes
	}

	testing.expect(t, total_successes == NUM_THREADS * ENTRIES_PER_THREAD)

	errors := 0
	for i in 0 ..< NUM_THREADS {
		for j in 0 ..< ENTRIES_PER_THREAD {
			name := fmt.tprintf("concurrent_%d_%d@node%d", i, j, i + 2)
			_, found := get_by_name(test_registry, name)
			if !found {
				errors += 1
			}
		}
	}
	testing.expect(t, errors == 0)
}

@(test)
add_remote_updates_stale_pid_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	old_handle := Handle {
		idx        = 5,
		gen        = 1,
		actor_type = 0,
	}
	old_pid := pack_pid(old_handle, Node_ID(3))

	ok1, is_new1 := add_remote(test_registry, old_pid, "worker@nodeC")
	testing.expect(t, ok1, "First add_remote should succeed")
	testing.expect(t, is_new1, "First add_remote should be new")

	new_handle := Handle {
		idx        = 5,
		gen        = 2,
		actor_type = 0,
	}
	new_pid := pack_pid(new_handle, Node_ID(3))

	ok2, is_new2 := add_remote(test_registry, new_pid, "worker@nodeC")
	testing.expect(t, ok2, "Second add_remote should succeed")
	testing.expect(t, !is_new2, "Second add_remote should not be new")

	found_pid, found := get_by_name(test_registry, "worker@nodeC")
	testing.expect(t, found, "Should find actor by name")
	testing.expect(t, found_pid == new_pid, "PID should be updated to new session PID")
	testing.expect(t, found_pid != old_pid, "PID should not be the stale one")
}

@(private)
DEDUP_ACTOR_NAME :: "shared_actor@nodeX"

@(private)
Concurrent_Dedup_Context :: struct {
	registry: ^PID_Map(rawptr, PID),
	pid:      PID,
	barrier:  ^sync.Barrier,
	result:   ^struct {
		ok:     bool,
		is_new: bool,
	},
}

@(test)
add_remote_concurrent_dedup_test :: proc(t: ^testing.T) {
	DEDUP_THREADS :: 8

	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	remote_handle := Handle {
		idx        = 10,
		gen        = 1,
		actor_type = 0,
	}
	remote_pid := pack_pid(remote_handle, Node_ID(5))

	barrier := sync.Barrier{}
	sync.barrier_init(&barrier, DEDUP_THREADS)

	results := make([]struct {
			ok:     bool,
			is_new: bool,
		}, DEDUP_THREADS)
	defer delete(results)

	contexts := make([]Concurrent_Dedup_Context, DEDUP_THREADS)
	defer delete(contexts)

	threads := make([]^thread.Thread, DEDUP_THREADS)
	defer delete(threads)

	for i in 0 ..< DEDUP_THREADS {
		contexts[i] = Concurrent_Dedup_Context {
			registry = test_registry,
			pid      = remote_pid,
			barrier  = &barrier,
			result   = &results[i],
		}
		threads[i] = thread.create_and_start_with_poly_data(
			&contexts[i],
			proc(ctx: ^Concurrent_Dedup_Context) {
				sync.barrier_wait(ctx.barrier)
				ok, is_new := add_remote(ctx.registry, ctx.pid, DEDUP_ACTOR_NAME)
				ctx.result.ok = ok
				ctx.result.is_new = is_new
			},
		)
	}

	for i in 0 ..< DEDUP_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	new_count := 0
	for i in 0 ..< DEDUP_THREADS {
		testing.expect(t, results[i].ok, "All add_remote calls should succeed")
		if results[i].is_new {
			new_count += 1
		}
	}
	testing.expect(t, new_count == 1, "Exactly one thread should see is_new=true")

	found_pid, found := get_by_name(test_registry, DEDUP_ACTOR_NAME)
	testing.expect(t, found, "Should find actor by name")
	testing.expect(t, found_pid == remote_pid, "PID should match")

	testing.expect(t, num_used(test_registry) == 1, "Should have exactly 1 used slot")
}

@(test)
add_remote_split_brain_full_scenario_test :: proc(t: ^testing.T) {
	test_registry := make_test_registry()
	defer free(test_registry)
	clear(test_registry)

	old_pid := pack_pid(Handle{idx = 5, gen = 1, actor_type = 0}, Node_ID(3))
	ok1, new1 := add_remote(test_registry, old_pid, "worker@nodeC")
	testing.expect(t, ok1 && new1)

	removed := remove_remote(test_registry, old_pid)
	testing.expect(t, removed, "Should remove old entry")

	new_pid := pack_pid(Handle{idx = 8, gen = 1, actor_type = 0}, Node_ID(3))
	ok2, new2 := add_remote(test_registry, new_pid, "worker@nodeC")
	testing.expect(t, ok2, "Re-registration should succeed")
	testing.expect(t, new2, "Should be treated as new after removal")

	found_pid, found := get_by_name(test_registry, "worker@nodeC")
	testing.expect(t, found, "Should find re-registered actor")
	testing.expect(t, found_pid == new_pid, "Should resolve to new session PID")

	ok3, new3 := add_remote(test_registry, old_pid, "worker@nodeC")
	testing.expect(t, ok3)
	testing.expect(t, !new3, "Stale add should not create new entry")

	found_pid2, found2 := get_by_name(test_registry, "worker@nodeC")
	testing.expect(t, found2, "Should still find actor")
	testing.expect(t, found_pid2 == old_pid || found_pid2 == new_pid, "Should have a valid PID")

	testing.expect(t, num_used(test_registry) == 1, "Should have exactly 1 used slot")
}
