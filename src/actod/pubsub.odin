package actod

import "../../test_harness/ti"
_ :: ti
import "core:log"
import "core:mem"
import "core:sync"

MAX_SUBSCRIBERS_PER_TYPE :: #config(ACTOD_MAX_SUBSCRIBERS_PER_TYPE, 16384)
MAX_TOPIC_SUBSCRIBERS :: 64
SUBSCRIBER_BLOCK_INITIAL_CAPACITY :: 64

Subscription :: struct {
	actor_type: Actor_Type,
	pid:        PID,
}

Topic :: struct {
	subscribers: [MAX_TOPIC_SUBSCRIBERS]PID,
	count:       u32,
}

Topic_Subscription :: struct {
	topic: ^Topic,
	pid:   PID,
}

Subscriber_Block :: struct {
	capacity: u32,
	prev:     ^Subscriber_Block,
	pids:     [^]u64,
}

Type_Subscriber_List :: struct {
	block:                 ^Subscriber_Block,
	count:                 u32,
	local_count:           u32,
	mutate_lock:           sync.Mutex,
	remote_node_sub_count: [MAX_NODES]u32,
}

@(private)
alloc_subscriber_block :: proc(capacity: u32, prev: ^Subscriber_Block) -> ^Subscriber_Block {
	raw, err := mem.alloc(
		size_of(Subscriber_Block) + int(capacity) * size_of(u64),
		align_of(Subscriber_Block),
		get_system_allocator(),
	)
	if err != nil do return nil
	block := cast(^Subscriber_Block)raw
	block.capacity = capacity
	block.prev = prev
	block.pids = cast([^]u64)(uintptr(raw) + size_of(Subscriber_Block))
	return block
}

@(private)
load_subscriber_block :: #force_inline proc(list: ^Type_Subscriber_List) -> ^Subscriber_Block {
	return(
		cast(^Subscriber_Block)rawptr(
			uintptr(sync.atomic_load_explicit(cast(^u64)&list.block, .Acquire)),
		) \
	)
}

@(private)
free_subscriber_blocks :: proc(block: ^Subscriber_Block) {
	block := block
	for block != nil {
		prev := block.prev
		mem.free(block, get_system_allocator())
		block = prev
	}
}

@(private)
add_subscriber :: proc(actor_type: Actor_Type, pid: PID, loc := #caller_location) -> bool {
	if actor_type == ACTOR_TYPE_UNTYPED {
		log.warn(
			"subscribe failed: actor type is ACTOR_TYPE_UNTYPED, set actor_type on the behaviour before subscribing",
			location = loc,
		)
		return false
	}
	if pid == 0 {
		log.warn(
			"subscribe failed: no calling actor, subscribe must be called from within an actor",
			location = loc,
		)
		return false
	}

	list := &NODE.type_subscribers[actor_type]
	sync.mutex_lock(&list.mutate_lock)
	defer sync.mutex_unlock(&list.mutate_lock)

	n := sync.atomic_load_explicit(&list.local_count, .Acquire)
	if n >= MAX_SUBSCRIBERS_PER_TYPE {
		log.warnf(
			"Subscriber list full for actor type %d, cap is %d (MAX_SUBSCRIBERS_PER_TYPE), subscription dropped",
			actor_type,
			MAX_SUBSCRIBERS_PER_TYPE,
			location = loc,
		)
		return false
	}

	block := list.block
	if block == nil || n == block.capacity {
		new_capacity :=
			block == nil \
			? u32(SUBSCRIBER_BLOCK_INITIAL_CAPACITY) \
			: min(block.capacity * 2, MAX_SUBSCRIBERS_PER_TYPE)
		new_block := alloc_subscriber_block(new_capacity, block)
		if new_block == nil {
			log.warnf(
				"Subscriber block allocation failed for actor type %d, subscription dropped",
				actor_type,
				location = loc,
			)
			return false
		}
		if block != nil {
			for i in 0 ..< n {
				new_block.pids[i] = sync.atomic_load_explicit(&block.pids[i], .Relaxed)
			}
		}
		sync.atomic_store_explicit(cast(^u64)&list.block, u64(uintptr(new_block)), .Release)
		block = new_block
	}

	sync.atomic_store_explicit(&block.pids[n], u64(pid), .Release)
	sync.atomic_add_explicit(&list.local_count, 1, .Release)
	sync.atomic_add_explicit(&list.count, 1, .Release)
	return true
}

