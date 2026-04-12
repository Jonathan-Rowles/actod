package integration

import actod "../actod"
import "base:intrinsics"
import "core:fmt"
import "core:math/rand"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

INTEGRATION_TEST_ITERATIONS :: 1000
INTEGRATION_STRESS_ITERATIONS :: 5000
INTEGRATION_MAX_CONCURRENT_ACTORS :: 50
INTEGRATION_TEST_TIMEOUT_MS :: 5000

wait_for_node :: proc() {
	for _ in 0 ..< 1000 {
		if actod.NODE.started && actod.NODE.pid != 0 {
			_, ok := actod.get(&actod.global_registry, actod.NODE.pid)
			if ok {
				break
			}
		}
		thread.yield()
	}
}

Test_State :: struct {
	messages_sent:     u64,
	messages_received: u64,
	actors_spawned:    u64,
	actors_terminated: u64,
	errors_count:      u64,
}

global_test_state: Test_State

reset_test_state :: proc() {
	sync.atomic_store(&global_test_state.messages_sent, 0)
	sync.atomic_store(&global_test_state.messages_received, 0)
	sync.atomic_store(&global_test_state.actors_spawned, 0)
	sync.atomic_store(&global_test_state.actors_terminated, 0)
	sync.atomic_store(&global_test_state.errors_count, 0)
}

Integration_Test_Message :: struct {
	id:      int,
	payload: string,
	sender:  actod.PID,
}

Stress_Test_Message :: struct {
	id:     int,
	value:  int,
	sender: actod.PID,
}

MAX_PIPELINE_HOPS :: 32

Pipeline_Message :: struct {
	origin:   actod.PID,
	hops:     int,
	max_hops: int,
	path:     [MAX_PIPELINE_HOPS]actod.PID,
	path_len: int,
}

Broadcast_Message :: struct {
	origin: actod.PID,
	value:  int,
	seq:    int,
}

MAX_TARGET_ACTORS :: 100

Target_Actors_Message :: struct {
	actors: [MAX_TARGET_ACTORS]actod.PID,
	count:  int,
}

Lifecycle_Actor_Data :: struct {
	id:            int,
	initialized:   bool,
	message_count: int,
	terminating:   bool,
}

Echo_Actor_Data :: struct {
	id:         int,
	echo_count: int,
}

Pipeline_Actor_Data :: struct {
	id:        int,
	next_pid:  actod.PID,
	hop_count: int,
}

Broadcast_Actor_Data :: struct {
	id:             int,
	received_count: int,
	subscribers:    [MAX_TARGET_ACTORS]actod.PID,
	sub_count:      int,
}

Lifecycle_Actor_Behaviour :: actod.Actor_Behaviour(Lifecycle_Actor_Data) {
	init           = lifecycle_actor_init,
	handle_message = lifecycle_actor_handle_message,
	terminate      = lifecycle_actor_terminate,
}

Echo_Actor_Behaviour :: actod.Actor_Behaviour(Echo_Actor_Data) {
	handle_message = echo_actor_handle_message,
}

Pipeline_Actor_Behaviour :: actod.Actor_Behaviour(Pipeline_Actor_Data) {
	handle_message = pipeline_actor_handle_message,
}

Broadcast_Actor_Behaviour :: actod.Actor_Behaviour(Broadcast_Actor_Data) {
	handle_message = broadcast_actor_handle_message,
}

lifecycle_actor_init :: proc(data: ^Lifecycle_Actor_Data) {
	data.initialized = true
	sync.atomic_add(&global_test_state.actors_spawned, 1)
}

lifecycle_actor_handle_message :: proc(data: ^Lifecycle_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Integration_Test_Message:
		data.message_count += 1
		sync.atomic_add(&global_test_state.messages_received, 1)

		reply := Integration_Test_Message {
			id      = m.id + 1000,
			payload = fmt.tprintf("Echo: %s", m.payload),
			sender  = actod.NODE.pid,
		}
		actod.send_message(from, reply)
		sync.atomic_add(&global_test_state.messages_sent, 1)

	}
}

lifecycle_actor_terminate :: proc(data: ^Lifecycle_Actor_Data) {
	if !data.initialized {
		sync.atomic_add(&global_test_state.errors_count, 1)
	}
	sync.atomic_add(&global_test_state.actors_terminated, 1)
}

echo_actor_handle_message :: proc(data: ^Echo_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Integration_Test_Message:
		data.echo_count += 1
		sync.atomic_add(&global_test_state.messages_received, 1)

		actod.send_message(from, m)
		sync.atomic_add(&global_test_state.messages_sent, 1)
	case Stress_Test_Message:
		data.echo_count += 1
		sync.atomic_add(&global_test_state.messages_received, 1)
	case Broadcast_Message:
		data.echo_count += 1
		sync.atomic_add(&global_test_state.messages_received, 1)
	}
}

pipeline_actor_handle_message :: proc(data: ^Pipeline_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Pipeline_Message:
		data.hop_count += 1

		mut_msg := m
		if mut_msg.path_len < MAX_PIPELINE_HOPS {
			mut_msg.path[mut_msg.path_len] = actod.get_self_pid()
			mut_msg.path_len += 1
		}

		if data.next_pid != {} && mut_msg.hops + 1 < mut_msg.max_hops {
			mut_msg.hops = mut_msg.hops + 1
			err := actod.send_message(data.next_pid, mut_msg)
			if err != actod.Send_Error.OK {
				valid := actod.valid(&actod.global_registry, data.next_pid)
				fmt.printf(
					"ERROR: Actor %d failed to send to next_pid %v (valid=%v)\n",
					data.id,
					data.next_pid,
					valid,
				)
				thread.yield()
				actod.send_message(data.next_pid, mut_msg)
			}
			sync.atomic_add(&global_test_state.messages_sent, 1)
		} else {
			err := actod.send_message(mut_msg.origin, mut_msg)
			if err != actod.Send_Error.OK {
				origin_valid := actod.valid(&actod.global_registry, mut_msg.origin)
				fmt.printf(
					"ERROR: Actor %d failed to send to origin %v (valid=%v)\n",
					data.id,
					mut_msg.origin,
					origin_valid,
				)
				for _ in 0 ..< 50 {
					thread.yield()
					err_retry := actod.send_message(mut_msg.origin, mut_msg)
					if err_retry == actod.Send_Error.OK {
						break
					}
				}
			}
			sync.atomic_add(&global_test_state.messages_sent, 1)
		}

	case actod.PID:
		data.next_pid = m
	}
}

broadcast_actor_handle_message :: proc(data: ^Broadcast_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Broadcast_Message:
		data.received_count += 1
		sync.atomic_add(&global_test_state.messages_received, 1)

		for j in 0 ..< len(data.subscribers) {
			actod.send_message(data.subscribers[j], m)
			sync.atomic_add(&global_test_state.messages_sent, 1)
		}

	case actod.PID:
		data.subscribers[data.sub_count] = m
		data.sub_count += 1
	}
}

