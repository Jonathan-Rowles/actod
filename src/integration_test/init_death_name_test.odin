package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

INIT_DEATH_CHILD_NAME :: "init-death-child"
INIT_DEATH_SURVIVING_INCARNATION :: 3

init_death_incarnations: int
init_death_ping_incarnation: int
init_death_ping_pid: u64
init_death_dedicated_thread: bool

Init_Death_Ping :: struct {
	token: int,
}

Init_Death_Child :: struct {
	incarnation: int,
}

init_death_child_init :: proc(data: ^Init_Death_Child) {
	data.incarnation = sync.atomic_add(&init_death_incarnations, 1) + 1
	if data.incarnation < INIT_DEATH_SURVIVING_INCARNATION do panic("dying in init")
}

init_death_child_handle :: proc(data: ^Init_Death_Child, from: actod.PID, msg: any) {
	if _, ok := msg.(Init_Death_Ping); !ok do return
	sync.atomic_store(&init_death_ping_pid, u64(actod.get_self_pid()))
	sync.atomic_store(&init_death_ping_incarnation, data.incarnation)
}

Init_Death_Child_Behaviour :: actod.Actor_Behaviour(Init_Death_Child) {
	init           = init_death_child_init,
	handle_message = init_death_child_handle,
}

Init_Death_Sup :: struct {}

init_death_sup_handle :: proc(data: ^Init_Death_Sup, from: actod.PID, msg: any) {}

Init_Death_Sup_Behaviour :: actod.Actor_Behaviour(Init_Death_Sup) {
	handle_message = init_death_sup_handle,
}

spawn_init_death_child :: proc(name: string, parent: actod.PID) -> (actod.PID, bool) {
	actor_name := name if name != "" else INIT_DEATH_CHILD_NAME
	return actod.spawn(
		actor_name,
		Init_Death_Child{},
		Init_Death_Child_Behaviour,
		actod.make_actor_config(
			logging = actod.make_log_config(level = test_log_level()),
			use_dedicated_os_thread = sync.atomic_load(&init_death_dedicated_thread),
		),
		parent,
	)
}

spawn_init_death_sup :: proc(name: string, parent: actod.PID) -> (actod.PID, bool) {
	return actod.spawn(
		"init-death-sup",
		Init_Death_Sup{},
		Init_Death_Sup_Behaviour,
		actod.make_actor_config(
			logging = actod.make_log_config(level = test_log_level()),
			children = actod.make_children(spawn_init_death_child),
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .TRANSIENT,
			max_restarts = 5,
			restart_window = 10 * time.Second,
		),
		parent,
	)
}

init_death_named_send_lands :: proc(state: rawptr) -> bool {
	if actod.send_message_name(INIT_DEATH_CHILD_NAME, Init_Death_Ping{token = 1}) != .OK do return false
	return sync.atomic_load(&init_death_ping_incarnation) == INIT_DEATH_SURVIVING_INCARNATION
}

run_init_death_name_test :: proc(t: ^testing.T, node_name: string, dedicated_thread: bool) {
	reset_test_state()
	sync.atomic_store(&init_death_incarnations, 0)
	sync.atomic_store(&init_death_ping_incarnation, 0)
	sync.atomic_store(&init_death_ping_pid, 0)
	sync.atomic_store(&init_death_dedicated_thread, dedicated_thread)

	restart_node_with(node_name, actod.make_children(spawn_init_death_sup), 3)
	wait_for_node()

	landed := poll_until(init_death_named_send_lands, nil, 3 * time.Second, time.Millisecond)
	expectf(
		t,
		landed,
		"a send by name must reach incarnation %d after two deaths in init, it reached %d",
		INIT_DEATH_SURVIVING_INCARNATION,
		sync.atomic_load(&init_death_ping_incarnation),
	)

	named_pid, found := actod.get_actor_pid(INIT_DEATH_CHILD_NAME)
	expect(t, found, "the restarted child must be findable by name")
	expect_value(t, u64(named_pid), sync.atomic_load(&init_death_ping_pid))

	actod.shutdown_node()
}

test_init_death_does_not_wedge_name_dedicated :: proc(t: ^testing.T) {
	run_init_death_name_test(t, "init-death-dedicated", true)
}

test_init_death_does_not_wedge_name_pooled :: proc(t: ^testing.T) {
	run_init_death_name_test(t, "init-death-pooled", false)
}
