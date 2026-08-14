package hot_check

import act "../../../.."
import "core:log"
import "core:net"
import "core:time"

Probe :: struct {
	n: int,
}

Note :: struct {
	text: string,
}

probe_topic: act.Topic

@(init)
register_hot_check_messages :: proc "contextless" () {
	act.register_message_type(Note)
}

probe_behaviour := act.Actor_Behaviour(Probe) {
	init           = probe_init,
	handle_message = probe_handle_message,
	terminate      = probe_terminate,
}

spawn_probe :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
	actor_name := name if name != "" else "probe"
	return act.spawn(actor_name, Probe{}, probe_behaviour, parent_pid = parent)
}

probe_init :: proc(d: ^Probe) {
	timer_id, _ := act.set_timer(1 * time.Second, true)
	_ = act.cancel_timer(timer_id)
	_, _ = act.subscribe(&probe_topic)
	_, _ = act.subscribe_topic(&probe_topic)
	_, _ = act.subscribe_to_stats()
	log.info("probe started", act.get_self_name(), act.get_self_pid(), act.get_parent_pid())
}

probe_handle_message :: proc(d: ^Probe, from: act.PID, msg: any) {
	switch m in msg {
	case Note:
		d.n += 1
		_ = act.send(from, d.n)
		_ = act.send("probe-child", m)
		_ = act.send_message(from, d.n)
		_ = act.send_message_name("probe-child", d.n)
		_ = act.send_unreliable(from, d.n)
		_ = act.send_self(d.n)
		_ = act.send_parent(d.n)
		_ = act.send_children(d.n)
		_, _ = act.replying_to()
		_, _ = act.spawn_child("probe-child", Probe{}, probe_behaviour)
		_, _ = act.spawn_child_default("probe-child-2", Probe{}, probe_behaviour)
		act.broadcast(d.n)
		act.publish(&probe_topic, d.n)
		act.yield()
	case act.Timer_Tick:
		_ = act.self_rename("probe-renamed")
		_ = act.rename("probe-renamed-again")
		_ = act.self_terminate()
		_ = act.terminate()
	}
}

probe_terminate :: proc(d: ^Probe) {
	log.info("probe stopping at", act.now())
}

exercise_node_api :: proc() {
	act.node_init("hot-check", act.make_node_config(
		actor_config = act.make_actor_config(logging = act.make_log_config()),
		network = act.make_network_config(),
	))

	p1, _ := act.spawn("probe-1", Probe{}, probe_behaviour)
	p2, _ := act.spawn_default("probe-2", Probe{}, probe_behaviour)
	_ = act.send(p1, Note{text = "hello"})

	_ = act.register_spawn_func("spawn_probe", spawn_probe)
	_, _ = act.spawn_by_name("spawn_probe", "probe-3")
	_, _ = act.spawn_remote("spawn_probe", "probe-4", "other-node")

	pid, found := act.get_actor_pid("probe-1")
	if found do log.info(act.get_actor_name(pid), act.is_local_pid(pid), act.get_node_id(pid))
	handle, node_id := act.unpack_pid(pid)
	_ = act.pack_pid(handle, node_id)
	_ = act.get_actor_type(pid)

	_ = act.terminate_actor(p2)
	_ = act.rename_actor(p1, "probe-one")
	_ = act.terminate(p2)
	_ = act.rename(p1, "probe-one-again")

	children := act.get_children(p1)
	_, _ = act.add_child(p1, spawn_probe)
	if len(children) > 0 {
		_, _ = act.adopt_child(p1, children[0], spawn_probe)
		_ = act.remove_child(p1, children[0])
	}

	actor_type, _ := act.register_actor_type("probe")
	_, _ = act.get_actor_type_name(actor_type)
	sub, _ := act.subscribe_type(actor_type)
	_, _ = act.subscribe(actor_type)
	_ = act.unsubscribe_type(sub)
	_ = act.unsubscribe(sub)
	_ = act.get_subscriber_count(actor_type)

	topic_sub, topic_ok := act.subscribe_topic(&probe_topic)
	if topic_ok {
		_ = act.unsubscribe_topic(topic_sub)
		_ = act.unsubscribe(topic_sub)
	}

	transport: act.Transport_Strategy
	remote_node, _ := act.register_node("other-node", net.Endpoint{}, transport)
	_, _ = act.get_node_info(remote_node)
	_, _ = act.get_node_by_name("other-node")
	act.unregister_node(remote_node)
	log.info(act.get_local_node_pid(), act.get_local_node_name())

	_, _ = act.start_observer()
	_ = act.trigger_stats_collection()
	_ = act.request_actor_stats(p1, p1)
	_ = act.request_all_stats(p1)
	_ = act.set_stats_collection_interval(1 * time.Second)
	_ = act.clear_terminated_stats()
	stats_sub, _ := act.subscribe_to_stats()
	_ = act.unsubscribe_from_stats(stats_sub)
	act.stop_observer()

	act.set_log_level(.Info)
	_ = act.is_log_level_enabled(.Info)
	_ = act.get_current_log_config()
	_ = act.get_node_log_ctx()

	act.sim_seed(0)
	_ = act.sim_pump()
	_ = act.sim_run_until_idle()

	act.await_signal()
	act.node_shutdown()
}