@(private)
remove_subscriber :: proc(actor_type: Actor_Type, pid: PID) -> bool {
	if actor_type == ACTOR_TYPE_UNTYPED || pid == 0 do return false

	list := &NODE.type_subscribers[actor_type]
	sync.mutex_lock(&list.mutate_lock)
	defer sync.mutex_unlock(&list.mutate_lock)

	n := sync.atomic_load_explicit(&list.local_count, .Acquire)
	block := list.block
	if block == nil do return false

	for i in 0 ..< n {
		if PID(sync.atomic_load_explicit(&block.pids[i], .Acquire)) == pid {
			last := n - 1
			if i != last {
				last_pid := sync.atomic_load_explicit(&block.pids[last], .Acquire)
				sync.atomic_store_explicit(&block.pids[i], last_pid, .Release)
			}
			sync.atomic_store_explicit(&block.pids[last], 0, .Release)
			sync.atomic_sub_explicit(&list.local_count, 1, .Release)
			sync.atomic_sub_explicit(&list.count, 1, .Release)
			return true
		}
	}
	return false
}

@(require_results)
subscribe_type :: proc(actor_type: Actor_Type, loc := #caller_location) -> (Subscription, bool) {
	when ODIN_TEST {
		if ti.intercept_subscribe_type(u8(actor_type)) {
			return Subscription{actor_type = actor_type, pid = get_self_pid()}, true
		}
	}

	if actor_type == ACTOR_TYPE_UNTYPED {
		log.warn(
			"subscribe_type: cannot subscribe to ACTOR_TYPE_UNTYPED, register the type with register_actor_type and set actor_type on the behaviour",
			location = loc,
		)
		return {}, false
	}

	if current_actor_context == nil {
		log.warn(
			"subscribe_type must be called from within an actor, the subscription was not created",
			location = loc,
		)
		return {}, false
	}
	pid := get_self_pid()

	if !add_subscriber(actor_type, pid, loc) {
		return {}, false
	}

	sub := Subscription {
		actor_type = actor_type,
		pid        = pid,
	}

	if current_actor_context != nil do append(&current_actor_context.subscriptions, sub)

	type_hash, hash_ok := get_actor_type_hash(actor_type)
	if hash_ok {
		broadcast_to_others(Subscribe_Remote{type_name_hash = type_hash, count = 1})
	} else {
		log.warnf(
			"subscribe_type: no registered type name hash for actor type %d, the local subscription succeeded but remote nodes were not told, broadcasts from other nodes will not arrive",
			actor_type,
			location = loc,
		)
	}

	return sub, true
}

@(require_results)
pubsub_unsubscribe :: proc(sub: Subscription, loc := #caller_location) -> bool {
	if sub.pid == 0 {
		log.warn(
			"pubsub_unsubscribe: subscription has no PID, it was never successfully created by subscribe_type",
			location = loc,
		)
		return false
	}

	removed := remove_subscriber(sub.actor_type, sub.pid)
	if !removed {
		log.warnf(
			"pubsub_unsubscribe: PID %v is not subscribed to actor type %d, it may already have been unsubscribed",
			sub.pid,
			sub.actor_type,
			location = loc,
		)
		return false
	}

	if current_actor_context != nil {
		for i := 0; i < len(current_actor_context.subscriptions); i += 1 {
			s := current_actor_context.subscriptions[i]
			if s.pid == sub.pid && s.actor_type == sub.actor_type {
				unordered_remove(&current_actor_context.subscriptions, i)
				break
			}
		}
	}

	type_hash, hash_ok := get_actor_type_hash(sub.actor_type)
	if hash_ok {
		broadcast_to_others(
			Unsubscribe_Remote{type_name_hash = type_hash, count = 1},
		)
	} else {
		log.warnf(
			"pubsub_unsubscribe: no registered type name hash for actor type %d, the local subscription was removed but remote nodes still consider PID %v subscribed",
			sub.actor_type,
			sub.pid,
			location = loc,
		)
	}

	return true
}

broadcast :: proc(msg: $T, loc := #caller_location) {
	when ODIN_TEST {if ti.intercept_broadcast(msg) do return}

	self_pid := get_self_pid()
	actor_type := get_pid_actor_type(self_pid)

	if actor_type == ACTOR_TYPE_UNTYPED {
		log.warn(
			"broadcast() called from untyped actor, the message was dropped, set actor_type on the behaviour of the sending actor",
			location = loc,
		)
		return
	}

	list := &NODE.type_subscribers[actor_type]
	block := load_subscriber_block(list)

	if block != nil {
		n := min(sync.atomic_load_explicit(&list.local_count, .Acquire), block.capacity)
		for i in 0 ..< n {
			pid := PID(sync.atomic_load_explicit(&block.pids[i], .Acquire))
			if pid != 0 && pid != self_pid do _ = send_message(pid, msg)
		}
	}

	type_hash, hash_ok := get_actor_type_hash(actor_type)
	if !hash_ok {
		log.warnf(
			"broadcast: no registered type name hash for actor type %d, local subscribers were served but remote nodes were skipped",
			actor_type,
			location = loc,
		)
		return
	}

	for node_id in 2 ..< u16(MAX_NODES) {
		if sync.atomic_load_explicit(&list.remote_node_sub_count[node_id], .Acquire) > 0 {
			send_broadcast_to_node(Node_ID(node_id), type_hash, msg)
		}
	}
}

