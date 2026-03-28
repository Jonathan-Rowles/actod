package actod

import "../../test_harness/ti"
_ :: ti
import "core:log"
import "core:sync"

MAX_SUBSCRIBERS_PER_TYPE :: 16384
MAX_TOPIC_SUBSCRIBERS :: 64

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

Type_Subscriber_List :: struct {
	subscribers:           [MAX_SUBSCRIBERS_PER_TYPE]PID,
	count:                 u32,
	local_count:           u32,
	remote_node_sub_count: [MAX_NODES]u32,
}

type_subscribers: [MAX_ACTOR_TYPES]Type_Subscriber_List

@(private)
add_subscriber :: proc(actor_type: Actor_Type, pid: PID) -> bool {
	if actor_type == ACTOR_TYPE_UNTYPED || pid == 0 {
		return false
	}

	list := &type_subscribers[actor_type]

	for {
		idx := sync.atomic_load_explicit(&list.local_count, .Acquire)
		if idx >= MAX_SUBSCRIBERS_PER_TYPE {
			log.warnf("Subscriber list full for actor type %d", actor_type)
			return false
		}

		slot := cast(^u64)&list.subscribers[idx]
		if _, swapped := sync.atomic_compare_exchange_strong_explicit(
			slot,
			0,
			u64(pid),
			.Acq_Rel,
			.Acquire,
		); swapped {
			sync.atomic_add_explicit(&list.local_count, 1, .Release)
			sync.atomic_add_explicit(&list.count, 1, .Release)
			return true
		}
	}
}

@(private)
remove_subscriber :: proc(actor_type: Actor_Type, pid: PID) -> bool {
	if actor_type == ACTOR_TYPE_UNTYPED || pid == 0 {
		return false
	}

	list := &type_subscribers[actor_type]
	n := sync.atomic_load_explicit(&list.local_count, .Acquire)

	for i in 0 ..< n {
		slot := cast(^u64)&list.subscribers[i]
		if PID(sync.atomic_load_explicit(slot, .Acquire)) == pid {
			last := n - 1
			if i != last {
				last_pid := sync.atomic_load_explicit(cast(^u64)&list.subscribers[last], .Acquire)
				sync.atomic_store_explicit(slot, last_pid, .Release)
			}
			sync.atomic_store_explicit(cast(^u64)&list.subscribers[last], 0, .Release)
			sync.atomic_sub_explicit(&list.local_count, 1, .Release)
			sync.atomic_sub_explicit(&list.count, 1, .Release)
			return true
		}
	}
	return false
}

subscribe_type :: proc(actor_type: Actor_Type) -> (Subscription, bool) {
	when ODIN_TEST {
		if ti.intercept_subscribe_type(u8(actor_type)) {
			return Subscription{actor_type = actor_type, pid = get_self_pid()}, true
		}
	}

	if actor_type == ACTOR_TYPE_UNTYPED {
		log.warn("Cannot subscribe to ACTOR_TYPE_UNTYPED")
		return {}, false
	}

	pid := get_self_pid()
	if pid == 0 {
		log.warn("subscribe_type must be called from within an actor")
		return {}, false
	}

	if !add_subscriber(actor_type, pid) {
		return {}, false
	}

	sub := Subscription {
		actor_type = actor_type,
		pid        = pid,
	}

	if current_actor_context != nil {
		append(&current_actor_context.subscriptions, sub)
	}

	type_hash, hash_ok := get_actor_type_hash(actor_type)
	if hash_ok {
		broadcast_to_all_nodes(Subscribe_Remote{subscriber_pid = pid, type_name_hash = type_hash})
	}

	return sub, true
}

pubsub_unsubscribe :: proc(sub: Subscription) -> bool {
	if sub.pid == 0 {
		return false
	}

	removed := remove_subscriber(sub.actor_type, sub.pid)
	if !removed {
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
		broadcast_to_all_nodes(
			Unsubscribe_Remote{subscriber_pid = sub.pid, type_name_hash = type_hash},
		)
	}

	return true
}

broadcast :: proc(msg: $T) {
	when ODIN_TEST {if ti.intercept_broadcast(msg) do return}

	self_pid := get_self_pid()
	actor_type := get_pid_actor_type(self_pid)

	if actor_type == ACTOR_TYPE_UNTYPED {
		log.warn("broadcast() called from untyped actor")
		return
	}

	list := &type_subscribers[actor_type]
	n := sync.atomic_load_explicit(&list.local_count, .Acquire)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&list.subscribers[i], .Acquire))
		if pid != 0 && pid != self_pid {
			send_message(pid, msg)
		}
	}

	type_hash, hash_ok := get_actor_type_hash(actor_type)
	if !hash_ok {
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

	p_flags := priority_to_flags(
		current_actor_context != nil ? current_actor_context.send_priority : .NORMAL,
	)

	ring := get_connection_ring(node_id)
	if ring != nil && ring.state == .Ready {
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
			if batch_append_message(ring, buf[:msg_len]) {
				return
			}
		}
	}

	conn_pid := get_or_create_connection(node_id)
	if conn_pid == 0 {
		return
	}
	build_and_send_network_command(conn_pid, msg, p_flags | {.BROADCAST}, broadcast_handle, "")
}

