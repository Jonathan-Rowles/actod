package responder

import act "../../../.."
import "../../messages"
import "core:fmt"
import "core:log"
import "core:time"

Responder :: struct {
	received: int,
}

responder_behaviour := act.Actor_Behaviour(Responder) {
	init           = responder_init,
	handle_message = responder_handle_message,
}

spawn_responder :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
	return act.spawn("responder", Responder{}, responder_behaviour)
}

responder_init :: proc(d: ^Responder) {
	log.info("responder started")
	act.set_timer(3 * time.Second, true)
}

responder_handle_message :: proc(d: ^Responder, from: act.PID, msg: any) {
	switch m in msg {
	case messages.Ping:
		d.received += 1
		reply := fmt.tprintf("pong #%d", m.seq) // <- change this reply string
		log.infof("ping %d -> responding", m.seq) // <- change this log message
		act.send_message(from, messages.Pong{seq = m.seq, message = reply})
	case act.Timer_Tick:
		log.infof("status: %d pings received", d.received) // <- change this log message
		act.send_message(from, messages.Status_Report{sent = 0, received = d.received})
	}
}
