package main

import act "../"
import "core:log"
import "core:time"

Tell_Joke :: struct {
	joke: string,
}

Heckle :: struct {
	response: string,
}

@(init)
register_messages :: proc "contextless" () {
	act.register_message_type(Tell_Joke)
	act.register_message_type(Heckle)
}

Comedian :: struct {
	joke_index: int,
	audience:   act.PID,
}

jokes := [?]string {
	"Why do programmers prefer dark mode? Because light attracts bugs.",
	"There are only 10 types of people — those who understand binary and those who don't.",
	"A SQL query walks into a bar, sees two tables, and asks: 'Can I join you?'",
	"Why do Java developers wear glasses? Because they can't C#.",
	"I told my wife she was drawing her eyebrows too high. She looked surprised.",
	"Parallel lines have so much in common. It's a shame they'll never meet.",
}

comedian_behaviour := act.Actor_Behaviour(Comedian) {
	init = proc(d: ^Comedian) {
		log.debugf("Comedian warming up the crowd...")
		act.send_message(d.audience, Tell_Joke{joke = jokes[0]})
	},
	handle_message = proc(d: ^Comedian, from: act.PID, msg: any) {
		switch m in msg {
		case Heckle:
			log.warnf("Heckled: \"%s\"", m.response)
			d.joke_index += 1
			if d.joke_index < len(jokes) {
				act.send_message(from, Tell_Joke{joke = jokes[d.joke_index]})
			} else {
				log.errorf("I'm out of material. Goodnight!")
				act.self_terminate()
			}
		}
	},
}

Audience :: struct {
	jokes_heard: int,
}

heckles := [?]string {
	"Booooo! My compiler tells better jokes!",
	"I've seen better error messages!",
	"That joke segfaulted my brain!",
	"Even my linter is funnier than you!",
	"I'd rather read man pages!",
	"That's it, I'm mass git reverting your commits!",
}

audience_behaviour := act.Actor_Behaviour(Audience) {
	init = proc(d: ^Audience) {
		log.infof("Audience takes their seats...")
	},
	handle_message = proc(d: ^Audience, from: act.PID, msg: any) {
		switch m in msg {
		case Tell_Joke:
			log.infof("Joke: \"%s\"", m.joke)
			response := heckles[d.jokes_heard % len(heckles)]
			d.jokes_heard += 1
			act.send_message(from, Heckle{response = response})
		}
	},
}

spawn_audience :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
	return act.spawn(
		"audience",
		Audience{},
		audience_behaviour,
		act.make_actor_config(
			logging = act.make_log_config(
				level = .Info,
				ident = "audience",
				console_opts = {.Level},
			),
		),
	)
}

spawn_comedian :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
	audience_pid, ok := act.get_actor_pid("audience")
	if !ok {return 0, false}

	return act.spawn(
		"comedian",
		Comedian{audience = audience_pid},
		comedian_behaviour,
		act.make_actor_config(
			logging = act.make_log_config(
				level = .Debug,
				ident = "comedian",
				console_opts = log.Options{.Level, .Terminal_Color, .Short_File_Path, .Line} |
				log.Full_Timestamp_Opts,
			),
		),
	)
}

main :: proc() {
	act.NODE_INIT(
		"comedy-club",
		act.make_node_config(
			actor_config = act.make_actor_config(
				children = act.make_children(spawn_audience, spawn_comedian),
			),
		),
	)

	time.sleep(1 * time.Second)

	act.SHUTDOWN_NODE()
}
