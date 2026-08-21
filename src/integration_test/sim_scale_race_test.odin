package integration

import "../actod"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:testing"
import "core:time"

SCALE_RACE_DEFAULT_SWEEP :: 25
SCALE_RACE_BASE_SEED :: u64(41000)
SCALE_RACE_STEP_CAP :: 200_000

@(private = "file")
g_scale_race_counts: [2]int

SCALE_RACE_MAX_IDS :: 4096

@(private = "file")
g_scale_race_seen: [2][SCALE_RACE_MAX_IDS]u8

Scale_Race_Counter_Data :: struct {
	slot: int,
}

Scale_Race_Counter_Behaviour := actod.Actor_Behaviour(Scale_Race_Counter_Data) {
	handle_message = proc(data: ^Scale_Race_Counter_Data, from: actod.PID, msg: any) {
		if m, is_test_msg := msg.(Integration_Test_Message); is_test_msg {
			g_scale_race_counts[data.slot] += 1
			if m.id >= 0 && m.id < SCALE_RACE_MAX_IDS do g_scale_race_seen[data.slot][m.id] += 1
		}
	},
}

@(private = "file")
scale_race_rand :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^ >> 17
}

@(private = "file")
scale_race_pick :: proc(state: ^u64, n: int) -> int {
	return int(scale_race_rand(state) % u64(n))
}

@(private = "file")
scale_race_conn_pid :: proc(peer_name: string) -> (actod.PID, actod.Node_ID) {
	peer_id, known := actod.get_node_by_name(peer_name)
	if !known do return 0, 0
	return actod.NODE.connection_actors[peer_id], peer_id
}

@(private = "file")
scale_race_stranded_slots :: proc(peer_name: string) -> (stranded: int, ring_label: string) {
	peer_id, known := actod.get_node_by_name(peer_name)
	if !known do return 0, ""
	pool := actod.get_connection_pool(peer_id)
	if pool == nil {
		ring := actod.get_connection_ring(peer_id)
		if ring == nil do return 0, ""
		return scale_race_ring_stranded(ring), "primary"
	}
	count := actod.pool_active_count(pool)
	for i: u32 = 0; i < count; i += 1 {
		ring := actod.get_pool_ring_at(pool, i)
		if ring == nil do continue
		if n := scale_race_ring_stranded(ring); n > 0 {
			return n, i == 0 ? "primary" : "pool-active"
		}
	}
	for i in 0 ..< pool.parked_count {
		ring := pool.parked[i]
		if ring == nil do continue
		if n := scale_race_ring_stranded(ring); n > 0 do return n, "parked"
	}
	return 0, ""
}

@(private = "file")
scale_race_ring_stranded :: proc(ring: ^actod.Connection_Ring) -> int {
	stranded := 0
	for i: u32 = 0; i < ring.send_slot_count; i += 1 {
		if sync.atomic_load(&ring.send_slots[i].state) != .FREE do stranded += 1
	}
	return stranded
}

