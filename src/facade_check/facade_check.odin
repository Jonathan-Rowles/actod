package facade_check

import act "../.."
import "core:time"

Probe :: struct {
	n: int,
}

Probe_Note :: struct {
	text: string,
}

@(init)
register_probe_messages :: proc "contextless" () {
	act.register_message_type(Probe_Note)
}

probe_topic: act.Topic

probe_behaviour := act.Actor_Behaviour(Probe) {
	handle_message = proc(d: ^Probe, from: act.PID, msg: any) {
		switch m in msg {
		case Probe_Note:
			d.n += 1
			_ = act.send(from, d.n)
			_ = act.send("probe-child", m)
			_ = act.send_self(d.n)
			_ = act.send_parent(d.n)
			_ = act.send_children(d.n)
			_ = act.reply(d.n)
			_, _ = act.ask(from, d.n, 1 * time.Second)
			_, _ = act.replying_to()
			_, _ = act.spawn_child("probe-child", Probe{}, probe_behaviour)
			_, _ = act.spawn_child("probe-child-sized", Probe{}, probe_behaviour, 128)
			_, _ = act.set_timer(1 * time.Second, false)
			act.broadcast(d.n)
			act.publish(&probe_topic, d.n)
		case act.Timer_Tick:
			_ = act.cancel_timer(m.id)
		case act.Ask_Timeout:
			_ = act.terminate()
		}
	},
	init = proc(d: ^Probe) {
		_, _ = act.subscribe(&probe_topic)
	},
}

spawn_probe :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
	actor_name := name if name != "" else "probe"
	return act.spawn(actor_name, Probe{}, probe_behaviour, parent_pid = parent)
}

exercise :: proc() {
	sized_config := act.make_actor_config(arena_headroom = 4 * 1024 * 1024)
	p1, _ := act.spawn("probe-default", Probe{}, probe_behaviour)
	p2, _ := act.spawn("probe-sized", Probe{}, probe_behaviour, 256)
	p3, _ := act.spawn("probe-sized-opts", Probe{}, probe_behaviour, 512, sized_config)
	_ = act.send(p1, Probe_Note{text = "hello"})
	_ = act.send_to("probe-sized", "node", 1)
	_ = act.terminate(p2)
	_ = act.rename(p3, "probe-renamed")
}

main :: proc() {
	act.node_init(
		"facade-check",
		act.make_node_config(
			actor_config = act.make_actor_config(children = act.make_children(spawn_probe)),
		),
	)
	exercise()
	act.node_shutdown()
}
