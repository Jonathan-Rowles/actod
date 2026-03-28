package ti

import "core:mem"
_ :: mem
import "core:time"

Send_Error :: enum {
	OK = 0,
	ACTOR_NOT_FOUND,
	MAILBOX_FULL,
	POOL_FULL,
	SYSTEM_SHUTTING_DOWN,
	NETWORK_ERROR,
	NETWORK_RING_FULL, // Ring buffer backpressure
	NODE_NOT_FOUND,
	NODE_DISCONNECTED,
}

Message_Priority :: enum u8 {
	HIGH   = 0,
	NORMAL = 1,
	LOW    = 2,
}

Termination_Reason :: enum {
	NORMAL,
	ABNORMAL,
	SHUTDOWN,
}

@(thread_local)
test_intercept: ^Test_Intercept

Test_Intercept :: struct {
	send_capture:            ^[dynamic]Captured_Send,
	publish_capture:         ^[dynamic]Captured_Publish,
	pid_registry:            ^map[string]u64,
	self_pid:                u64,
	self_name:               string,
	timer_capture:           ^[dynamic]Captured_Timer,
	next_timer_id:           u32,
	spawn_capture:           ^[dynamic]Captured_Spawn,
	terminate_capture:       ^[dynamic]Captured_Terminate,
	broadcast_capture:       ^[dynamic]Captured_Broadcast,
	rename_capture:          ^[dynamic]Captured_Rename,
	subscribe_capture:       ^[dynamic]Captured_Subscribe,
	topic_subscribe_capture: ^[dynamic]Captured_Topic_Subscribe,
	parent_pid:              u64,
	children_pids:           ^[dynamic]u64,
	next_spawn_pid:          u64,
	virtual_now:             time.Time,
}

Captured_Send :: struct {
	to:       u64,
	data:     rawptr,
	type_id:  typeid,
	priority: Message_Priority,
}

Captured_Publish :: struct {
	topic:   rawptr,
	data:    rawptr,
	type_id: typeid,
}

Captured_Timer :: struct {
	id:       u32,
	interval: time.Duration,
	repeat:   bool,
	active:   bool,
}

Captured_Spawn :: struct {
	name:    string,
	type_id: typeid,
}

Captured_Terminate :: struct {
	pid:    u64,
	reason: Termination_Reason,
}

Captured_Broadcast :: struct {
	data:    rawptr,
	type_id: typeid,
}

Captured_Rename :: struct {
	pid:      u64,
	new_name: string,
}

Captured_Subscribe :: struct {
	actor_type: u8,
}

Captured_Topic_Subscribe :: struct {
	topic: rawptr,
}

intercept_send_message :: proc(
	to: u64,
	content: $T,
	priority: Message_Priority = .NORMAL,
) -> (
	Send_Error,
	bool,
) {
	if test_intercept == nil do return {}, false
	val := content
	ptr, _ := mem.alloc(size_of(T))
	clone := cast(^T)ptr
	clone^ = val
	append(
		test_intercept.send_capture,
		Captured_Send{to = to, data = clone, type_id = T, priority = priority},
	)
	return .OK, true
}

intercept_send_self :: proc(content: $T) -> (Send_Error, bool) {
	if test_intercept == nil do return {}, false
	return intercept_send_message(test_intercept.self_pid, content)
}

intercept_send_message_name :: proc(to: string, content: $T) -> (Send_Error, bool) {
	if test_intercept == nil do return {}, false
	for c in to {
		if c == '@' do return .NODE_NOT_FOUND, true
	}
	if pid, ok := test_intercept.pid_registry[to]; ok {
		return intercept_send_message(pid, content)
	}
	return .ACTOR_NOT_FOUND, true
}

intercept_send_message_high :: proc(to: u64, content: $T) -> (Send_Error, bool) {
	if test_intercept == nil do return {}, false
	return intercept_send_message(to, content, .HIGH)
}

intercept_send_message_low :: proc(to: u64, content: $T) -> (Send_Error, bool) {
	if test_intercept == nil do return {}, false
	return intercept_send_message(to, content, .LOW)
}

intercept_send_message_to_children :: proc(content: $T) -> (bool, bool) {
	if test_intercept == nil do return false, false
	if test_intercept.children_pids == nil do return true, true
	for child_pid in test_intercept.children_pids {
		intercept_send_message(child_pid, content)
	}
	return true, true
}

intercept_send_message_to_parent :: proc(content: $T) -> (bool, bool) {
	if test_intercept == nil do return false, false
	if test_intercept.parent_pid == 0 do return false, true
	intercept_send_message(test_intercept.parent_pid, content)
	return true, true
}

