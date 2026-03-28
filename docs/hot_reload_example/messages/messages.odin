package messages

import act "../../.."

Ping :: struct {
	seq: int,
}

Pong :: struct {
	seq:     int,
	message: string,
}

Status_Report :: struct {
	sent:     int,
	received: int,
}

@(init)
register_messages :: proc "contextless" () {
	act.register_message_type(Ping)
	act.register_message_type(Pong)
	act.register_message_type(Status_Report)
}
