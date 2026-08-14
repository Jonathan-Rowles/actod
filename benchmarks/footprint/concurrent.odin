package footprint

import "../../src/actod"
import "core:fmt"
import "core:sync"
import "core:time"

CHILD_NAME_CAP :: 32
SPAWNER_READY_TIMEOUT :: 120 * time.Second
SPAWNER_POLL :: 1 * time.Millisecond

Spawn_Go :: struct {
	count: int,
}

Spawn_Kill :: struct {}

Spawner :: struct {
	id:       int,
	children: [dynamic]actod.PID,
}

spawner_children_made: int
spawner_spawn_done: int
spawner_kill_done: int

@(init)
register_concurrent_messages :: proc "contextless" () {
	actod.register_message_type(Spawn_Go)
	actod.register_message_type(Spawn_Kill)
}

spawner_behaviour := actod.Actor_Behaviour(Spawner) {
	handle_message = proc(data: ^Spawner, from: actod.PID, msg: any) {
		if go, is_go := msg.(Spawn_Go); is_go {
			name_buf: [CHILD_NAME_CAP]u8
			for i in 0 ..< go.count {
				name := fmt.bprintf(name_buf[:], "c%d_%d", data.id, i)
				pid, ok := actod.spawn(
					name,
					Idle{},
					actod.Actor_Behaviour(Idle){handle_message = idle_handle},
				)
				if !ok do break
				append(&data.children, pid)
			}
			sync.atomic_add(&spawner_children_made, len(data.children))
			sync.atomic_add(&spawner_spawn_done, 1)
			return
		}

		if _, is_kill := msg.(Spawn_Kill); is_kill {
			for pid in data.children {
				_ = actod.terminate_actor(pid)
			}
			clear(&data.children)
			sync.atomic_add(&spawner_kill_done, 1)
		}
	},
}

wait_for_counter :: proc(counter: ^int, target: int) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < SPAWNER_READY_TIMEOUT {
		if sync.atomic_load(counter) >= target do return true
		time.sleep(SPAWNER_POLL)
	}
	return false
}

per_second :: proc(n: int, d: time.Duration) -> f64 {
	ns := f64(time.duration_nanoseconds(d))
	if ns <= 0 do return 0
	return f64(n) / (ns / 1e9)
}

run_concurrent_spawn :: proc(total: int, spawner_count: int, baseline_live: int) {
	spawners := make([dynamic]actod.PID, 0, spawner_count)
	defer delete(spawners)

	for i in 0 ..< spawner_count {
		pid, ok := actod.spawn(fmt.tprintf("spawner_%d", i), Spawner{id = i}, spawner_behaviour)
		if !ok {
			fmt.printf("failed to spawn spawner %d\n", i)
			return
		}
		append(&spawners, pid)
	}

	per_spawner := total / spawner_count
	if per_spawner < 1 do per_spawner = 1

	sync.atomic_store(&spawner_children_made, 0)
	sync.atomic_store(&spawner_spawn_done, 0)
	sync.atomic_store(&spawner_kill_done, 0)

	spawn_start := time.now()
	for pid in spawners {
		if actod.send_message(pid, Spawn_Go{count = per_spawner}) != .OK {
			fmt.println("failed to trigger a spawner")
			return
		}
	}
	if !wait_for_counter(&spawner_spawn_done, spawner_count) {
		fmt.println("concurrent spawn timed out")
		return
	}
	spawn_elapsed := time.since(spawn_start)
	made := sync.atomic_load(&spawner_children_made)

	kill_start := time.now()
	for pid in spawners {
		_ = actod.send_message(pid, Spawn_Kill{})
	}
	if !wait_for_counter(&spawner_kill_done, spawner_count) {
		fmt.println("concurrent terminate timed out")
		return
	}
	_, reaped := wait_for_reap(baseline_live + spawner_count)
	kill_elapsed := time.since(kill_start)

	fmt.printf("spawners:           %d\n", spawner_count)
	fmt.printf("actors spawned:     %d\n", made)
	fmt.printf(
		"concurrent spawn:   %.2f us/actor   %.0f actors/sec\n",
		us_per(spawn_elapsed, made),
		per_second(made, spawn_elapsed),
	)
	if reaped {
		fmt.printf(
			"concurrent teardown:%.2f us/actor   %.0f actors/sec\n",
			us_per(kill_elapsed, made),
			per_second(made, kill_elapsed),
		)
	} else {
		fmt.printf("concurrent teardown:did not reap within the timeout\n")
	}

	for pid in spawners {
		_ = actod.terminate_actor(pid)
	}
	_, _ = wait_for_reap(baseline_live)
}