intercept_send_to :: proc(
	actor_name: string,
	node_name: string,
	content: $T,
) -> (
	Send_Error,
	bool,
) {
	if test_intercept == nil do return {}, false
	return .NODE_NOT_FOUND, true
}

intercept_spawn :: proc(name: string, $T: typeid) -> (u64, bool) {
	if test_intercept == nil do return 0, false
	test_intercept.next_spawn_pid += 1
	pid := test_intercept.next_spawn_pid
	append(test_intercept.spawn_capture, Captured_Spawn{name = name, type_id = T})
	return pid, true
}

intercept_spawn_child :: proc(name: string, $T: typeid) -> (u64, bool) {
	if test_intercept == nil do return 0, false
	test_intercept.next_spawn_pid += 1
	pid := test_intercept.next_spawn_pid
	append(test_intercept.spawn_capture, Captured_Spawn{name = name, type_id = T})
	if test_intercept.children_pids != nil {
		append(test_intercept.children_pids, pid)
	}
	return pid, true
}

intercept_self_terminate :: proc(reason: Termination_Reason) -> bool {
	if test_intercept == nil do return false
	append(
		test_intercept.terminate_capture,
		Captured_Terminate{pid = test_intercept.self_pid, reason = reason},
	)
	return true
}

intercept_terminate_actor :: proc(to: u64, reason: Termination_Reason) -> bool {
	if test_intercept == nil do return false
	append(test_intercept.terminate_capture, Captured_Terminate{pid = to, reason = reason})
	return true
}

intercept_broadcast :: proc(content: $T) -> bool {
	if test_intercept == nil do return false
	val := content
	ptr, _ := mem.alloc(size_of(T))
	clone := cast(^T)ptr
	clone^ = val
	append(test_intercept.broadcast_capture, Captured_Broadcast{data = clone, type_id = T})
	return true
}

intercept_subscribe_type :: proc(actor_type: u8) -> bool {
	if test_intercept == nil do return false
	append(test_intercept.subscribe_capture, Captured_Subscribe{actor_type = actor_type})
	return true
}

intercept_subscribe_topic :: proc(topic: rawptr) -> bool {
	if test_intercept == nil do return false
	append(test_intercept.topic_subscribe_capture, Captured_Topic_Subscribe{topic = topic})
	return true
}

intercept_rename_actor :: proc(pid: u64, new_name: string) -> bool {
	if test_intercept == nil do return false
	append(test_intercept.rename_capture, Captured_Rename{pid = pid, new_name = new_name})
	return true
}

intercept_self_rename :: proc(new_name: string) -> bool {
	if test_intercept == nil do return false
	return intercept_rename_actor(test_intercept.self_pid, new_name)
}

intercept_get_actor_pid :: proc(name: string) -> (u64, bool, bool) {
	if test_intercept == nil do return 0, false, false
	if pid, ok := test_intercept.pid_registry[name]; ok {
		return pid, true, true
	}
	return 0, false, true
}

intercept_get_self_pid :: proc() -> (u64, bool) {
	if test_intercept == nil do return 0, false
	return test_intercept.self_pid, true
}

intercept_get_self_name :: proc() -> (string, bool) {
	if test_intercept == nil do return "", false
	return test_intercept.self_name, true
}

intercept_set_timer :: proc(interval: time.Duration, repeat: bool) -> (u32, Send_Error, bool) {
	if test_intercept == nil do return 0, {}, false
	test_intercept.next_timer_id += 1
	id := test_intercept.next_timer_id
	append(
		test_intercept.timer_capture,
		Captured_Timer{id = id, interval = interval, repeat = repeat, active = true},
	)
	return id, .OK, true
}

intercept_publish :: proc(topic: rawptr, content: $T) -> bool {
	if test_intercept == nil do return false
	val := content
	ptr, _ := mem.alloc(size_of(T))
	clone := cast(^T)ptr
	clone^ = val
	append(
		test_intercept.publish_capture,
		Captured_Publish{topic = topic, data = clone, type_id = T},
	)
	return true
}

intercept_cancel_timer :: proc(id: u32) -> (Send_Error, bool) {
	if test_intercept == nil do return {}, false
	for &t in test_intercept.timer_capture {
		if t.id == id {
			t.active = false
			break
		}
	}
	return .OK, true
}

intercept_now :: proc() -> (time.Time, bool) {
	if test_intercept == nil do return {}, false
	if test_intercept.virtual_now == {} do return {}, false
	return test_intercept.virtual_now, true
}
