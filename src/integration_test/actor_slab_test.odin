package integration

import "../actod"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"

SLAB_CHURN_ROUNDS :: 4
SLAB_CHURN_ACTORS :: 200
SLAB_REAP_TIMEOUT :: 10 * time.Second
SLAB_REAP_POLL :: 5 * time.Millisecond
SLAB_BIG_MAILBOX :: 8192

Slab_Probe :: struct {
	received: int,
	marker:   u64,
}

slab_probe_behaviour := actod.Actor_Behaviour(Slab_Probe) {
	handle_message = proc(data: ^Slab_Probe, from: actod.PID, msg: any) {
		if value, ok := msg.(u64); ok {
			data.marker = value
		}
		data.received += 1
	},
}

slab_in_use :: proc() -> i64 {
	return actod.slot_slab_in_use(&actod.NODE.actor_slab)
}

slab_use_reached :: proc(state: rawptr) -> bool {
	target := cast(^i64)state
	return slab_in_use() <= target^
}

wait_for_slab_in_use :: proc(target: i64) -> bool {
	ceiling := target
	return poll_until(slab_use_reached, &ceiling, SLAB_REAP_TIMEOUT, SLAB_REAP_POLL)
}

test_slab_slots_return_after_termination :: proc(t: ^testing.T) {
	reset_test_state()

	if !actod.NODE.actor_slab.enabled {
		return
	}

	baseline := slab_in_use()

	for round in 0 ..< SLAB_CHURN_ROUNDS {
		pids := make([dynamic]actod.PID, 0, SLAB_CHURN_ACTORS)
		defer delete(pids)

		for i in 0 ..< SLAB_CHURN_ACTORS {
			pid, spawned := actod.spawn("slab-churn", Slab_Probe{}, slab_probe_behaviour)
			expectf(t, spawned, "round %d: spawn %d failed", round, i)
			if !spawned {
				return
			}
			append(&pids, pid)
		}

		expectf(
			t,
			slab_in_use() > baseline,
			"round %d: spawning %d actors did not take any slab slots",
			round,
			SLAB_CHURN_ACTORS,
		)

		for pid in pids {
			_ = actod.terminate_actor(pid)
		}

		expectf(
			t,
			wait_for_slab_in_use(baseline),
			"round %d: slab slots not returned after termination, in_use %d vs baseline %d",
			round,
			slab_in_use(),
			baseline,
		)
	}
}

test_slab_spills_for_oversized_actor :: proc(t: ^testing.T) {
	reset_test_state()

	if !actod.NODE.actor_slab.enabled {
		return
	}

	before := slab_in_use()

	pid, spawned := actod.spawn(
		"slab-oversized",
		Slab_Probe{},
		slab_probe_behaviour,
		SLAB_BIG_MAILBOX,
	)
	expect(t, spawned, "an actor whose mailbox outgrows a slab slot must still spawn")
	if !spawned {
		return
	}

	expectf(
		t,
		slab_in_use() == before + 1,
		"an actor that outgrows its slot should keep the slot and spill the rest, in_use went %d -> %d",
		before,
		slab_in_use(),
	)

	expect(t, actod.send_message(pid, u64(0xABCD)) == .OK, "the spilled actor must receive messages")

	_ = actod.terminate_actor(pid)
	expect(t, wait_for_slab_in_use(before), "terminating a spilled actor must return its slot")
}

SLAB_NEIGHBOUR_COUNT :: 3
SLAB_GREEDY_BLOCK :: 1024 * 1024

slab_markers: [SLAB_NEIGHBOUR_COUNT]u64
slab_greedy_hit_limit: bool
slab_greedy_blocks: int

Slab_Neighbour :: struct {
	index: int,
}

slab_neighbour_behaviour := actod.Actor_Behaviour(Slab_Neighbour) {
	handle_message = proc(data: ^Slab_Neighbour, from: actod.PID, msg: any) {
		if value, ok := msg.(u64); ok {
			sync.atomic_store(&slab_markers[data.index], value)
		}
	},
}

Slab_Greedy :: struct {
	eaten: int,
}

slab_greedy_behaviour := actod.Actor_Behaviour(Slab_Greedy) {
	handle_message = proc(data: ^Slab_Greedy, from: actod.PID, msg: any) {
		if _, ok := msg.(u64); !ok {
			return
		}
		for {
			_, err := mem.alloc(SLAB_GREEDY_BLOCK, 64, context.allocator)
			if err != nil {
				sync.atomic_store(&slab_greedy_hit_limit, true)
				sync.atomic_store(&slab_greedy_blocks, data.eaten)
				return
			}
			data.eaten += 1
			if data.eaten > 64 * 1024 {
				sync.atomic_store(&slab_greedy_blocks, data.eaten)
				return
			}
		}
	},
}

test_slab_neighbours_survive_arena_exhaustion :: proc(t: ^testing.T) {
	reset_test_state()

	if !actod.NODE.actor_slab.enabled {
		return
	}

	sync.atomic_store(&slab_greedy_hit_limit, false)
	sync.atomic_store(&slab_greedy_blocks, 0)

	neighbours: [SLAB_NEIGHBOUR_COUNT]actod.PID
	for i in 0 ..< SLAB_NEIGHBOUR_COUNT {
		sync.atomic_store(&slab_markers[i], 0)
		pid, spawned := actod.spawn("slab-neighbour", Slab_Neighbour{index = i}, slab_neighbour_behaviour)
		expectf(t, spawned, "neighbour %d failed to spawn", i)
		if !spawned {
			return
		}
		neighbours[i] = pid
	}

	greedy, greedy_spawned := actod.spawn("slab-greedy", Slab_Greedy{}, slab_greedy_behaviour)
	expect(t, greedy_spawned, "the greedy actor failed to spawn")
	if !greedy_spawned {
		return
	}

	for pid, i in neighbours {
		expect(t, actod.send_message(pid, u64(0x1000 + i)) == .OK, "marker send failed")
	}
	expect(t, actod.send_message(greedy, u64(1)) == .OK, "greedy trigger send failed")

	deadline := time.tick_now()
	for time.tick_since(deadline) < SLAB_REAP_TIMEOUT {
		if sync.atomic_load(&slab_greedy_hit_limit) {
			break
		}
		time.sleep(SLAB_REAP_POLL)
	}

	expectf(
		t,
		sync.atomic_load(&slab_greedy_hit_limit),
		"allocating past the arena must return an error, stopped after %d blocks instead",
		sync.atomic_load(&slab_greedy_blocks),
	)

	for i in 0 ..< SLAB_NEIGHBOUR_COUNT {
		expectf(
			t,
			sync.atomic_load(&slab_markers[i]) == u64(0x1000 + i),
			"neighbour %d marker was corrupted by the greedy actor: got %X want %X",
			i,
			sync.atomic_load(&slab_markers[i]),
			u64(0x1000 + i),
		)
	}

	for pid, i in neighbours {
		expectf(
			t,
			actod.send_message(pid, u64(0x2000 + i)) == .OK,
			"neighbour %d must still accept messages after its neighbour exhausted its arena",
			i,
		)
	}
	time.sleep(200 * time.Millisecond)

	for i in 0 ..< SLAB_NEIGHBOUR_COUNT {
		expectf(
			t,
			sync.atomic_load(&slab_markers[i]) == u64(0x2000 + i),
			"neighbour %d stopped processing after the exhaustion",
			i,
		)
	}

	_ = actod.terminate_actor(greedy)
	for pid in neighbours {
		_ = actod.terminate_actor(pid)
	}
}
