package hooked

import act "../../../../.."
import "base:runtime"
import "core:sync"
import "core:time"

FOREIGN_WAIT_LIMIT :: 15 * time.Second

Hooked :: struct {
	idle_entered: ^sync.Sema,
	wake:         ^sync.Sema,
	handled:      ^sync.Sema,
}

hooked_idle :: proc(d: ^Hooked) {
	sync.sema_post(d.idle_entered)
	sync.sema_wait_with_timeout(d.wake, FOREIGN_WAIT_LIMIT)
}

hooked_wake :: proc "contextless" (d: ^Hooked) {
	sync.sema_post(d.wake)
}

hooked_handle :: proc(d: ^Hooked, from: act.PID, msg: any) {
	sync.sema_post(d.handled)
}

hooked_behaviour := act.Actor_Behaviour(Hooked) {
	handle_message = hooked_handle,
	on_idle        = hooked_idle,
	on_wake        = hooked_wake,
}

@(export)
spawn_hooked :: proc "c" (idle_entered: ^sync.Sema, wake: ^sync.Sema, handled: ^sync.Sema) -> u64 {
	context = runtime.default_context()
	pid, _ := act.spawn(
		"hooked",
		Hooked{idle_entered = idle_entered, wake = wake, handled = handled},
		hooked_behaviour,
		act.make_actor_config(use_dedicated_os_thread = true),
	)
	return u64(pid)
}