test_actor_lifecycle :: proc(t: ^testing.T) {
	reset_test_state()

	actor_count := 10
	actors := make([]actod.PID, actor_count)
	defer delete(actors)

	for i in 0 ..< actor_count {
		data := Lifecycle_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("lifecycle-%d", i), data, Lifecycle_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn lifecycle actor")
		testing.expect(t, pid != 0, "Got zero PID")
		actors[i] = pid
	}

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if sync.atomic_load(&global_test_state.actors_spawned) == u64(actor_count) {
			break
		}
		thread.yield()
	}

	for _ in 0 ..< 100 {
		thread.yield()
	}

	for idx in 0 ..< len(actors) {
		msg := Integration_Test_Message {
			id      = idx,
			payload = fmt.tprintf("test-%d", idx),
			sender  = actod.NODE.pid,
		}
		err := actod.send_message(actors[idx], msg)
		testing.expect(t, err == actod.Send_Error.OK, "Failed to send message")
		sync.atomic_add(&global_test_state.messages_sent, 1)
	}

	expected_messages := u64(actor_count * 2)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		total :=
			sync.atomic_load(&global_test_state.messages_sent) +
			sync.atomic_load(&global_test_state.messages_received)
		if total >= expected_messages {
			break
		}
		thread.yield()
	}

	for pid in actors {
		err := actod.send_message(pid, actod.Terminate{reason = .NORMAL})
		testing.expect(t, err == actod.Send_Error.OK, "Failed to send terminate")
	}

	expected_terminated := u64(actor_count)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS * 20 {
		all_removed := true
		for pid in actors {
			if actod.valid(&actod.global_registry, pid) {
				all_removed = false
				break
			}
		}
		terminated := sync.atomic_load(&global_test_state.actors_terminated)
		if all_removed && terminated >= expected_terminated {
			break
		}
		thread.yield()
	}

	final_terminated := sync.atomic_load(&global_test_state.actors_terminated)

	testing.expect_value(t, sync.atomic_load(&global_test_state.actors_spawned), u64(actor_count))
	testing.expect_value(t, final_terminated, u64(actor_count))
	testing.expect_value(t, sync.atomic_load(&global_test_state.errors_count), u64(0))
}

test_request_reply_pattern :: proc(t: ^testing.T) {
	reset_test_state()

	echo_count := 5
	echo_actors := make([]actod.PID, echo_count)
	defer delete(echo_actors)

	for i in 0 ..< echo_count {
		data := Echo_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("echo-%d", i), data, Echo_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn echo actor")
		echo_actors[i] = pid
	}

	messages_per_actor := 10
	total_messages := echo_count * messages_per_actor

	for i in 0 ..< echo_count {
		for j in 0 ..< messages_per_actor {
			msg := Integration_Test_Message {
				id      = i * messages_per_actor + j,
				payload = fmt.tprintf("echo-test-%d-%d", i, j),
				sender  = actod.NODE.pid,
			}
			err := actod.send_message(echo_actors[i], msg)
			testing.expect(t, err == actod.Send_Error.OK, "Failed to send echo message")
		}
	}

	expected_total := u64(total_messages * 2)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		total :=
			sync.atomic_load(&global_test_state.messages_sent) +
			sync.atomic_load(&global_test_state.messages_received)
		if total >= expected_total {
			break
		}

		for _ in 0 ..< 250 {
			thread.yield()
		}
	}

	for pid in echo_actors {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	sent := sync.atomic_load(&global_test_state.messages_sent)
	received := sync.atomic_load(&global_test_state.messages_received)
	testing.expect(t, sent >= u64(total_messages), "Not enough messages sent")
	testing.expect(t, received >= u64(total_messages), "Not enough messages received")
}

test_pipeline_pattern :: proc(t: ^testing.T) {
	reset_test_state()

	Origin_Actor_Data :: struct {
		returned_count: int,
	}

	Origin_Actor_Behaviour :: actod.Actor_Behaviour(Origin_Actor_Data) {
		handle_message = proc(data: ^Origin_Actor_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Pipeline_Message:
				data.returned_count += 1
				sync.atomic_add(&global_test_state.messages_received, 1)
			}
		},
	}

	origin_data := Origin_Actor_Data{}
	origin_pid, origin_ok := actod.spawn("pipeline-origin", origin_data, Origin_Actor_Behaviour)
	testing.expect(t, origin_ok, "Failed to spawn origin actor")

	pipeline_length := 5
	pipeline_actors := make([]actod.PID, pipeline_length)
	defer delete(pipeline_actors)

	for i in 0 ..< pipeline_length {
		data := Pipeline_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("pipeline-%d", i), data, Pipeline_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn pipeline actor")
		pipeline_actors[i] = pid
	}

	for i in 0 ..< pipeline_length {
		pid := pipeline_actors[i]
		valid := actod.valid(&actod.global_registry, pid)
		testing.expect(t, valid, fmt.tprintf("Pipeline actor %d (PID %v) not valid", i, pid))

		err := actod.send_message(pid, "test")
		if err != actod.Send_Error.OK {
			fmt.printf("WARNING: Pipeline actor %d cannot receive messages yet\n", i)
		}
	}

	for _ in 0 ..< 500 {
		thread.yield()
	}

	for i in 0 ..< pipeline_length - 1 {
		err := actod.send_message(pipeline_actors[i], pipeline_actors[i + 1])
		testing.expect(t, err == actod.Send_Error.OK, "Failed to link pipeline actors")
	}

	for _ in 0 ..< 500 {
		thread.yield()
	}

	test_messages := 10
	for _ in 0 ..< test_messages {
		msg := Pipeline_Message {
			origin   = origin_pid,
			hops     = 0,
			max_hops = pipeline_length,
			path_len = 0,
		}

		err := actod.send_message(pipeline_actors[0], msg)
		testing.expect(t, err == actod.Send_Error.OK, "Failed to send pipeline message")
		sync.atomic_add(&global_test_state.messages_sent, 1)
	}

	expected_returns := u64(test_messages)
	for i in 0 ..< INTEGRATION_TEST_ITERATIONS * 5 {
		received := sync.atomic_load(&global_test_state.messages_received)
		if received >= expected_returns {
			break
		}
		if i % 100 == 0 {}
		thread.yield()
	}

	for pid in pipeline_actors {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}
	actod.send_message(origin_pid, actod.Terminate{reason = .NORMAL})

	received := sync.atomic_load(&global_test_state.messages_received)
	_ = sync.atomic_load(&global_test_state.messages_sent)
	testing.expect(t, received >= expected_returns, "Pipeline didn't process all messages")
}