@(private)
send_broadcast_to_node :: proc(node_id: Node_ID, actor_type_hash: u64, msg: $T) {
	from_handle, _ := unpack_pid(get_self_pid())
	broadcast_handle := transmute(Handle)actor_type_hash

	p_flags := Network_Message_Flags{}

	ring := ensure_ring_for_node(node_id)
	if ring == nil {
		node_name, name_ok := get_node_name(node_id)
		if name_ok {
			log.warnf("Broadcast to node '%s' (%d) dropped, no connection ring", node_name, node_id)
		} else {
			log.warnf("Broadcast to node %d dropped, no connection ring", node_id)
		}
		return
	}

	buf: [((size_of(T) + WIRE_FORMAT_OVERHEAD + 63) / 64) * 64]byte

	msg_len := build_wire_format_into_buffer(
		buf[:],
		msg,
		broadcast_handle,
		from_handle,
		p_flags | {.BROADCAST},
		"",
	)
	if msg_len > 0 {
		if !batch_append_message_retry(ring, buf[:msg_len]) {
			log.warnf("Broadcast to node %d dropped, ring full", node_id)
		}
	}
}

get_subscriber_count :: proc(actor_type: Actor_Type) -> u32 {
	if actor_type == ACTOR_TYPE_UNTYPED do return 0
	return sync.atomic_load_explicit(&NODE.type_subscribers[actor_type].count, .Acquire)
}

announce_subscriptions_to_node :: proc(node_id: Node_ID) {
	ring := get_connection_ring(node_id)
	if ring == nil do return
	for type_idx in 1 ..< MAX_ACTOR_TYPES {
		list := &NODE.type_subscribers[Actor_Type(type_idx)]
		block := load_subscriber_block(list)
		if block == nil do continue
		n := min(sync.atomic_load_explicit(&list.local_count, .Acquire), block.capacity)
		if n == 0 do continue
		type_hash, hash_ok := get_actor_type_hash(Actor_Type(type_idx))
		if !hash_ok do continue
		send_lifecycle_message(ring, Subscribe_Remote{type_name_hash = type_hash, count = n})
	}
}

handle_remote_subscribe :: proc(msg: Subscribe_Remote, from_node: Node_ID) {
	local_type, found := get_actor_type_by_hash(msg.type_name_hash)
	if !found {
		log.warnf("Unknown actor type hash for subscribe: %x", msg.type_name_hash)
		return
	}

	if from_node == 0 || from_node >= MAX_NODES do return

	if msg.count == 0 do return

	list := &NODE.type_subscribers[local_type]
	sync.atomic_add_explicit(&list.remote_node_sub_count[from_node], msg.count, .Release)
	sync.atomic_add_explicit(&list.count, msg.count, .Release)
}

handle_remote_unsubscribe :: proc(msg: Unsubscribe_Remote, from_node: Node_ID) {
	local_type, found := get_actor_type_by_hash(msg.type_name_hash)
	if !found do return

	if from_node == 0 || from_node >= MAX_NODES do return

	list := &NODE.type_subscribers[local_type]
	current := sync.atomic_load_explicit(&list.remote_node_sub_count[from_node], .Acquire)
	removed := min(msg.count, current)
	if removed > 0 {
		sync.atomic_sub_explicit(&list.remote_node_sub_count[from_node], removed, .Release)
		sync.atomic_sub_explicit(&list.count, removed, .Release)
	}
}

clear_subscriptions_for_node :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id == NODE.node_id || node_id >= MAX_NODES do return

	for type_idx in 0 ..< MAX_ACTOR_TYPES {
		list := &NODE.type_subscribers[Actor_Type(type_idx)]
		remote_count := sync.atomic_load_explicit(&list.remote_node_sub_count[node_id], .Acquire)
		if remote_count > 0 {
			sync.atomic_store_explicit(&list.remote_node_sub_count[node_id], 0, .Release)
			sync.atomic_sub_explicit(&list.count, remote_count, .Release)
		}
	}
}

clear_all_subscriptions :: proc() {
	for type_idx in 0 ..< MAX_ACTOR_TYPES {
		clear_type_subscriber_list(&NODE.type_subscribers[Actor_Type(type_idx)])
	}
}

