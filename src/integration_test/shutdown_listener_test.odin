package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

SHUTDOWN_LISTENER_PORT :: 17620

shutdown_listener_watcher_stopped: bool
shutdown_listener_stopped_before_watcher: bool

Shutdown_Listener_Watcher :: struct {}

shutdown_listener_watcher_handle :: proc(
	data: ^Shutdown_Listener_Watcher,
	from: actod.PID,
	msg: any,
) {}

shutdown_listener_watcher_terminate :: proc(data: ^Shutdown_Listener_Watcher) {
	sync.atomic_store(
		&shutdown_listener_stopped_before_watcher,
		actod.NODE.network_listener_thread == nil,
	)
	sync.atomic_store(&shutdown_listener_watcher_stopped, true)
}

Shutdown_Listener_Watcher_Behaviour :: actod.Actor_Behaviour(
	Shutdown_Listener_Watcher,
) {
	handle_message = shutdown_listener_watcher_handle,
	terminate      = shutdown_listener_watcher_terminate,
}

test_shutdown_stops_the_listener_before_user_actors :: proc(t: ^testing.T) {
	sync.atomic_store(&shutdown_listener_watcher_stopped, false)
	sync.atomic_store(&shutdown_listener_stopped_before_watcher, false)

	if !expectf(
		t,
		poll_until(listener_running, nil, 5 * time.Second),
		"the node's listener is running on port %d before shutdown",
		SHUTDOWN_LISTENER_PORT,
	) {
		return
	}

	_, spawned := actod.spawn(
		"shutdown-listener-watcher",
		Shutdown_Listener_Watcher{},
		Shutdown_Listener_Watcher_Behaviour,
	)
	if !expect(t, spawned, "the watcher actor spawned") do return

	actod.shutdown_node()

	expect(
		t,
		sync.atomic_load(&shutdown_listener_watcher_stopped),
		"shutdown stopped the watcher actor",
	)
	expect(
		t,
		sync.atomic_load(&shutdown_listener_stopped_before_watcher),
		"the network listener was still running when shutdown stopped a user actor",
	)
}