test_broadcast_pattern :: proc(t: ^testing.T) {

	reset_test_state()

	broadcaster_data := Broadcast_Actor_Data {
		id = 0,
	}
	broadcaster, ok := actod.spawn("broadcaster", broadcaster_data, Broadcast_Actor_Behaviour)
	testing.expect(t, ok, "Failed to spawn broadcaster")

	subscriber_count := 10
	subscribers := make([]actod.PID, subscriber_count)
	defer delete(subscribers)

	for i in 0 ..< subscriber_count {
		data := Echo_Actor_Data {
			id = i,
		}
		pid, sub_ok := actod.spawn(fmt.tprintf("subscriber-%d", i), data, Echo_Actor_Behaviour)
		testing.expect(t, sub_ok, "Failed to spawn subscriber")
		subscribers[i] = pid

		err := actod.send_message(broadcaster, pid)
		testing.expect(t, err == actod.Send_Error.OK, "Failed to subscribe")
	}

	broadcast_count := 5
	for i in 0 ..< broadcast_count {
		msg := Broadcast_Message {
			origin = actod.NODE.pid,
			value  = i * 100,
			seq    = i,
		}

		err := actod.send_message(broadcaster, msg)
		testing.expect(t, err == actod.Send_Error.OK, "Failed to send broadcast")
		sync.atomic_add(&global_test_state.messages_sent, 1)
	}

	expected_messages := u64(broadcast_count * (1 + subscriber_count))
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		total :=
			sync.atomic_load(&global_test_state.messages_sent) +
			sync.atomic_load(&global_test_state.messages_received)
		if total >= expected_messages {
			break
		}
		thread.yield()
	}

	actod.send_message(broadcaster, actod.Terminate{reason = .NORMAL})
	for pid in subscribers {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	sent := sync.atomic_load(&global_test_state.messages_sent)
	testing.expect(t, sent >= u64(broadcast_count * subscriber_count), "Not all broadcasts sent")
}

test_concurrent_actor_operations :: proc(t: ^testing.T) {

	reset_test_state()

	cycles := 10
	actors_per_cycle := 20

	for cycle in 0 ..< cycles {
		actors := make([]actod.PID, actors_per_cycle)

		for i in 0 ..< actors_per_cycle {
			data := Lifecycle_Actor_Data {
				id = cycle * actors_per_cycle + i,
			}
			pid, ok := actod.spawn(
				fmt.tprintf("rapid-%d-%d", cycle, i),
				data,
				Lifecycle_Actor_Behaviour,
			)
			testing.expect(t, ok, "Failed to spawn in rapid cycle")
			actors[i] = pid
		}

		for i in 0 ..< len(actors) {
			msg := Integration_Test_Message {
				id      = i,
				payload = fmt.tprintf("rapid-test-%d", i),
				sender  = actod.NODE.pid,
			}
			actod.send_message(actors[i], msg)
		}

		for pid in actors {
			actod.send_message(pid, actod.Terminate{reason = .NORMAL})
		}

		expected_terminated := u64((cycle + 1) * actors_per_cycle)
		for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
			all_removed := true
			for pid in actors {
				if actod.valid(&actod.global_registry, pid) {
					all_removed = false
					break
				}
			}
			terminated := sync.atomic_load(&global_test_state.actors_terminated)
			if all_removed && terminated >= expected_terminated {
				break
			}
			thread.yield()
		}

		delete(actors)
	}

	expected_spawned := u64(cycles * actors_per_cycle)
	for wait_i in 0 ..< INTEGRATION_TEST_ITERATIONS * 20 {
		spawned := sync.atomic_load(&global_test_state.actors_spawned)
		terminated := sync.atomic_load(&global_test_state.actors_terminated)
		if spawned >= expected_spawned && terminated >= expected_spawned {
			break
		}
		if wait_i % 1000 == 0 && wait_i > 0 {
		}
		thread.yield()
	}

	spawned := sync.atomic_load(&global_test_state.actors_spawned)
	terminated := sync.atomic_load(&global_test_state.actors_terminated)
	if terminated < expected_spawned {
		registry_count := actod.num_used(&actod.global_registry)
		fmt.printf(
			"Warning: Not all actors terminated - spawned=%d, terminated=%d, expected=%d, registry=%d\n",
			spawned,
			terminated,
			expected_spawned,
			registry_count,
		)
	}
	testing.expect_value(t, spawned, expected_spawned)
	testing.expect_value(t, terminated, expected_spawned)
}