@(private = "file")
scale_race_scenario :: proc(seed: u64) -> (ok: bool, reason: string) {
	g_scale_race_counts = {}
	g_scale_race_seen = {}

	mesh := actod.sim_mesh_create(2, seed = seed, base_port = 29500, log_level = test_log_level())
	defer actod.sim_mesh_destroy(mesh)

	names := [2]string{"mesh0", "mesh1"}

	for i in 0 ..< 2 {
		_ = actod.sim_mesh_bind(mesh, i)
		if _, spawned := actod.spawn("scr", Scale_Race_Counter_Data{slot = i}, Scale_Race_Counter_Behaviour);
		   !spawned {
			return false, "counter spawn failed"
		}
	}

	if !actod.sim_mesh_connect_full(mesh) do return false, "mesh connect did not settle"

	rng := seed ~ 0x9E3779B97F4A7C15
	_ = scale_race_rand(&rng)

	sent: [2]int
	sent_ids: [2][SCALE_RACE_MAX_IDS]u8
	next_id := 0
	op_count := 40 + scale_race_pick(&rng, 21)

	for _ in 0 ..< op_count {
		switch scale_race_pick(&rng, 6) {
		case 0, 1:
			src := scale_race_pick(&rng, 2)
			dst := 1 - src
			burst := 1 + scale_race_pick(&rng, 8)
			_ = actod.sim_mesh_bind(mesh, src)
			for _ in 0 ..< burst {
				err := actod.send_remote_by_name(
					names[dst],
					"scr",
					Integration_Test_Message{id = next_id},
				)
				if err == .OK {
					sent[dst] += 1
					if next_id < SCALE_RACE_MAX_IDS do sent_ids[dst][next_id] = 1
				}
				next_id += 1
			}
		case 2:
			n := scale_race_pick(&rng, 2)
			_ = actod.sim_mesh_bind(mesh, n)
			conn_pid, _ := scale_race_conn_pid(names[1 - n])
			if conn_pid != 0 do _ = actod.send_message(conn_pid, actod.Scale_Up_Request{})
		case 3:
			steps := 1 + scale_race_pick(&rng, 24)
			for _ in 0 ..< steps {
				if !actod.sim_mesh_pump(mesh) do break
			}
		case 4:
			actod.sim_mesh_advance_clock(
				mesh,
				time.Duration(5 + scale_race_pick(&rng, 250)) * time.Millisecond,
			)
		case 5:
			actod.sim_mesh_advance_clock(mesh, time.Duration(1 + scale_race_pick(&rng, 5)) * time.Second)
		}
		extra := scale_race_pick(&rng, 4)
		for _ in 0 ..< extra {
			if !actod.sim_mesh_pump(mesh) do break
		}
	}

	if actod.sim_mesh_run_until_idle(mesh, SCALE_RACE_STEP_CAP) >= SCALE_RACE_STEP_CAP {
		return false, "pump did not go idle (livelock)"
	}
	if !actod.sim_mesh_settle_pools(mesh) do return false, "pool scale-down did not settle"
	_ = actod.sim_mesh_run_until_idle(mesh, SCALE_RACE_STEP_CAP)

	failures: [dynamic]string
	failures.allocator = context.temp_allocator

	for i in 0 ..< 2 {
		if g_scale_race_counts[i] == sent[i] do continue
		missing: [dynamic]int
		missing.allocator = context.temp_allocator
		duplicated: [dynamic]int
		duplicated.allocator = context.temp_allocator
		for id in 0 ..< min(next_id, SCALE_RACE_MAX_IDS) {
			if sent_ids[i][id] == 1 && g_scale_race_seen[i][id] == 0 do append(&missing, id)
			if g_scale_race_seen[i][id] > sent_ids[i][id] do append(&duplicated, id)
		}
		append(
			&failures,
			fmt.tprintf(
				"node %d counter saw %d messages, %d were sent with .OK (missing ids %v, duplicated ids %v)",
				i,
				g_scale_race_counts[i],
				sent[i],
				missing[:],
				duplicated[:],
			),
		)
	}

	for i in 0 ..< 2 {
		_ = actod.sim_mesh_bind(mesh, i)
		if stranded, label := scale_race_stranded_slots(names[1 - i]); stranded > 0 {
			append(
				&failures,
				fmt.tprintf(
					"node %d has %d stranded send slot(s) in a %s ring at quiesce",
					i,
					stranded,
					label,
				),
			)
		}
	}

	if len(failures) > 0 {
		joined := ""
		for f, i in failures do joined = i == 0 ? f : fmt.tprintf("%s; %s", joined, f)
		return false, joined
	}
	return true, ""
}

test_sim_scale_up_race :: proc(t: ^testing.T) {
	sweep := SCALE_RACE_DEFAULT_SWEEP
	base := SCALE_RACE_BASE_SEED
	if v, has := os.lookup_env("ACTOD_SCALE_RACE_COUNT", context.temp_allocator); has {
		if n, parsed := strconv.parse_int(v); parsed && n > 0 do sweep = n
	}
	if v, has := os.lookup_env("ACTOD_SCALE_RACE_SEED", context.temp_allocator); has {
		if n, parsed := strconv.parse_u64(v); parsed {
			base = n
			sweep = 1
		}
	}

	for i in 0 ..< sweep {
		seed := base + u64(i)
		ok, reason := scale_race_scenario(seed)
		if !ok {
			fmt.eprintfln(
				"scale-race seed %d FAILED: %s\nreplay: ACTOD_TEST_RUN=test_sim_scale_up_race ACTOD_SCALE_RACE_SEED=%d bin/integration_test",
				seed,
				reason,
				seed,
			)
		}
		expect(t, ok, reason)
		if !ok do return
		free_all(context.temp_allocator)
	}
}
