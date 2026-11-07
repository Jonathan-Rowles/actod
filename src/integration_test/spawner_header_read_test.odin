package integration

import "../actod"
import "base:intrinsics"
import "core:testing"
import "core:time"

SPAWNER_HEADER_ACTOR_NAME :: "spawner-header-init-panic"
SPAWNER_HEADER_POISON :: 0xA5
SPAWNER_HEADER_REUSE_BLOCKS :: 32
SPAWNER_HEADER_RECLAIM_BUDGET :: 2 * time.Second

Held_Spawner :: struct {
	actor:         ^actod.Actor,
	pid:           actod.PID,
	reached:       bool,
	retired:       bool,
	freed:         bool,
	reused_blocks: [SPAWNER_HEADER_REUSE_BLOCKS]^actod.Actor,
}

held_spawner: Held_Spawner

Init_Panic_Actor :: struct {}

init_panic_actor_init :: proc(data: ^Init_Panic_Actor) {
	panic("dying in init while the spawner waits")
}

init_panic_actor_handle :: proc(data: ^Init_Panic_Actor, from: actod.PID, msg: any) {}

Init_Panic_Actor_Behaviour :: actod.Actor_Behaviour(Init_Panic_Actor) {
	init           = init_panic_actor_init,
	handle_message = init_panic_actor_handle,
}

retired_header_freed :: proc(state: rawptr) -> bool {
	actod.reclaim_scan()
	return !actor_is_retired_and_kept(state)
}

retired_header_kept :: proc(state: rawptr) -> bool {
	return actor_is_retired_and_kept(state)
}

poison_reused_header_blocks :: proc(held: ^Held_Spawner) {
	for &block in held.reused_blocks {
		block = new(actod.Actor, actod.get_system_allocator())
		bytes := ([^]u8)(block)
		for i in 0 ..< size_of(actod.Actor) do intrinsics.volatile_store(&bytes[i], SPAWNER_HEADER_POISON)
	}
}

release_reused_header_blocks :: proc(held: ^Held_Spawner) {
	for &block in held.reused_blocks {
		if block != nil do free(block, actod.get_system_allocator())
		block = nil
	}
}

hold_spawner_until_header_freed :: proc(actor: ^actod.Actor, pid: actod.PID, name: string) {
	if name != SPAWNER_HEADER_ACTOR_NAME do return
	held := &held_spawner
	held.actor = actor
	held.pid = pid
	held.reached = true
	held.retired = poll_until(
		retired_header_kept,
		actor,
		SPAWNER_HEADER_RECLAIM_BUDGET,
		time.Millisecond,
	)
	actod.reclaim_unpin()
	if !held.retired do return
	held.freed = poll_until(
		retired_header_freed,
		actor,
		SPAWNER_HEADER_RECLAIM_BUDGET,
		time.Millisecond,
	)
	if !held.freed do return
	poison_reused_header_blocks(held)
}

test_spawner_does_not_read_header_after_init_panic :: proc(t: ^testing.T) {
	held_spawner = {}
	actod.spawner_resumed_after_start_hook = hold_spawner_until_header_freed
	defer {
		actod.spawner_resumed_after_start_hook = nil
		release_reused_header_blocks(&held_spawner)
	}

	actod.reclaim_pin()
	pid, spawned := actod.spawn(
		SPAWNER_HEADER_ACTOR_NAME,
		Init_Panic_Actor{},
		Init_Panic_Actor_Behaviour,
		actod.make_actor_config(
			logging = actod.make_log_config(level = test_log_level()),
			restart_policy = .TEMPORARY,
		),
	)

	if !held_spawner.reached do actod.reclaim_unpin()

	expect(t, held_spawner.reached, "the spawner must pass the hook after its start wait")
	expect(
		t,
		held_spawner.retired,
		"the actor that panicked in init must be retired and kept while the spawner holds its pin",
	)
	expect(
		t,
		held_spawner.freed,
		"reclaim_scan must free the retired header while the spawner is held",
	)
	expect(t, spawned, "spawn reports success once init has run, even when init panicked")
	expectf(
		t,
		pid == held_spawner.pid,
		"spawn returned %v after its header was freed, the allocated pid was %v",
		pid,
		held_spawner.pid,
	)
}
