package actod

Hot_Reload_Hooks :: struct {
	spawn_child:    SPAWN,
	stop:           proc(),
	register_actor: proc(state: Erased_State, pid: PID, name: string),
	swap_behaviour: proc(actor: ^Actor, generation: u32),
}

hot_reload_hooks: Hot_Reload_Hooks