get_subscriber_count :: proc(actor_type: Actor_Type) -> u32 {
	if actor_type == ACTOR_TYPE_UNTYPED {
		return 0
	}
	return sync.atomic_load_explicit(&type_subscribers[actor_type].count, .Acquire)
}

handle_remote_subscribe :: proc(msg: Subscribe_Remote, from_node: Node_ID) {
	local_type, found := get_actor_type_by_hash(msg.type_name_hash)
	if !found {
		log.warnf("Unknown actor type hash for subscribe: %x", msg.type_name_hash)
		return
	}

	if from_node == 0 || from_node >= MAX_NODES {
		return
	}

	list := &type_subscribers[local_type]
	sync.atomic_add_explicit(&list.remote_node_sub_count[from_node], 1, .Release)
	sync.atomic_add_explicit(&list.count, 1, .Release)
}

handle_remote_unsubscribe :: proc(msg: Unsubscribe_Remote, from_node: Node_ID) {
	local_type, found := get_actor_type_by_hash(msg.type_name_hash)
	if !found {
		return
	}

	if from_node == 0 || from_node >= MAX_NODES {
		return
	}

	list := &type_subscribers[local_type]
	current := sync.atomic_load_explicit(&list.remote_node_sub_count[from_node], .Acquire)
	if current > 0 {
		sync.atomic_sub_explicit(&list.remote_node_sub_count[from_node], 1, .Release)
		sync.atomic_sub_explicit(&list.count, 1, .Release)
	}
}

clear_subscriptions_for_node :: proc(node_id: Node_ID) {
	if node_id == 0 || node_id == current_node_id || node_id >= MAX_NODES {
		return
	}

	for type_idx in 0 ..< MAX_ACTOR_TYPES {
		list := &type_subscribers[Actor_Type(type_idx)]
		remote_count := sync.atomic_load_explicit(&list.remote_node_sub_count[node_id], .Acquire)
		if remote_count > 0 {
			sync.atomic_store_explicit(&list.remote_node_sub_count[node_id], 0, .Release)
			sync.atomic_sub_explicit(&list.count, remote_count, .Release)
		}
	}
}

clear_all_subscriptions :: proc() {
	for type_idx in 0 ..< MAX_ACTOR_TYPES {
		list := &type_subscribers[Actor_Type(type_idx)]
		for i in 0 ..< MAX_SUBSCRIBERS_PER_TYPE {
			sync.atomic_store_explicit(cast(^u64)&list.subscribers[i], 0, .Release)
		}
		for node_id in 0 ..< MAX_NODES {
			sync.atomic_store_explicit(&list.remote_node_sub_count[node_id], 0, .Release)
		}
		sync.atomic_store_explicit(&list.local_count, 0, .Release)
		sync.atomic_store_explicit(&list.count, 0, .Release)
	}
}

subscribe_topic :: proc(topic: ^Topic) -> (Topic_Subscription, bool) {
	if topic == nil {
		return {}, false
	}

	when ODIN_TEST {
		if ti.intercept_subscribe_topic(topic) {
			return Topic_Subscription{topic = topic, pid = get_self_pid()}, true
		}
	}

	pid := get_self_pid()
	if pid == 0 {
		log.warn("subscribe_topic must be called from within an actor")
		return {}, false
	}

	for {
		idx := sync.atomic_load_explicit(&topic.count, .Acquire)
		if idx >= MAX_TOPIC_SUBSCRIBERS {
			log.warn("Topic subscriber list full")
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

unsubscribe_topic :: proc(sub: Topic_Subscription) -> bool {
	if sub.topic == nil || sub.pid == 0 {
		return false
	}

	if !topic_remove_subscriber(sub.topic, sub.pid) {
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

publish :: proc(topic: ^Topic, msg: $T) {
	if topic == nil {
		return
	}

	when ODIN_TEST {if ok := ti.intercept_publish(topic, msg); ok do return}

	self_pid := get_self_pid()
	n := sync.atomic_load_explicit(&topic.count, .Acquire)

	for i in 0 ..< n {
		pid := PID(sync.atomic_load_explicit(cast(^u64)&topic.subscribers[i], .Acquire))
		if pid != 0 && pid != self_pid {
			send_message(pid, msg)
		}
	}
}

@(private)
topic_remove_subscriber :: proc(topic: ^Topic, pid: PID) -> bool {
	if topic == nil || pid == 0 {
		return false
	}

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