test_stress_message_throughput :: proc(t: ^testing.T) {
	reset_test_state()

	actor_count := 10
	messages_per_actor := 1000

	actors := make([]actod.PID, actor_count)
	defer delete(actors)

	for i in 0 ..< actor_count {
		data := Echo_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("stress-%d", i), data, Echo_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn stress actor")
		actors[i] = pid
	}

	sender_count := 4
	messages_per_sender := (actor_count * messages_per_actor) / sender_count

	wg: sync.Wait_Group
	sync.wait_group_add(&wg, sender_count)

	sender_proc :: proc(actors: []actod.PID, messages: int, sender_id: int, wg: ^sync.Wait_Group) {
		defer sync.wait_group_done(wg)

		for i in 0 ..< messages {
			actor_idx := rand.int31() % i32(len(actors))
			msg := Stress_Test_Message {
				id     = sender_id * messages + i,
				value  = i * 42,
				sender = actod.NODE.pid,
			}

			actod.send_message(actors[actor_idx], msg)
			sync.atomic_add(&global_test_state.messages_sent, 1)

			if i % 100 == 0 {
				thread.yield()
			}
		}
	}

	Sender_Context :: struct {
		actors:    []actod.PID,
		messages:  int,
		sender_id: int,
		wg:        ^sync.Wait_Group,
	}

	sender_thread_proc :: proc(ctx: rawptr) {
		ctx_ptr := cast(^Sender_Context)ctx
		sender_proc(ctx_ptr.actors, ctx_ptr.messages, ctx_ptr.sender_id, ctx_ptr.wg)
	}

	sender_contexts := make([]Sender_Context, sender_count)
	defer delete(sender_contexts)

	sender_threads := make([dynamic]^thread.Thread, sender_count)
	defer {
		for t in sender_threads {
			if t != nil {
				thread.join(t)
				thread.destroy(t)
			}
		}
		delete(sender_threads)
	}

	for i in 0 ..< sender_count {
		sender_contexts[i] = Sender_Context {
			actors    = actors,
			messages  = messages_per_sender,
			sender_id = i,
			wg        = &wg,
		}
		sender_threads[i] = thread.create_and_start_with_data(
			&sender_contexts[i],
			sender_thread_proc,
		)
	}

	sync.wait_group_wait(&wg)

	expected_messages := u64(actor_count * messages_per_actor)
	for _ in 0 ..< INTEGRATION_STRESS_ITERATIONS {
		if sync.atomic_load(&global_test_state.messages_received) >= expected_messages {
			break
		}
		thread.yield()
	}

	for pid in actors {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	sent := sync.atomic_load(&global_test_state.messages_sent)
	received := sync.atomic_load(&global_test_state.messages_received)
	testing.expect(t, sent >= expected_messages, "Not enough messages sent in stress test")
	testing.expect(t, received >= expected_messages, "Not enough messages received in stress test")
}

test_pool_integration :: proc(t: ^testing.T) {
	reset_test_state()

	actor_count := 50
	messages_per_actor := 100

	actors := make([]actod.PID, actor_count)
	defer delete(actors)

	for i in 0 ..< actor_count {
		data := Echo_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("pool-test-%d", i), data, Echo_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn pool test actor")
		actors[i] = pid
	}

	for i in 0 ..< messages_per_actor {
		for j in 0 ..< len(actors) {
			msg := Integration_Test_Message {
				id      = i * actor_count + j,
				payload = fmt.tprintf("pool-stress-%d-%d", i, j),
				sender  = actod.NODE.pid,
			}
			actod.send_message(actors[j], msg)
		}

		if i % 10 == 0 {
			thread.yield()
		}
	}

	expected_messages := u64(actor_count * messages_per_actor)
	for _ in 0 ..< INTEGRATION_STRESS_ITERATIONS {
		if sync.atomic_load(&global_test_state.messages_received) >= expected_messages {
			break
		}
		thread.yield()
	}

	for pid in actors {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	errors := sync.atomic_load(&global_test_state.errors_count)
	testing.expect_value(t, errors, u64(0))
}

Large_Message :: struct {
	data:     [1024]byte,
	sequence: int,
}

test_pool_cleanup_on_actor_termination :: proc(t: ^testing.T) {
	reset_test_state()

	actor_count := 5
	messages_per_actor := 100

	Pool_Test_Actor_Data :: struct {
		id:          int,
		allocations: int,
	}

	Pool_Test_Actor_Behaviour :: actod.Actor_Behaviour(Pool_Test_Actor_Data) {
		handle_message = proc(data: ^Pool_Test_Actor_Data, from: actod.PID, msg: any) {
			data.allocations += 1
			sync.atomic_add(&global_test_state.messages_received, 1)
		},
	}

	actors := make([]actod.PID, actor_count)
	defer delete(actors)

	for i in 0 ..< actor_count {
		data := Pool_Test_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("pool-cleanup-%d", i), data, Pool_Test_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn pool test actor")
		actors[i] = pid
	}

	for i in 0 ..< messages_per_actor {
		for j in 0 ..< len(actors) {
			msg := Large_Message {
				sequence = i * actor_count + j,
			}
			for k in 0 ..< len(msg.data) {
				msg.data[k] = u8((i + j + k) & 0xFF)
			}
			actod.send_message(actors[j], msg)
			sync.atomic_add(&global_test_state.messages_sent, 1)
		}
	}

	expected_messages := u64(actor_count * messages_per_actor)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if sync.atomic_load(&global_test_state.messages_received) >= expected_messages {
			break
		}
		thread.yield()
	}

	initial_registry_count := actod.num_used(&actod.global_registry)

	for pid in actors {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		current_count := actod.num_used(&actod.global_registry)
		if current_count == initial_registry_count - actor_count {
			break
		}
		thread.yield()
	}

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS * 20 {
		all_invalid := true
		for pid in actors {
			if actod.valid(&actod.global_registry, pid) {
				all_invalid = false
				break
			}
		}
		if all_invalid {
			break
		}
		thread.yield()
	}

	for pid in actors {
		testing.expect(
			t,
			!actod.valid(&actod.global_registry, pid),
			"Actor still valid after termination",
		)
	}

	final_count := actod.num_used(&actod.global_registry)
	testing.expect_value(t, final_count, initial_registry_count - actor_count)

	testing.expect_value(t, sync.atomic_load(&global_test_state.messages_sent), expected_messages)
	testing.expect_value(
		t,
		sync.atomic_load(&global_test_state.messages_received),
		expected_messages,
	)
}

test_registry_consistency :: proc(t: ^testing.T) {
	reset_test_state()

	iterations := 10
	actors := make([dynamic]actod.PID)
	defer delete(actors)

	for i in 0 ..< iterations {
		initial_count := actod.num_used(&actod.global_registry)

		data := Lifecycle_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn(fmt.tprintf("registry-test-%d", i), data, Lifecycle_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn registry test actor")
		if !ok {
			continue
		}
		append(&actors, pid)

		for _ in 0 ..< 100 {
			after_spawn := actod.num_used(&actod.global_registry)
			if after_spawn > initial_count {
				break
			}
			thread.yield()
		}

		after_spawn := actod.num_used(&actod.global_registry)
		testing.expect(t, after_spawn > initial_count, "Registry not updated after spawn")

		testing.expect(t, actod.valid(&actod.global_registry, pid), "Actor not valid after spawn")
	}

	for i in 0 ..< len(actors) {
		msg := Integration_Test_Message {
			id      = i,
			payload = fmt.tprintf("registry-%d", i),
			sender  = actod.NODE.pid,
		}
		actod.send_message(actors[i], msg)
	}

	expected_messages := u64(len(actors) * 2)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if sync.atomic_load(&global_test_state.messages_received) >= expected_messages {
			break
		}
		thread.yield()
	}

	for pid in actors {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		all_terminated := true
		for pid in actors {
			if actod.valid(&actod.global_registry, pid) {
				all_terminated = false
				break
			}
		}
		if all_terminated {
			break
		}
		thread.yield()
	}

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if sync.atomic_load(&global_test_state.actors_terminated) >= u64(iterations) {
			break
		}
		thread.yield()
	}

	errors := sync.atomic_load(&global_test_state.errors_count)
	testing.expect_value(t, errors, u64(0))
}


String_Test_Message :: struct {
	id:          int,
	name:        string,
	description: string,
	metadata:    string,
}

Complex_String_Message :: struct {
	title:   string,
	content: string,
	author:  string,
	tags:    [5]string,
	count:   int,
}

Mixed_Message :: struct {
	id:    int,
	name:  string,
	value: f64,
	data:  [64]byte,
	label: string,
}

String_Actor_Data :: struct {
	received_messages: int,
	last_message:      String_Test_Message,
}

String_Actor_Behaviour := actod.Actor_Behaviour(String_Actor_Data) {
	handle_message = string_actor_handle_message,
}

string_actor_handle_message :: proc(data: ^String_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case String_Test_Message:
		data.received_messages += 1
		data.last_message = m


		reply := String_Test_Message {
			id          = m.id + 1000,
			name        = fmt.tprintf("Echo: %s", m.name),
			description = fmt.tprintf("Received: %s", m.description),
			metadata    = fmt.tprintf("Count: %d", data.received_messages),
		}
		actod.send_message(from, reply)

	case Complex_String_Message:
		data.received_messages += 1

	case Mixed_Message:
		data.received_messages += 1
	}

	sync.atomic_add(&global_test_state.messages_received, 1)
}

