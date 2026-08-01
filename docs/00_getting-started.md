# Getting Started

## The Minimal Program

The shape to start from: actors are children of the node, and `main` does nothing but build the config, call `node_init`, and wait. Children get a supervisor for free: if an actor crashes, the node restarts it.

```odin
package main

import act "actod"
import "core:log"

Add :: struct {
	amount: int,
}

@(init)
register_messages :: proc "contextless" () {
	act.register_message_type(Add)
}

Counter :: struct {
	total: int,
}

counter_behaviour := act.Actor_Behaviour(Counter) {
	init = proc(d: ^Counter) {
		_ = act.send_self(Add{amount = 42})
	},
	handle_message = proc(d: ^Counter, from: act.PID, msg: any) {
		switch m in msg {
		case Add:
			d.total += m.amount
			log.infof("total: %d", d.total)
		}
	},
}

spawn_counter :: proc(_: string, _: act.PID) -> (act.PID, bool) {
	return act.spawn("counter", Counter{}, counter_behaviour)
}

main :: proc() {
	act.node_init("hello", act.make_node_config(
		actor_config = act.make_actor_config(
			children = act.make_children(spawn_counter),
		),
	))
	act.await_signal()
}
```

`main` never spawns or sends; the actor kicks itself off in `init`. Growing the app means adding spawn functions to `make_children`, the shape does not change. Everything else defaults: no logging, networking, or supervision settings are needed until you want to override them.

## The Full Example

A complete example: two actors playing ping-pong with increasingly absurd jokes. See [comedy_club.odin](comedy_club.odin) for the full runnable source.

## Running

```bash
cd docs
odin run .
```

## What The Example Shows

- **Two actors communicating**: Comedian sends `Tell_Joke`, Audience replies with `Heckle`
- **Message registration**: `Tell_Joke` and `Heckle` contain strings, so they're registered with `@(init)`
- **Per-actor logging**: Comedian uses colored terminal output via `console_opts`, Audience uses default logging: each actor has its own log config
- **Supervision**: Both actors are children of the node: spawned in order via `make_children`
- **Actor lookup**: Comedian finds Audience by name with `get_actor_pid`
- **Self-termination**: Comedian calls `act.self_terminate()` when out of jokes
- **Spawn functions**: Children are defined as `SPAWN` procs so the supervisor can recreate them

## Next Steps

- [Node](01_node.md): system lifecycle, design philosophy, and memory model
- [Actor](02_actor.md): full actor API
- [Message Registration](03_message-registration.md): when and why to register types
- [Supervisor](04_supervisor.md): restart strategies and child management
- [Delivery Semantics](14_delivery-semantics.md): what a send result does and does not promise
- [Test Harness](13_test-harness.md): unit and simulation testing

---
[Node >](01_node.md)
