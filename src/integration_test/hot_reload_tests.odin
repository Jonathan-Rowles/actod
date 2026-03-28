package integration

import "../actod"
import "../pkgs/hot_reload"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

HR_Counter_State :: struct {
	count: i32,
}

HR_TEST_SRC_DIR :: "src/pkgs/hot_reload/mocks"

@(private)
hr_build_counter: u64

hr_build_test_module :: proc(name: string) -> (so_path: string, tmp_dir: string, ok: bool) {
	uid := sync.atomic_add(&hr_build_counter, 1)
	sys_tmp, _ := os.temp_directory(context.temp_allocator)
	tmp, _ := filepath.join({sys_tmp, fmt.tprintf("actod_hr_integration_%d", uid)}, context.temp_allocator)
	os.make_directory(tmp)

	src, _ := filepath.join({HR_TEST_SRC_DIR, name}, context.temp_allocator)
	out, _ := filepath.join({tmp, fmt.tprintf("%s%s", name, hot_reload.SHARED_LIB_EXT)}, context.temp_allocator)

	result := hot_reload.compile_module(src, out)
	if !result.ok {
		return "", tmp, false
	}
	return out, tmp, true
}

hr_handle_message_v1 :: proc(data: ^HR_Counter_State, from: actod.PID, content: any) {
	data.count += 1
}

hr_init :: proc(data: ^HR_Counter_State) {
	data.count = 0
}

HR_V1_Behaviour :: actod.Actor_Behaviour(HR_Counter_State) {
	handle_message = hr_handle_message_v1,
	init           = hr_init,
}

hr_read_count :: proc(pid: actod.PID) -> (i32, bool) {
	actor_ptr, active := actod.get(&actod.global_registry, pid)
	if !active || actor_ptr == nil {
		return 0, false
	}

	data_ptr := cast(^rawptr)(uintptr(actor_ptr) + offset_of(actod.Actor(int), data))
	if data_ptr^ == nil {
		return 0, false
	}
	state := cast(^HR_Counter_State)data_ptr^
	return state.count, true
}