test_string_handling :: proc(t: ^testing.T) {
	reset_test_state()

	actor_data := String_Actor_Data{}
	string_actor, ok := actod.spawn("string-test-actor", actor_data, String_Actor_Behaviour)
	testing.expect(t, ok, "Failed to spawn string test actor")


	test_messages := []String_Test_Message {
		{
			id = 1,
			name = "Test Actor",
			description = "This is a test description with special chars: 🎭 ñ ü",
			metadata = "",
		},
		{id = 2, name = "Short", description = "A", metadata = "Some metadata"},
		{id = 3, name = "", description = "", metadata = "Only metadata"},
		{
			id = 4,
			name = "Very long name that exceeds inline message size to force pool allocation",
			description = "This description is also quite long to ensure we're testing the string copying mechanism properly",
			metadata = "Additional metadata field",
		},
	}

	for msg in test_messages {
		err := actod.send_message(string_actor, msg)
		testing.expect(
			t,
			err == actod.Send_Error.OK,
			fmt.tprintf("Failed to send message %d", msg.id),
		)
		sync.atomic_add(&global_test_state.messages_sent, 1)
	}


	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if sync.atomic_load(&global_test_state.messages_received) >= u64(len(test_messages)) {
			break
		}
		thread.yield()
	}


	complex_msg := Complex_String_Message {
		title   = "Complex Message Test",
		content = "This message contains multiple string fields and an array of strings",
		author  = "Test Suite",
		tags    = {"tag1", "tag2", "tag3", "", ""},
		count   = 3,
	}

	err := actod.send_message(string_actor, complex_msg)
	testing.expect(t, err == actod.Send_Error.OK, "Failed to send complex message")


	mixed_msg := Mixed_Message {
		id    = 42,
		name  = "Mixed data test",
		value = 3.14159,
		label = "Test label with unicode: 你好",
	}

	for i in 0 ..< len(mixed_msg.data) {
		mixed_msg.data[i] = u8(i)
	}

	err2 := actod.send_message(string_actor, mixed_msg)
	testing.expect(t, err2 == actod.Send_Error.OK, "Failed to send mixed message")


	sender_count := 5
	senders := make([]actod.PID, sender_count)
	defer delete(senders)

	Sender_Data :: struct {
		id:     int,
		target: actod.PID,
	}

	Sender_Behaviour :: actod.Actor_Behaviour(Sender_Data) {
		init = proc(data: ^Sender_Data) {

			for i in 0 ..< 10 {
				msg := String_Test_Message {
					id          = data.id * 100 + i,
					name        = fmt.tprintf("Sender-%d-Message-%d", data.id, i),
					description = fmt.tprintf(
						"Description from sender %d, message %d",
						data.id,
						i,
					),
					metadata    = fmt.tprintf("Metadata: %d-%d", data.id, i),
				}
				actod.send_message(data.target, msg)
			}
		},
		handle_message = proc(data: ^Sender_Data, from: actod.PID, msg: any) {

		},
	}

	for i in 0 ..< sender_count {
		sender_data := Sender_Data {
			id     = i,
			target = string_actor,
		}
		pid, sender_ok := actod.spawn(fmt.tprintf("sender-%d", i), sender_data, Sender_Behaviour)
		testing.expect(t, sender_ok, "Failed to spawn sender")
		senders[i] = pid
	}


	expected_total := u64(len(test_messages) + 2 + sender_count * 10)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS * 2 {
		if sync.atomic_load(&global_test_state.messages_received) >= expected_total {
			break
		}
		thread.yield()
	}


	actod.send_message(string_actor, actod.Terminate{reason = .NORMAL})
	for pid in senders {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}


	received := sync.atomic_load(&global_test_state.messages_received)
	testing.expect(
		t,
		received >= expected_total,
		fmt.tprintf("Not all string messages received: %d < %d", received, expected_total),
	)
}

Byte_Slice_Test_Message :: struct {
	id:          int,
	name:        []byte,
	description: []byte,
	metadata:    []byte,
}

Complex_Byte_Slice_Message :: struct {
	title:   []byte,
	content: []byte,
	author:  []byte,
	count:   int,
}

Mixed_Byte_Slice_Message :: struct {
	id:    int,
	name:  []byte,
	value: f64,
	data:  [64]byte,
	label: []byte,
}

Byte_Slice_Actor_Data :: struct {
	received_messages: int,
	last_message:      Byte_Slice_Test_Message,
}

Byte_Slice_Actor_Behaviour := actod.Actor_Behaviour(Byte_Slice_Actor_Data) {
	handle_message = byte_slice_actor_handle_message,
}

byte_slice_actor_handle_message :: proc(data: ^Byte_Slice_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Byte_Slice_Test_Message:
		data.received_messages += 1
		data.last_message = m

		reply := Byte_Slice_Test_Message {
			id          = m.id + 1000,
			name        = transmute([]byte)fmt.tprintf("Echo: %s", string(m.name)),
			description = transmute([]byte)fmt.tprintf("Received: %s", string(m.description)),
			metadata    = transmute([]byte)fmt.tprintf("Count: %d", data.received_messages),
		}
		actod.send_message(from, reply)

	case Complex_Byte_Slice_Message:
		data.received_messages += 1

	case Mixed_Byte_Slice_Message:
		data.received_messages += 1
	}

	sync.atomic_add(&global_test_state.messages_received, 1)
}

