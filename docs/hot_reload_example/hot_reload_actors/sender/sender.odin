package sender

import act "../../../.."
import "../../messages"
import "core:log"
import "core:time"

Sender :: struct {
	target: act.PID,
	seq:    int,
}

sender_behaviour := act.Actor_Behaviour(Sender) {
	init           = sender_init,
	handle_message = sender_handle_message,
}

spawn_sender :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
	responder_pid, ok := act.get_actor_pid("responder")
	if !ok {return 0, false}
	return act.spawn("sender", Sender{target = responder_pid}, sender_behaviour)
}

sender_init :: proc(d: ^Sender) {
	log.info("sender started")
	act.set_timer(1 * time.Second, true)
}

sender_handle_message :: proc(d: ^Sender, from: act.PID, msg: any) {
	switch m in msg {
	case act.Timer_Tick:
		d.seq += 1
		log.infof("sending ping %d", d.seq) // <- change this log message
		act.send_message(d.target, messages.Ping{seq = d.seq})
	case messages.Pong:
		log.infof("got pong %d: %s", m.seq, m.message) // <- change this log message
	}
}