@(private)
clear_type_subscriber_list :: proc(list: ^Type_Subscriber_List) {
	assert(
		sync.atomic_load(&NODE.shutting_down),
		"clear_type_subscriber_list frees blocks a live broadcaster may still hold, it is only safe once the node is shutting down and its actors have been joined",
	)
	sync.mutex_lock(&list.mutate_lock)
	block := list.block
	sync.atomic_store_explicit(cast(^u64)&list.block, 0, .Release)
	sync.atomic_store_explicit(&list.local_count, 0, .Release)
	sync.atomic_store_explicit(&list.count, 0, .Release)
	for node_id in 0 ..< MAX_NODES {
		sync.atomic_store_explicit(&list.remote_node_sub_count[node_id], 0, .Release)
	}
	sync.mutex_unlock(&list.mutate_lock)
	free_subscriber_blocks(block)
}

@(require_results)
subscribe_topic :: proc(topic: ^Topic, loc := #caller_location) -> (Topic_Subscription, bool) {
	if topic == nil {
		log.warn(
			"subscribe_topic called with a nil topic, no subscription was created",
			location = loc,
		)
		return {}, false
	}

	when ODIN_TEST {
		if ti.intercept_subscribe_topic(topic) {
			return Topic_Subscription{topic = topic, pid = get_self_pid()}, true
		}
	}

	if current_actor_context == nil {
		log.warn(
			"subscribe_topic must be called from within an actor, the subscription was not created",
			location = loc,
		)
		return {}, false
	}
	pid := get_self_pid()

	for {
		idx := sync.atomic_load_explicit(&topic.count, .Acquire)
		if idx >= MAX_TOPIC_SUBSCRIBERS {
			log.warnf(
				"Topic subscriber list full, cap is %d (MAX_TOPIC_SUBSCRIBERS), subscription dropped",
				MAX_TOPIC_SUBSCRIBERS,
				location = loc,
			)
			return {}, false
		}

		slot := cast(^u64)&topic.subscribers[idx]
		if _, swapped := sync.atomic_compare_exchange_strong_explicit(
			slot,
			0,
			u64(pid),
			.Acq_Rel,
			.Acquire,
		); swapped {
			sync.atomic_add_explicit(&topic.count, 1, .Release)

			sub := Topic_Subscription {
				topic = topic,
				pid   = pid,
			}

			if current_actor_context != nil {
				append(&current_actor_context.topic_subscriptions, sub)
			}

			return sub, true
		}
	}
}

@(require_results)
unsubscribe_topic :: proc(sub: Topic_Subscription, loc := #caller_location) -> bool {
	if sub.topic == nil || sub.pid == 0 {
		log.warn(
			"unsubscribe_topic: subscription has no topic or no PID, it was never successfully created by subscribe_topic",
			location = loc,
		)
		return false
	}

	if !topic_remove_subscriber(sub.topic, sub.pid) {
		log.warnf(
			"unsubscribe_topic: PID %v is not subscribed to this topic, it may already have been unsubscribed",
			sub.pid,
			location = loc,
		)
		return false
	}

	if current_actor_context != nil {
		for i := 0; i < len(current_actor_context.topic_subscriptions); i += 1 {
			s := current_actor_context.topic_subscriptions[i]
			if s.topic == sub.topic && s.pid == sub.pid {
				unordered_remove(&current_actor_context.topic_subscriptions, i)
				break
			}
		}
	}

	return true
}

publish :: proc(topic: ^Topic, msg: $T, loc := #caller_location) {
	if topic == nil {
		log.warn("publish called with a nil topic, the message was discarded", location = loc)
		return
	}

	when ODIN_TEST {if ok := ti.intercept_publish(topic, msg); ok do return}

	self_pid := get_self_pid()
	n := sync.atomic_load_explicit(&topic.count, .Acquire)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[i], .Acquire))
		if pid != 0 && pid != self_pid do _ = send_message(pid, msg)
	}
}

@(private)
topic_remove_subscriber :: proc(topic: ^Topic, pid: PID) -> bool {
	if topic == nil || pid == 0 do return false

	n := sync.atomic_load_explicit(&topic.count, .Acquire)

	for i in 0 ..< n {
		slot := cast(^u64)&topic.subscribers[i]
		if PID(sync.atomic_load_explicit(slot, .Acquire)) == pid {
			last := n - 1
			if i != last {
				last_pid := sync.atomic_load_explicit(cast(^u64)&topic.subscribers[last], .Acquire)
				sync.atomic_store_explicit(slot, last_pid, .Release)
			}
			sync.atomic_store_explicit(cast(^u64)&topic.subscribers[last], 0, .Release)
			sync.atomic_sub_explicit(&topic.count, 1, .Release)
			return true
		}
	}
	return false
}