test_byte_slice_handling :: proc(t: ^testing.T) {
	reset_test_state()

	actor_data := Byte_Slice_Actor_Data{}
	byte_actor, ok := actod.spawn("byte-slice-test-actor", actor_data, Byte_Slice_Actor_Behaviour)
	testing.expect(t, ok, "Failed to spawn byte slice test actor")

	test_messages := []Byte_Slice_Test_Message {
		{
			id = 1,
			name = transmute([]byte)string("Test Actor"),
			description = transmute([]byte)string(
				"This is a test description with special chars: 🎭 ñ ü",
			),
			metadata = transmute([]byte)string(""),
		},
		{
			id = 2,
			name = transmute([]byte)string("Short"),
			description = transmute([]byte)string("A"),
			metadata = transmute([]byte)string("Some metadata"),
		},
		{
			id = 3,
			name = transmute([]byte)string(""),
			description = transmute([]byte)string(""),
			metadata = transmute([]byte)string("Only metadata"),
		},
		{
			id = 4,
			name = transmute([]byte)string(
				"Very long name that exceeds inline message size to force pool allocation",
			),
			description = transmute([]byte)string(
				"This description is also quite long to ensure we're testing the byte slice copying mechanism properly",
			),
			metadata = transmute([]byte)string("Additional metadata field"),
		},
	}

	for msg in test_messages {
		err := actod.send_message(byte_actor, msg)
		testing.expect(
			t,
			err == actod.Send_Error.OK,
			fmt.tprintf("Failed to send message %d", msg.id),
		)
		sync.atomic_add(&global_test_state.messages_sent, 1)
	}

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if sync.atomic_load(&global_test_state.messages_received) >= u64(len(test_messages)) {
			break
		}
		thread.yield()
	}

	complex_msg := Complex_Byte_Slice_Message {
		title   = transmute([]byte)string("Complex Message Test"),
		content = transmute([]byte)string("This message contains multiple byte slice fields"),
		author  = transmute([]byte)string("Test Suite"),
		count   = 3,
	}

	err := actod.send_message(byte_actor, complex_msg)
	testing.expect(t, err == actod.Send_Error.OK, "Failed to send complex byte slice message")

	mixed_msg := Mixed_Byte_Slice_Message {
		id    = 42,
		name  = transmute([]byte)string("Mixed data test"),
		value = 3.14159,
		label = transmute([]byte)string("Test label with unicode: 你好"),
	}

	for i in 0 ..< len(mixed_msg.data) {
		mixed_msg.data[i] = u8(i)
	}

	err2 := actod.send_message(byte_actor, mixed_msg)
	testing.expect(t, err2 == actod.Send_Error.OK, "Failed to send mixed byte slice message")

	sender_count := 5
	senders := make([]actod.PID, sender_count)
	defer delete(senders)

	Byte_Sender_Data :: struct {
		id:     int,
		target: actod.PID,
	}

	Byte_Sender_Behaviour :: actod.Actor_Behaviour(Byte_Sender_Data) {
		init = proc(data: ^Byte_Sender_Data) {
			for i in 0 ..< 10 {
				msg := Byte_Slice_Test_Message {
					id          = data.id * 100 + i,
					name        = transmute([]byte)fmt.tprintf("Sender-%d-Message-%d", data.id, i),
					description = transmute([]byte)fmt.tprintf(
						"Description from sender %d, message %d",
						data.id,
						i,
					),
					metadata    = transmute([]byte)fmt.tprintf("Metadata: %d-%d", data.id, i),
				}
				actod.send_message(data.target, msg)
			}
		},
		handle_message = proc(data: ^Byte_Sender_Data, from: actod.PID, msg: any) {
		},
	}

	for i in 0 ..< sender_count {
		sender_data := Byte_Sender_Data {
			id     = i,
			target = byte_actor,
		}
		pid, sender_ok := actod.spawn(
			fmt.tprintf("byte-sender-%d", i),
			sender_data,
			Byte_Sender_Behaviour,
		)
		testing.expect(t, sender_ok, "Failed to spawn byte sender")
		senders[i] = pid
	}

	expected_total := u64(len(test_messages) + 2 + sender_count * 10)
	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS * 2 {
		if sync.atomic_load(&global_test_state.messages_received) >= expected_total {
			break
		}
		thread.yield()
	}

	actod.send_message(byte_actor, actod.Terminate{reason = .NORMAL})
	for pid in senders {
		actod.send_message(pid, actod.Terminate{reason = .NORMAL})
	}

	received := sync.atomic_load(&global_test_state.messages_received)
	testing.expect(
		t,
		received >= expected_total,
		fmt.tprintf("Not all byte slice messages received: %d < %d", received, expected_total),
	)
}

test_node_shutdown_under_load :: proc(t: ^testing.T) {
	reset_test_state()

	actor_count := 10
	actors := make([]actod.PID, actor_count)
	defer delete(actors)

	Active_Actor_Data :: struct {
		id:            int,
		target_actors: [dynamic]actod.PID,
		should_stop:   bool,
	}

	Active_Actor_Behaviour :: actod.Actor_Behaviour(Active_Actor_Data) {
		terminate = proc(data: ^Active_Actor_Data) {
			if len(data.target_actors) > 0 {
				delete(data.target_actors)
			}
		},
		handle_message = proc(data: ^Active_Actor_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Integration_Test_Message:
				if !data.should_stop && len(data.target_actors) > 0 {
					for i := 0; i < 3; i += 1 {
						target_idx := int(rand.uint32()) % len(data.target_actors)
						reply := Integration_Test_Message {
							id      = m.id + i,
							payload = "relay",
							sender  = actod.NODE.pid,
						}
						actod.send_message(data.target_actors[target_idx], reply)
						sync.atomic_add(&global_test_state.messages_sent, 1)
					}
				}
				sync.atomic_add(&global_test_state.messages_received, 1)
			case string:
				if m == "stop" {
					data.should_stop = true
				}
			case Target_Actors_Message:
				if len(data.target_actors) > 0 {
					delete(data.target_actors)
				}
				data.target_actors = make([dynamic]actod.PID, m.count)
				for i in 0 ..< m.count {
					data.target_actors[i] = m.actors[i]
				}
			}
		},
	}

	for i in 0 ..< actor_count {
		data := Active_Actor_Data {
			id = i,
		}
		pid, ok := actod.spawn("active", data, Active_Actor_Behaviour)
		testing.expect(t, ok, "Failed to spawn active actor")
		actors[i] = pid
	}

	for pid in actors {
		msg := Target_Actors_Message {
			count = len(actors),
		}
		copy(msg.actors[:len(actors)], actors[:])
		actod.send_message(pid, msg)
	}

	initial_messages := 50
	for i in 0 ..< initial_messages {
		for j := 0; j < len(actors); j += 1 {
			msg := Integration_Test_Message {
				id      = i * len(actors) + j,
				payload = "initial",
				sender  = actod.NODE.pid,
			}
			actod.send_message(actors[j], msg)
			sync.atomic_add(&global_test_state.messages_sent, 1)
		}
	}

	thread.yield()

	stop_senders := false
	sender_count := 50
	wg: sync.Wait_Group
	sync.wait_group_add(&wg, sender_count)

	Sender_Context :: struct {
		actors:    []actod.PID,
		stop:      ^bool,
		wg:        ^sync.Wait_Group,
		sender_id: int,
	}

	sender_proc :: proc(ctx: rawptr) {
		sender_ctx := cast(^Sender_Context)ctx
		defer sync.wait_group_done(sender_ctx.wg)

		msg_id := 0
		for !sync.atomic_load(sender_ctx.stop) {
			target_idx := int(rand.uint32()) % len(sender_ctx.actors)
			msg := Integration_Test_Message {
				id      = sender_ctx.sender_id * 10000 + msg_id,
				payload = "flood",
				sender  = actod.NODE.pid,
			}

			for i := 0; i < 5; i += 1 {
				actod.send_message(sender_ctx.actors[target_idx], msg)
			}
			msg_id += 1

			if msg_id % 1000 == 0 {
				intrinsics.cpu_relax()
			}
		}
	}

	sender_contexts := make([]Sender_Context, sender_count)
	defer delete(sender_contexts)

	sender_threads := make([dynamic]^thread.Thread, sender_count)
	defer {
		for t in sender_threads {
			if t != nil {
				thread.join(t)
				thread.destroy(t)
			}
		}
		delete(sender_threads)
	}

	for i in 0 ..< sender_count {
		sender_contexts[i] = Sender_Context {
			actors    = actors,
			stop      = &stop_senders,
			wg        = &wg,
			sender_id = i,
		}
		sender_threads[i] = thread.create_and_start_with_data(&sender_contexts[i], sender_proc)
	}

	for _ in 0 ..< 10 {
		intrinsics.cpu_relax()
	}

	initial_registry_count := actod.num_used(&actod.global_registry)
	testing.expect(t, int(initial_registry_count) > actor_count, "Registry should have actors")
	messages_before_shutdown := sync.atomic_load(&global_test_state.messages_received)

	node_pid := actod.NODE.pid
	testing.expect(t, node_pid != 0, "Node PID should not be 0 before shutdown")

	actod.SHUTDOWN_NODE()

	for i := 0; i < 1000; i += 1 {
		intrinsics.cpu_relax()

		if i % 100 == 0 {
		}
	}

	sync.atomic_store(&stop_senders, true)
	sync.wait_group_wait(&wg)

	testing.expect_value(t, actod.NODE.pid, actod.PID(0))
	testing.expect(
		t,
		actod.NODE.started == false,
		"Node should not be marked as started after shutdown",
	)

	final_registry_count := actod.num_used(&actod.global_registry)
	testing.expect_value(t, final_registry_count, 0)

	for pid in actors {
		testing.expect(
			t,
			!actod.valid(&actod.global_registry, pid),
			"Actor should not be valid after shutdown",
		)
	}

	testing.expect(
		t,
		!actod.valid(&actod.global_registry, node_pid),
		"Node actor should not be valid after shutdown",
	)

	testing.expect(
		t,
		messages_before_shutdown > 0,
		"Should have processed messages before shutdown",
	)
}

