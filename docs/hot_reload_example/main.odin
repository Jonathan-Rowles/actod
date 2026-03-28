package main

import act "../.."
import "hot_reload_actors/responder"
import "hot_reload_actors/sender"

main :: proc() {

	act.NODE_INIT(
		"hot-reload_test",
		act.make_node_config(
			hot_reload_dev = true,
			hot_reload_watch_path = "hot_reload_actors",
			actor_config = act.make_actor_config(
				children = act.make_children(
					responder.spawn_responder,
					sender.spawn_sender,
				),
			),
		),
	)

	act.await_signal()
}