hr_wait_for_count :: proc(pid: actod.PID, expected: i32, max_ms: int = 500) -> bool {
	for _ in 0 ..< max_ms / 5 {
		count, ok := hr_read_count(pid)
		if ok && count >= expected {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

test_hot_reload_basic :: proc(t: ^testing.T) {
	pid, spawned := actod.spawn("hr-counter", HR_Counter_State{}, HR_V1_Behaviour)
	testing.expect(t, spawned, "Failed to spawn counter actor")
	if !spawned do return

	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	time.sleep(10 * time.Millisecond)

	for _ in 0 ..< 3 {
		err := actod.send_message(pid, "tick")
		testing.expect(t, err == .OK, "Failed to send message")
	}

	testing.expect(t, hr_wait_for_count(pid, 3), "v1 should have incremented to 3")

	v2_path, tmp, built := hr_build_test_module("counter_v2")
	defer os.remove_all(tmp)
	testing.expect(t, built, "Failed to build counter_v2.so")
	if !built do return

	specs := []hot_reload.Symbol_Spec{{name = "handle_message", required = true}}
	mod, load_err := hot_reload.load_module(
		v2_path,
		specs,
		size_of(HR_Counter_State),
		generation = 1,
	)
	testing.expect_value(t, load_err.kind, hot_reload.Load_Error_Kind.None)
	if mod == nil do return
	defer hot_reload.unload_module(mod)

	actod.hot_module_table[1] = mod
	defer delete_key(&actod.hot_module_table, 1)

	reload_err := actod.send_reload_behaviour(pid, 1)
	testing.expect(t, reload_err == .OK, "Failed to send reload")

	time.sleep(20 * time.Millisecond)

	for _ in 0 ..< 2 {
		err := actod.send_message(pid, "tick")
		testing.expect(t, err == .OK, "Failed to send message after reload")
	}

	testing.expect(t, hr_wait_for_count(pid, 23), "v2 should have incremented to 23")

	count, ok := hr_read_count(pid)
	testing.expect(t, ok, "should be able to read count")
	testing.expect_value(t, count, i32(23))
}

test_hot_reload_state_preserved :: proc(t: ^testing.T) {
	pid, spawned := actod.spawn("hr-state-test", HR_Counter_State{}, HR_V1_Behaviour)
	testing.expect(t, spawned, "Failed to spawn counter actor")
	if !spawned do return

	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	time.sleep(10 * time.Millisecond)

	for _ in 0 ..< 5 {
		actod.send_message(pid, "tick")
	}
	testing.expect(t, hr_wait_for_count(pid, 5), "should reach 5")

	v2_path, tmp, built := hr_build_test_module("counter_v2")
	defer os.remove_all(tmp)
	if !built {
		testing.expect(t, false, "Failed to build counter_v2.so")
		return
	}

	specs := []hot_reload.Symbol_Spec{{name = "handle_message", required = true}}
	mod, load_err := hot_reload.load_module(
		v2_path,
		specs,
		size_of(HR_Counter_State),
		generation = 2,
	)
	testing.expect_value(t, load_err.kind, hot_reload.Load_Error_Kind.None)
	if mod == nil do return
	defer hot_reload.unload_module(mod)

	actod.hot_module_table[2] = mod
	defer delete_key(&actod.hot_module_table, 2)

	actod.send_reload_behaviour(pid, 2)
	time.sleep(20 * time.Millisecond)

	count_before, ok := hr_read_count(pid)
	testing.expect(t, ok, "should be able to read count")
	testing.expect_value(t, count_before, i32(5))

	actod.send_message(pid, "tick")
	testing.expect(t, hr_wait_for_count(pid, 15), "should be 5 + 10 = 15")
}

test_reload_behaviour_system_msg :: proc(t: ^testing.T) {
	pid, spawned := actod.spawn("hr-ptr-test", HR_Counter_State{}, HR_V1_Behaviour)
	testing.expect(t, spawned, "Failed to spawn")
	if !spawned do return

	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	time.sleep(10 * time.Millisecond)

	actor_ptr, active := actod.get(&actod.global_registry, pid)
	testing.expect(t, active, "actor should be active")
	if !active do return

	behaviour_offset := offset_of(actod.Actor(int), behaviour)
	handle_msg_ptr_before := (cast(^rawptr)(uintptr(actor_ptr) + behaviour_offset))^

	v2_path, tmp, built := hr_build_test_module("counter_v2")
	defer os.remove_all(tmp)
	if !built {
		testing.expect(t, false, "Failed to build counter_v2.so")
		return
	}

	specs := []hot_reload.Symbol_Spec{{name = "handle_message", required = true}}
	mod, load_err := hot_reload.load_module(
		v2_path,
		specs,
		size_of(HR_Counter_State),
		generation = 3,
	)
	testing.expect_value(t, load_err.kind, hot_reload.Load_Error_Kind.None)
	if mod == nil do return
	defer hot_reload.unload_module(mod)

	actod.hot_module_table[3] = mod
	defer delete_key(&actod.hot_module_table, 3)

	actod.send_reload_behaviour(pid, 3)
	time.sleep(20 * time.Millisecond)

	handle_msg_ptr_after := (cast(^rawptr)(uintptr(actor_ptr) + behaviour_offset))^
	testing.expect(
		t,
		handle_msg_ptr_before != handle_msg_ptr_after,
		"handle_message pointer should change after reload",
	)
}

test_rollback :: proc(t: ^testing.T) {
	pid, spawned := actod.spawn("hr-rollback-test", HR_Counter_State{}, HR_V1_Behaviour)
	testing.expect(t, spawned, "Failed to spawn")
	if !spawned do return

	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	time.sleep(10 * time.Millisecond)

	v1_path, tmp1, v1_built := hr_build_test_module("counter_v1")
	defer os.remove_all(tmp1)
	if !v1_built {
		testing.expect(t, false, "Failed to build counter_v1.so")
		return
	}

	v2_path, tmp2, v2_built := hr_build_test_module("counter_v2")
	defer os.remove_all(tmp2)
	if !v2_built {
		testing.expect(t, false, "Failed to build counter_v2.so")
		return
	}

	specs := []hot_reload.Symbol_Spec{{name = "handle_message", required = true}}

	v1_mod, v1_err := hot_reload.load_module(
		v1_path,
		specs,
		size_of(HR_Counter_State),
		generation = 4,
	)
	testing.expect_value(t, v1_err.kind, hot_reload.Load_Error_Kind.None)
	if v1_mod == nil do return
	defer hot_reload.unload_module(v1_mod)

	v2_mod, v2_err := hot_reload.load_module(
		v2_path,
		specs,
		size_of(HR_Counter_State),
		generation = 5,
	)
	testing.expect_value(t, v2_err.kind, hot_reload.Load_Error_Kind.None)
	if v2_mod == nil do return
	defer hot_reload.unload_module(v2_mod)

	actod.hot_module_table[4] = v1_mod
	actod.hot_module_table[5] = v2_mod
	defer delete_key(&actod.hot_module_table, 4)
	defer delete_key(&actod.hot_module_table, 5)

	for _ in 0 ..< 2 {
		actod.send_message(pid, "tick")
	}
	testing.expect(t, hr_wait_for_count(pid, 2), "should reach 2")

	actod.send_reload_behaviour(pid, 5)
	time.sleep(20 * time.Millisecond)

	actod.send_message(pid, "tick")
	testing.expect(t, hr_wait_for_count(pid, 12), "v2 should reach 12")

	actod.send_reload_behaviour(pid, 4)
	time.sleep(20 * time.Millisecond)

	actod.send_message(pid, "tick")
	testing.expect(t, hr_wait_for_count(pid, 13), "after rollback should increment by 1 to 13")

	count, ok := hr_read_count(pid)
	testing.expect(t, ok, "should read count")
	testing.expect_value(t, count, i32(13))
}


test_file_watcher_detection :: proc(t: ^testing.T) {
	uid := sync.atomic_add(&hr_build_counter, 1)
	sys_tmp, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({sys_tmp, fmt.tprintf("actod_test_file_watcher_%d", uid)}, context.temp_allocator)
	os.make_directory(dir)
	defer os.remove_all(dir)

	callback_fired: bool
	callback_name: [64]u8
	callback_name_len: int

	Cb_Data :: struct {
		fired:    ^bool,
		name:     ^[64]u8,
		name_len: ^int,
	}

	cb :: proc(event: hot_reload.Watch_Event, user_data: rawptr) {
		data := cast(^Cb_Data)user_data
		sync.atomic_store_explicit(data.fired, true, .Release)
		name_len := min(len(event.actor_name), 64)
		for i in 0 ..< name_len {
			data.name[i] = event.actor_name[i]
		}
		data.name_len^ = name_len
	}

	cb_data := Cb_Data {
		fired    = &callback_fired,
		name     = &callback_name,
		name_len = &callback_name_len,
	}

	w, ok := hot_reload.create_watcher(cb, &cb_data, debounce_ms = 10)
	testing.expect(t, ok, "should create watcher")
	if !ok do return
	defer hot_reload.destroy_watcher(w)

	testing.expect(t, hot_reload.add_watch(w, dir, "test_actor"), "should add watch")
	hot_reload.start_watcher(w)
	time.sleep(50 * time.Millisecond)

	test_file, _ := filepath.join({dir, "test.odin"}, context.temp_allocator)
	_ = os.write_entire_file(test_file, transmute([]u8)string("package test\n"))

	detected := false
	for _ in 0 ..< 50 {
		if sync.atomic_load_explicit(&callback_fired, .Acquire) {
			detected = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}

	testing.expect(t, detected, "callback should fire on .odin file change")
	if detected {
		name := string(callback_name[:callback_name_len])
		testing.expect_value(t, name, "test_actor")
	}
}

test_file_watcher_excludes_tmp :: proc(t: ^testing.T) {
	uid := sync.atomic_add(&hr_build_counter, 1)
	sys_tmp2, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({sys_tmp2, fmt.tprintf("actod_test_file_watcher_tmp_%d", uid)}, context.temp_allocator)
	tmp_dir, _ := filepath.join({dir, "tmp"}, context.temp_allocator)
	os.make_directory(dir)
	os.make_directory(tmp_dir)
	defer os.remove_all(dir)

	callback_fired: bool

	cb :: proc(event: hot_reload.Watch_Event, user_data: rawptr) {
		fired := cast(^bool)user_data
		sync.atomic_store_explicit(fired, true, .Release)
	}

	w, ok := hot_reload.create_watcher(cb, &callback_fired, debounce_ms = 10)
	testing.expect(t, ok, "should create watcher")
	if !ok do return
	defer hot_reload.destroy_watcher(w)

	testing.expect(t, hot_reload.add_watch(w, dir, "test_actor"), "should add watch")
	hot_reload.start_watcher(w)
	time.sleep(50 * time.Millisecond)

	txt_file, _ := filepath.join({dir, "notes.txt"}, context.temp_allocator)
	_ = os.write_entire_file(txt_file, transmute([]u8)string("hello\n"))

	time.sleep(200 * time.Millisecond)
	testing.expect(
		t,
		!sync.atomic_load_explicit(&callback_fired, .Acquire),
		"callback should NOT fire for non-.odin files",
	)
}

test_hot_reload_under_load :: proc(t: ^testing.T) {
	pid, spawned := actod.spawn("hr-load-test", HR_Counter_State{}, HR_V1_Behaviour)
	testing.expect(t, spawned, "Failed to spawn counter actor")
	if !spawned do return

	defer {
		actod.terminate_actor(pid)
		actod.wait_for_pids([]actod.PID{pid})
	}

	time.sleep(10 * time.Millisecond)

	done: bool
	msg_count: i32

	sender_thread :: proc(data: rawptr) {
		ctx := cast(^struct {
			pid:   actod.PID,
			done:  ^bool,
			count: ^i32,
		})data
		for !sync.atomic_load_explicit(ctx.done, .Acquire) {
			err := actod.send_message(ctx.pid, "tick")
			if err == .OK {
				sync.atomic_add(ctx.count, 1)
			}
			time.sleep(1 * time.Millisecond)
		}
	}

	Sender_Ctx :: struct {
		pid:   actod.PID,
		done:  ^bool,
		count: ^i32,
	}
	sender_ctx := Sender_Ctx {
		pid   = pid,
		done  = &done,
		count = &msg_count,
	}

	sender := thread.create_and_start_with_data(&sender_ctx, sender_thread)

	time.sleep(20 * time.Millisecond)

	v2_path, tmp, built := hr_build_test_module("counter_v2")
	defer os.remove_all(tmp)
	if !built {
		sync.atomic_store_explicit(&done, true, .Release)
		thread.join(sender)
		thread.destroy(sender)
		testing.expect(t, false, "Failed to build counter_v2.so")
		return
	}

	specs := []hot_reload.Symbol_Spec{{name = "handle_message", required = true}}
	mod, load_err := hot_reload.load_module(
		v2_path,
		specs,
		size_of(HR_Counter_State),
		generation = 100,
	)
	if load_err.kind != .None {
		sync.atomic_store_explicit(&done, true, .Release)
		thread.join(sender)
		thread.destroy(sender)
		testing.expect(t, false, "Failed to load module")
		return
	}
	defer hot_reload.unload_module(mod)

	actod.hot_module_table[100] = mod
	defer delete_key(&actod.hot_module_table, 100)

	actod.send_reload_behaviour(pid, 100)
	time.sleep(50 * time.Millisecond)

	sync.atomic_store_explicit(&done, true, .Release)
	thread.join(sender)
	thread.destroy(sender)

	count_before, ok := hr_read_count(pid)
	testing.expect(t, ok, "should read count")
	testing.expect(t, count_before > 0, "should have processed messages")

	actod.send_message(pid, "tick")
	time.sleep(20 * time.Millisecond)

	count_after, ok2 := hr_read_count(pid)
	testing.expect(t, ok2, "should read count after")
	testing.expect_value(t, count_after, count_before + 10)
}