Union_Ping :: struct {
	seq: u32,
}

Union_Chat :: struct {
	name:    string,
	content: string,
}

Union_Test_Message :: union {
	Union_Ping,
	Union_Chat,
}

Union_Ack :: struct {
	variant_name: [32]u8,
	name_len:     int,
	seq:          u32,
}

Union_Actor_Data :: struct {
	ping_count: int,
	chat_count: int,
	last_seq:   u32,
	last_name:  [64]u8,
	name_len:   int,
}

Union_Actor_Behaviour := actod.Actor_Behaviour(Union_Actor_Data) {
	handle_message = union_actor_handle_message,
}

union_actor_handle_message :: proc(data: ^Union_Actor_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Union_Test_Message:
		switch v in m {
		case Union_Ping:
			data.ping_count += 1
			data.last_seq = v.seq
		case Union_Chat:
			data.chat_count += 1
			data.last_seq = 0
			name_bytes := transmute([]u8)v.name
			data.name_len = min(len(name_bytes), len(data.last_name))
			copy(data.last_name[:data.name_len], name_bytes[:data.name_len])
		}
		sync.atomic_add(&global_test_state.messages_received, 1)

		ack := Union_Ack {
			seq = data.last_seq,
		}
		actod.send_message(from, ack)
	}
}

test_union_message_handling :: proc(t: ^testing.T) {
	reset_test_state()

	Collector_Data :: struct {
		ack_count: int,
		done:      ^sync.Sema,
		expected:  int,
	}

	Collector_Behaviour :: actod.Actor_Behaviour(Collector_Data) {
		handle_message = proc(data: ^Collector_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case Union_Ack:
				data.ack_count += 1
				if data.ack_count >= data.expected {
					sync.sema_post(data.done)
				}
			}
		},
	}

	done := sync.Sema{}
	expected_messages := 6

	union_actor, ok := actod.spawn("union-test-actor", Union_Actor_Data{}, Union_Actor_Behaviour)
	testing.expect(t, ok, "Failed to spawn union test actor")

	collector_data := Collector_Data {
		done     = &done,
		expected = expected_messages,
	}
	collector, col_ok := actod.spawn("union-collector", collector_data, Collector_Behaviour)
	testing.expect(t, col_ok, "Failed to spawn collector")

	actod.send_message(union_actor, Union_Test_Message(Union_Ping{seq = 1}))
	actod.send_message(union_actor, Union_Test_Message(Union_Ping{seq = 42}))

	actod.send_message(union_actor, Union_Test_Message(Union_Chat{name = "alice", content = "hi"}))
	actod.send_message(
		union_actor,
		Union_Test_Message(
			Union_Chat {
				name = "bob",
				content = "This is a longer message that should exceed the inline message size and force pool allocation for proper deep-copy testing",
			},
		),
	)
	actod.send_message(union_actor, Union_Test_Message(Union_Chat{name = "", content = ""}))
	actod.send_message(
		union_actor,
		Union_Test_Message(Union_Chat{name = "unicode 你好", content = "🎭 ñ ü"}),
	)

	success := sync.sema_wait_with_timeout(&done, 3 * time.Second)
	testing.expect(t, success, "Timed out waiting for union messages")

	received := sync.atomic_load(&global_test_state.messages_received)
	testing.expect(
		t,
		received >= u64(expected_messages),
		fmt.tprintf("Not all union messages received: %d < %d", received, expected_messages),
	)

	actod.terminate_actor(union_actor)
	actod.terminate_actor(collector)

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if !actod.valid(&actod.global_registry, union_actor) {
			break
		}
		thread.yield()
	}
}

CONTENTION_ACTOR_COUNT :: 128
CONTENTION_WORKER_COUNT :: 2
CONTENTION_SEED_PINGS :: 4
CONTENTION_DURATION_MS :: 2000
CONTENTION_MIN_FAIRNESS :: 0.1

contention_received: [CONTENTION_ACTOR_COUNT]u64
contention_pids: [CONTENTION_ACTOR_COUNT]actod.PID

test_worker_contention :: proc(t: ^testing.T) {
	for i in 0 ..< CONTENTION_ACTOR_COUNT {
		sync.atomic_store(&contention_received[i], 0)
	}

	Contention_Actor_Data :: struct {
		idx: int,
	}

	Contention_Actor_Behaviour :: actod.Actor_Behaviour(Contention_Actor_Data) {
		handle_message = proc(data: ^Contention_Actor_Data, from: actod.PID, msg: any) {
			switch _ in msg {
			case Integration_Test_Message:
				sync.atomic_add(&contention_received[data.idx], 1)
				target := contention_pids[int(rand.uint32()) % CONTENTION_ACTOR_COUNT]
				actod.send_message(target, Integration_Test_Message{})
			}
		},
	}

	for i in 0 ..< CONTENTION_ACTOR_COUNT {
		pid, ok := actod.spawn(
			"contention",
			Contention_Actor_Data{idx = i},
			Contention_Actor_Behaviour,
		)
		testing.expect(t, ok, "Failed to spawn contention actor")
		contention_pids[i] = pid
	}

	for i in 0 ..< CONTENTION_ACTOR_COUNT {
		for _ in 0 ..< CONTENTION_SEED_PINGS {
			actod.send_message(contention_pids[i], Integration_Test_Message{})
		}
	}

	time.sleep(time.Duration(CONTENTION_DURATION_MS) * time.Millisecond)

	total: u64 = 0
	min_recv: u64 = max(u64)
	max_recv: u64 = 0
	starved := 0

	for i in 0 ..< CONTENTION_ACTOR_COUNT {
		count := sync.atomic_load(&contention_received[i])
		total += count
		if count < min_recv do min_recv = count
		if count > max_recv do max_recv = count
		if count == 0 do starved += 1
	}

	fairness := f64(min_recv) / f64(max_recv) if max_recv > 0 else 0.0

	testing.expectf(
		t,
		starved == 0,
		"Starved actors: %d of %d received zero messages",
		starved,
		CONTENTION_ACTOR_COUNT,
	)
	testing.expectf(
		t,
		fairness >= CONTENTION_MIN_FAIRNESS,
		"Fairness ratio %.3f below %.1f threshold (min=%d, max=%d)",
		fairness,
		CONTENTION_MIN_FAIRNESS,
		min_recv,
		max_recv,
	)
	testing.expectf(t, total > 0, "No messages processed at all")

	for i in 0 ..< CONTENTION_ACTOR_COUNT {
		actod.terminate_actor(contention_pids[i])
	}

	for _ in 0 ..< INTEGRATION_STRESS_ITERATIONS {
		all_done := true
		for i in 0 ..< CONTENTION_ACTOR_COUNT {
			if actod.valid(&actod.global_registry, contention_pids[i]) {
				all_done = false
				break
			}
		}
		if all_done do break
		thread.yield()
	}
}

Pubsub_Price_Update :: struct {
	symbol: u64,
	bid:    f64,
	ask:    f64,
}

PUBSUB_PUBLISHER_TYPE: actod.Actor_Type
PUBSUB_SUBSCRIBER_COUNT :: 5

pubsub_types_registered := false
pubsub_registration_mutex: sync.Mutex

register_pubsub_types :: proc() {
	sync.lock(&pubsub_registration_mutex)
	defer sync.unlock(&pubsub_registration_mutex)
	if pubsub_types_registered do return
	PUBSUB_PUBLISHER_TYPE, _ = actod.register_actor_type("pubsub_test_publisher")
	pubsub_types_registered = true
}

Pubsub_Publisher_Data :: struct {
	broadcast_count: int,
}

Pubsub_Publisher_Behaviour :: actod.Actor_Behaviour(Pubsub_Publisher_Data) {
	actor_type     = {},
	handle_message = pubsub_publisher_handle,
}

pubsub_publisher_handle :: proc(data: ^Pubsub_Publisher_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case string:
		if m == "publish" {
			actod.broadcast(Pubsub_Price_Update{symbol = 1, bid = 100.5, ask = 101.0})
			data.broadcast_count += 1
		}
	}
}

Pubsub_Subscriber_Data :: struct {
	received: ^i32,
}

Pubsub_Subscriber_Behaviour :: actod.Actor_Behaviour(Pubsub_Subscriber_Data) {
	init           = pubsub_subscriber_init,
	handle_message = pubsub_subscriber_handle,
}

pubsub_subscriber_init :: proc(data: ^Pubsub_Subscriber_Data) {
	actod.subscribe_type(PUBSUB_PUBLISHER_TYPE)
}

pubsub_subscriber_handle :: proc(data: ^Pubsub_Subscriber_Data, from: actod.PID, msg: any) {
	switch m in msg {
	case Pubsub_Price_Update:
		sync.atomic_add(data.received, 1)
	}
}

test_pubsub_broadcast :: proc(t: ^testing.T) {
	register_pubsub_types()

	pub_behaviour := Pubsub_Publisher_Behaviour
	pub_behaviour.actor_type = PUBSUB_PUBLISHER_TYPE

	pub_pid, pub_ok := actod.spawn("pubsub_publisher", Pubsub_Publisher_Data{}, pub_behaviour)
	testing.expect(t, pub_ok, "Should spawn publisher")

	time.sleep(20 * time.Millisecond)

	received_count: i32 = 0

	sub_pids: [PUBSUB_SUBSCRIBER_COUNT]actod.PID
	for i in 0 ..< PUBSUB_SUBSCRIBER_COUNT {
		sub_data := Pubsub_Subscriber_Data {
			received = &received_count,
		}
		pid, ok := actod.spawn(
			fmt.tprintf("pubsub_sub_%d", i),
			sub_data,
			Pubsub_Subscriber_Behaviour,
		)
		testing.expect(t, ok, "Should spawn subscriber")
		sub_pids[i] = pid
	}

	time.sleep(50 * time.Millisecond)

	sub_count := actod.get_subscriber_count(PUBSUB_PUBLISHER_TYPE)
	testing.expectf(
		t,
		sub_count == PUBSUB_SUBSCRIBER_COUNT,
		"Should have %d subscribers, got %d",
		PUBSUB_SUBSCRIBER_COUNT,
		sub_count,
	)

	actod.send_message(pub_pid, "publish")

	for _ in 0 ..< 5000 {
		if sync.atomic_load(&received_count) >= PUBSUB_SUBSCRIBER_COUNT {
			break
		}
		thread.yield()
	}

	final_received := sync.atomic_load(&received_count)
	testing.expectf(
		t,
		final_received == PUBSUB_SUBSCRIBER_COUNT,
		"All %d subscribers should receive broadcast, got %d",
		PUBSUB_SUBSCRIBER_COUNT,
		final_received,
	)

	for pid in sub_pids {
		actod.terminate_actor(pid)
	}
	actod.terminate_actor(pub_pid)

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if !actod.valid(&actod.global_registry, pub_pid) {
			break
		}
		thread.yield()
	}
}

test_pubsub_auto_cleanup :: proc(t: ^testing.T) {
	register_pubsub_types()

	pub_behaviour := Pubsub_Publisher_Behaviour
	pub_behaviour.actor_type = PUBSUB_PUBLISHER_TYPE

	pub_pid, pub_ok := actod.spawn("pubsub_cleanup_pub", Pubsub_Publisher_Data{}, pub_behaviour)
	testing.expect(t, pub_ok, "Should spawn publisher")

	time.sleep(20 * time.Millisecond)

	received_count: i32 = 0
	sub_data := Pubsub_Subscriber_Data {
		received = &received_count,
	}
	sub_pid, sub_ok := actod.spawn("pubsub_cleanup_sub", sub_data, Pubsub_Subscriber_Behaviour)
	testing.expect(t, sub_ok, "Should spawn subscriber")

	time.sleep(50 * time.Millisecond)

	testing.expect(
		t,
		actod.get_subscriber_count(PUBSUB_PUBLISHER_TYPE) >= 1,
		"Should have at least 1 subscriber",
	)

	actod.terminate_actor(sub_pid)

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if !actod.valid(&actod.global_registry, sub_pid) {
			break
		}
		thread.yield()
	}

	time.sleep(50 * time.Millisecond)

	count_after := actod.get_subscriber_count(PUBSUB_PUBLISHER_TYPE)
	testing.expectf(
		t,
		count_after == 0,
		"Subscriber count should be 0 after termination, got %d",
		count_after,
	)

	actod.send_message(pub_pid, "publish")
	time.sleep(50 * time.Millisecond)

	testing.expect(
		t,
		sync.atomic_load(&received_count) == 0,
		"No messages should be received after subscriber terminated",
	)

	actod.terminate_actor(pub_pid)

	for _ in 0 ..< INTEGRATION_TEST_ITERATIONS {
		if !actod.valid(&actod.global_registry, pub_pid) {
			break
		}
		thread.yield()
	}
}
