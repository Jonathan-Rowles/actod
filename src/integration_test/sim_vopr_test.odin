package integration

import "../actod"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"
import "core:time"

VOPR_REGRESSION_SEEDS :: []u64{1001, 888, 907, 892}

VOPR_MAX_NODES :: 8
VOPR_DEFAULT_SWEEP :: 4
VOPR_DEFAULT_MAX_OPS :: 50
VOPR_DEFAULT_MAX_NODES :: 4
VOPR_STEP_CAP :: 200_000

Vopr_Do_Ask :: struct {
	node:   string,
	ask_id: int,
}

Vopr_Do_Publish :: struct {
	pub_id: int,
}

@(init)
register_vopr_messages :: proc "contextless" () {
	actod.register_message_type(Vopr_Do_Ask)
	actod.register_message_type(Vopr_Do_Publish)
}

@(private = "file")
g_vopr_seen: map[int]int

@(private = "file")
g_vopr_sent: map[int]bool

@(private = "file")
g_vopr_publisher_type: actod.Actor_Type

@(private = "file")
g_vopr_ask_issued: map[int][2]int

@(private = "file")
g_vopr_ask_replies: map[int]int

@(private = "file")
g_vopr_ask_timeouts: map[int]int

@(private = "file")
g_vopr_ask_token_to_id: map[u64]int

@(private = "file")
g_vopr_crash_epoch: [VOPR_MAX_NODES]int

@(private = "file")
g_vopr_pub_sent: map[int]bool

@(private = "file")
g_vopr_pub_seen: [VOPR_MAX_NODES]map[int]int

@(private = "file")
g_vopr_next_id: int

@(private = "file")
g_vopr_sweep_asks_issued: int

@(private = "file")
g_vopr_verbose: bool

@(private = "file")
g_vopr_max_ops := VOPR_DEFAULT_MAX_OPS

@(private = "file")
g_vopr_max_nodes := VOPR_DEFAULT_MAX_NODES

@(private = "file")
vopr_log :: proc(format: string, args: ..any) {
	if g_vopr_verbose {
		fmt.printf(format, ..args)
		fmt.println()
	}
}

Vopr_Counter_Data :: struct {
	slot: int,
}

Vopr_Counter_Behaviour :: actod.Actor_Behaviour(Vopr_Counter_Data) {
	init = proc(data: ^Vopr_Counter_Data) {
		_, _ = actod.subscribe_type(g_vopr_publisher_type)
	},
	handle_message = proc(data: ^Vopr_Counter_Data, from: actod.PID, msg: any) {
		if m, ok := msg.(Integration_Test_Message); ok {
			switch m.payload {
			case "pub":
				g_vopr_pub_seen[data.slot][m.id] += 1
			case "ask":
				g_vopr_seen[m.id] += 1
				_ = actod.reply(Integration_Test_Message{id = m.id, payload = "re"})
			case:
				g_vopr_seen[m.id] += 1
			}
		}
	},
}

Vopr_Asker_Data :: struct {
	slot: int,
}

@(private = "file")
vopr_ask_key :: proc(slot: int, token: u64) -> u64 {
	return u64(slot) << 56 | token
}

Vopr_Asker_Behaviour :: actod.Actor_Behaviour(Vopr_Asker_Data) {
	handle_message = proc(data: ^Vopr_Asker_Data, from: actod.PID, msg: any) {
		switch m in msg {
		case Vopr_Do_Ask:
			target, found := actod.get_actor_pid(fmt.tprintf("vc@%s", m.node))
			if !found {
				return
			}
			token, err := actod.ask(
				target,
				Integration_Test_Message{id = m.ask_id, payload = "ask"},
				5 * time.Second,
			)
			if err == .OK {
				g_vopr_ask_issued[m.ask_id] = {data.slot, g_vopr_crash_epoch[data.slot]}
				g_vopr_ask_token_to_id[vopr_ask_key(data.slot, u64(token))] = m.ask_id
			}
		case Integration_Test_Message:
			if m.payload == "re" {
				g_vopr_ask_replies[m.id] += 1
			}
		case actod.Ask_Timeout:
			key := vopr_ask_key(data.slot, u64(m.token))
			if id, tracked := g_vopr_ask_token_to_id[key]; tracked {
				g_vopr_ask_timeouts[id] += 1
			}
		}
	},
}

Vopr_Pub_Data :: struct {}

@(private = "file")
g_vopr_pub_behaviour: actod.Actor_Behaviour(Vopr_Pub_Data)

@(private = "file")
vopr_rand :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^ >> 33
}

@(private = "file")
vopr_pick :: proc(state: ^u64, n: int) -> int {
	return int(vopr_rand(state) % u64(n))
}

@(private = "file")
vopr_spawn_actors :: proc(mesh: ^actod.Sim_Mesh, i: int) -> bool {
	_ = actod.sim_mesh_bind(mesh, i)
	_, counter_ok := actod.spawn("vc", Vopr_Counter_Data{slot = i}, Vopr_Counter_Behaviour)
	_, asker_ok := actod.spawn("va", Vopr_Asker_Data{slot = i}, Vopr_Asker_Behaviour)
	_, pub_ok := actod.spawn("vp", Vopr_Pub_Data{}, g_vopr_pub_behaviour)
	return counter_ok && asker_ok && pub_ok
}

@(private = "file")
run_vopr_scenario :: proc(seed: u64) -> (ok: bool, reason: string) {
	rng := seed ~ 0x853C49E6748FEA9B
	_ = vopr_rand(&rng)

	clear(&g_vopr_seen)
	clear(&g_vopr_sent)
	clear(&g_vopr_ask_issued)
	clear(&g_vopr_ask_replies)
	clear(&g_vopr_ask_timeouts)
	clear(&g_vopr_ask_token_to_id)
	clear(&g_vopr_pub_sent)
	for slot in 0 ..< VOPR_MAX_NODES {
		clear(&g_vopr_pub_seen[slot])
	}
	g_vopr_crash_epoch = {}
	g_vopr_next_id = 0
	actod.frame_tap_clear()
	fault_rules_added := 0

	node_count := 2 + vopr_pick(&rng, g_vopr_max_nodes - 1)
	vopr_log("seed %d: %d nodes", seed, node_count)
	mesh := actod.sim_mesh_create(
		node_count,
		seed,
		base_port = 25000,
		log_level = .Info if g_vopr_verbose else test_log_level(),
	)
	defer actod.sim_mesh_destroy(mesh)
	defer actod.frame_tap_clear()

	recv_chunk := 0
	if vopr_pick(&rng, 4) == 0 {
		recv_chunk = 1 + vopr_pick(&rng, 7)
	}
	actod.sim_set_recv_chunk(recv_chunk)
	defer actod.sim_set_recv_chunk(0)
	if recv_chunk > 0 {
		vopr_log("recv chunk: %d bytes per delivery", recv_chunk)
	}

	crashed: [VOPR_MAX_NODES]bool
	blocked: [dynamic][2]int
	defer delete(blocked)

	for i in 0 ..< node_count {
		if !vopr_spawn_actors(mesh, i) {
			return false, "actor spawn failed"
		}
	}

	op_count := g_vopr_max_ops * 3 / 5 + vopr_pick(&rng, g_vopr_max_ops * 2 / 5 + 1)
	for _ in 0 ..< op_count {
		switch vopr_pick(&rng, 16) {
		case 0 ..= 4:
			from := vopr_pick(&rng, node_count)
			if crashed[from] {
				continue
			}
			to := vopr_pick(&rng, node_count)
			if to == from {
				to = (to + 1) % node_count
			}
			_ = actod.sim_mesh_bind(mesh, from)
			burst := 1 + vopr_pick(&rng, 4)
			vopr_log("op send: %d -> %d, burst %d (ids from %d)", from, to, burst, g_vopr_next_id + 1)
			for _ in 0 ..< burst {
				g_vopr_next_id += 1
				g_vopr_sent[g_vopr_next_id] = true
				_ = actod.send_remote_by_name(
					actod.sim_mesh_name(mesh, to),
					"vc",
					Integration_Test_Message{id = g_vopr_next_id, payload = "vopr"},
				)
			}

		case 5:
			a := vopr_pick(&rng, node_count)
			b := vopr_pick(&rng, node_count)
			if a == b || crashed[a] || crashed[b] {
				continue
			}
			pair := [2]int{min(a, b), max(a, b)}
			already := false
			for p in blocked {
				if p == pair {
					already = true
					break
				}
			}
			if !already {
				vopr_log("op partition: %d | %d", pair[0], pair[1])
				actod.sim_mesh_partition(mesh, pair[0], pair[1])
				append(&blocked, pair)
			}

		case 6:
			if len(blocked) > 0 {
				k := vopr_pick(&rng, len(blocked))
				pair := blocked[k]
				ordered_remove(&blocked, k)
				vopr_log("op heal: %d | %d", pair[0], pair[1])
				actod.sim_mesh_heal(mesh, pair[0], pair[1])
			}

		case 7:
			jump := time.Duration(1 + vopr_pick(&rng, 10)) * time.Second
			vopr_log("op clock: +%v", jump)
			actod.sim_mesh_advance_clock(mesh, jump)

		case 8:
			live := 0
			for i in 0 ..< node_count {
				if !crashed[i] {
					live += 1
				}
			}
			victim := vopr_pick(&rng, node_count)
			if live > 1 && !crashed[victim] {
				vopr_log("op crash: %d", victim)
				actod.sim_mesh_crash(mesh, victim)
				crashed[victim] = true
				g_vopr_crash_epoch[victim] += 1
				k := 0
				for k < len(blocked) {
					if blocked[k][0] == victim || blocked[k][1] == victim {
						ordered_remove(&blocked, k)
						continue
					}
					k += 1
				}
			}

		case 9:
			start := vopr_pick(&rng, node_count)
			for offset in 0 ..< node_count {
				i := (start + offset) % node_count
				if !crashed[i] {
					continue
				}
				vopr_log("op restart: %d", i)
				_ = actod.sim_mesh_restart(mesh, i)
				crashed[i] = false
				if !vopr_spawn_actors(mesh, i) {
					return false, "actor respawn failed"
				}
				break
			}

		case 10:
			if fault_rules_added >= 12 {
				continue
			}
			a := vopr_pick(&rng, node_count)
			b := vopr_pick(&rng, node_count)
			if a == b || crashed[a] || crashed[b] {
				continue
			}
			_ = actod.sim_mesh_bind(mesh, a)
			peer_id, known := actod.get_node_by_name(actod.sim_mesh_name(mesh, b))
			if !known {
				continue
			}
			dir := actod.Frame_Dir.Out if vopr_pick(&rng, 2) == 0 else actod.Frame_Dir.In
			drop_count := 1 + vopr_pick(&rng, 4)
			vopr_log("op drop-link: node %d %v peer %d, %d frames", a, dir, b, drop_count)
			actod.frame_tap_add(
				actod.Frame_Fault_Rule {
					dir       = dir,
					action    = .Drop,
					type_hash = actod.frame_tap_type_hash(Integration_Test_Message),
					node      = actod.sim_mesh_node(mesh, a),
					peer      = peer_id,
					count     = drop_count,
				},
			)
			fault_rules_added += 1

		case 11:
			if fault_rules_added >= 12 {
				continue
			}
			a := vopr_pick(&rng, node_count)
			if crashed[a] {
				continue
			}
			vopr_log("op corrupt-handshake: node %d", a)
			actod.frame_tap_add(
				actod.Frame_Fault_Rule {
					dir       = .Out,
					action    = .Corrupt,
					type_hash = actod.FRAME_TAP_HANDSHAKE,
					node      = actod.sim_mesh_node(mesh, a),
					count     = 1,
				},
			)
			fault_rules_added += 1

		case 12:
			from := vopr_pick(&rng, node_count)
			if crashed[from] {
				continue
			}
			to := vopr_pick(&rng, node_count)
			if to == from {
				to = (to + 1) % node_count
			}
			_ = actod.sim_mesh_bind(mesh, from)
			asker_pid, asker_found := actod.get_actor_pid("va")
			if !asker_found {
				continue
			}
			g_vopr_next_id += 1
			g_vopr_sent[g_vopr_next_id] = true
			vopr_log("op ask: %d -> %d (id %d)", from, to, g_vopr_next_id)
			_ = actod.send_message(
				asker_pid,
				Vopr_Do_Ask{node = actod.sim_mesh_name(mesh, to), ask_id = g_vopr_next_id},
			)

		case 13:
			publisher := vopr_pick(&rng, node_count)
			if crashed[publisher] {
				continue
			}
			_ = actod.sim_mesh_bind(mesh, publisher)
			pub_pid, pub_found := actod.get_actor_pid("vp")
			if !pub_found {
				continue
			}
			g_vopr_next_id += 1
			g_vopr_pub_sent[g_vopr_next_id] = true
			vopr_log("op publish: node %d (id %d)", publisher, g_vopr_next_id)
			_ = actod.send_message(pub_pid, Vopr_Do_Publish{pub_id = g_vopr_next_id})

		case 14:
			a := vopr_pick(&rng, node_count)
			b := vopr_pick(&rng, node_count)
			if a == b || crashed[a] || crashed[b] {
				continue
			}
			_ = actod.sim_mesh_bind(mesh, a)
			peer_id, known := actod.get_node_by_name(actod.sim_mesh_name(mesh, b))
			if !known {
				continue
			}
			conn_pid := actod.NODE.connection_actors[peer_id]
			if conn_pid == 0 {
				continue
			}
			vopr_log("op scale-up: node %d pool toward %d", a, b)
			_ = actod.send_message(conn_pid, actod.Scale_Up_Request{})

		case 15:
			a := vopr_pick(&rng, node_count)
			b := vopr_pick(&rng, node_count)
			if a == b || crashed[a] || crashed[b] {
				continue
			}
			deliver_error := vopr_pick(&rng, 2) == 0
			vopr_log("op sever: %d | %d err=%v", a, b, deliver_error)
			actod.sim_mesh_sever(mesh, a, b, deliver_error)
		}

		if actod.sim_mesh_run_until_idle(mesh, VOPR_STEP_CAP) >= VOPR_STEP_CAP {
			return false, "pump livelock: run_until_idle hit the step cap"
		}
		if step_ok, step_reason := vopr_check_step_invariants(mesh, node_count, crashed);
		   !step_ok {
			return false, step_reason
		}
	}

	actod.frame_tap_clear()
	for len(blocked) > 0 {
		pair := blocked[len(blocked) - 1]
		ordered_remove(&blocked, len(blocked) - 1)
		actod.sim_mesh_heal(mesh, pair[0], pair[1])
	}
	for i in 0 ..< node_count {
		if !crashed[i] {
			continue
		}
		_ = actod.sim_mesh_restart(mesh, i)
		crashed[i] = false
		if !vopr_spawn_actors(mesh, i) {
			return false, "actor respawn failed at quiesce"
		}
	}
	actod.sim_mesh_advance_clock(mesh, 30 * time.Second)
	if actod.sim_mesh_run_until_idle(mesh, VOPR_STEP_CAP) >= VOPR_STEP_CAP {
		return false, "pump livelock at quiesce"
	}
	if !actod.sim_mesh_connect_full(mesh) {
		return false, "mesh failed to fully reconnect at quiesce"
	}
	if actod.sim_mesh_run_until_idle(mesh, VOPR_STEP_CAP) >= VOPR_STEP_CAP {
		return false, "pump livelock after reconnect"
	}
	actod.sim_mesh_advance_clock(mesh, 10 * time.Second)
	if actod.sim_mesh_run_until_idle(mesh, VOPR_STEP_CAP) >= VOPR_STEP_CAP {
		return false, "pump livelock draining ask timeouts"
	}

	for id, issue in g_vopr_ask_issued {
		replies := g_vopr_ask_replies[id]
		timeouts := g_vopr_ask_timeouts[id]
		if g_vopr_crash_epoch[issue[0]] != issue[1] {
			if replies + timeouts > 1 {
				return false, fmt.tprintf(
					"crash-excused ask %d still resolved %d replies and %d timeouts, want at most one",
					id,
					replies,
					timeouts,
				)
			}
			continue
		}
		if replies + timeouts != 1 {
			return false, fmt.tprintf(
				"ask %d resolved %d replies and %d timeouts, want exactly one outcome",
				id,
				replies,
				timeouts,
			)
		}
	}
	g_vopr_sweep_asks_issued += len(g_vopr_ask_issued)

	for slot in 0 ..< VOPR_MAX_NODES {
		for id, deliveries in g_vopr_pub_seen[slot] {
			if deliveries > 1 {
				return false, fmt.tprintf(
					"publish %d delivered %d times to node %d's subscriber",
					id,
					deliveries,
					slot,
				)
			}
			if id not_in g_vopr_pub_sent {
				return false, fmt.tprintf("phantom publish id %d on node %d", id, slot)
			}
		}
	}

	if !actod.sim_mesh_settle_pools(mesh) {
		return false, "pool scale-down did not settle at quiesce"
	}
	if !actod.sim_mesh_connect_full(mesh) {
		return false, "mesh failed to reconnect before the quiesce publish round"
	}
	if actod.sim_mesh_run_until_idle(mesh, VOPR_STEP_CAP) >= VOPR_STEP_CAP {
		return false, "pump livelock settling before the quiesce publish round"
	}

	final_pub_ids: [VOPR_MAX_NODES]int
	for i in 0 ..< node_count {
		_ = actod.sim_mesh_bind(mesh, i)
		pub_pid, pub_found := actod.get_actor_pid("vp")
		if !pub_found {
			return false, fmt.tprintf("publisher missing on node %d at quiesce", i)
		}
		g_vopr_next_id += 1
		final_pub_ids[i] = g_vopr_next_id
		g_vopr_pub_sent[g_vopr_next_id] = true
		_ = actod.send_message(pub_pid, Vopr_Do_Publish{pub_id = g_vopr_next_id})
	}
	if actod.sim_mesh_run_until_idle(mesh, VOPR_STEP_CAP) >= VOPR_STEP_CAP {
		return false, "pump livelock delivering quiesce publishes"
	}
	for i in 0 ..< node_count {
		for j in 0 ..< node_count {
			if g_vopr_pub_seen[j][final_pub_ids[i]] != 1 {
				_ = actod.sim_mesh_bind(mesh, i)
				sub_count := -1
				pool_rings := -1
				if peer_id, known := actod.get_node_by_name(actod.sim_mesh_name(mesh, j));
				   known {
					sub_count = int(
						actod.NODE.type_subscribers[g_vopr_publisher_type].remote_node_sub_count[peer_id],
					)
					if pool := actod.get_connection_pool(peer_id); pool != nil {
						pool_rings = int(actod.pool_active_count(pool))
					}
				}
				_ = actod.sim_mesh_bind(mesh, j)
				local_subs := int(
					actod.NODE.type_subscribers[g_vopr_publisher_type].local_count,
				)
				return false, fmt.tprintf(
					"quiesce publish from node %d seen %d times on node %d, want exactly once (publisher remote_count=%d pool_rings=%d, receiver local_subs=%d)",
					i,
					g_vopr_pub_seen[j][final_pub_ids[i]],
					j,
					sub_count,
					pool_rings,
					local_subs,
				)
			}
		}
	}

	for id, count in g_vopr_seen {
		if count > 1 {
			return false, fmt.tprintf("message id %d delivered %d times", id, count)
		}
		if id not_in g_vopr_sent {
			return false, fmt.tprintf("phantom message id %d was never sent", id)
		}
	}

	for i in 0 ..< node_count {
		_ = actod.sim_mesh_bind(mesh, i)
		for j in 0 ..< node_count {
			if j == i {
				continue
			}
			name := fmt.tprintf("vc@%s", actod.sim_mesh_name(mesh, j))
			if _, found := actod.get_actor_pid(name); !found {
				return false, fmt.tprintf("gossip: node %d cannot see %s", i, name)
			}
		}
	}

	return true, ""
}

@(private = "file")
vopr_check_step_invariants :: proc(
	mesh: ^actod.Sim_Mesh,
	node_count: int,
	crashed: [VOPR_MAX_NODES]bool,
) -> (
	ok: bool,
	reason: string,
) {
	for i in 0 ..< node_count {
		if crashed[i] {
			continue
		}
		_ = actod.sim_mesh_bind(mesh, i)

		it := actod.make_iter(&actod.NODE.actor_registry)
		for {
			_, pid, more := actod.iter(&it)
			if !more {
				break
			}
			if actod.is_local_pid(pid) {
				continue
			}
			node_id := actod.get_node_id(pid)
			if _, known := actod.get_node_info(node_id); !known {
				return false, fmt.tprintf(
					"node %d holds proxy %v for unknown node id %d",
					i,
					pid,
					node_id,
				)
			}
		}

		for slot_id in 0 ..< len(actod.NODE.connection_actors) {
			conn_pid := actod.NODE.connection_actors[slot_id]
			if conn_pid == 0 {
				continue
			}
			actor_ptr, alive := actod.get(&actod.NODE.actor_registry, conn_pid)
			if !alive || actor_ptr == nil {
				return false, fmt.tprintf(
					"node %d connection actor slot %d holds dead pid %v",
					i,
					slot_id,
					conn_pid,
				)
			}
		}
	}
	return true, ""
}

@(private = "file")
vopr_env_u64 :: proc(key: string, fallback: u64) -> u64 {
	if s, has := os.lookup_env(key, context.temp_allocator); has {
		if v, parsed := strconv.parse_u64(s); parsed {
			return v
		}
	}
	return fallback
}

@(private = "file")
vopr_failure :: proc(seed: u64, reason: string) -> string {
	return fmt.tprintf(
		"VOPR seed %d failed (profile ops<=%d nodes<=%d): %s (replay: ACTOD_TEST_RUN=test_sim_vopr ACTOD_VOPR_SEED=%d ACTOD_VOPR_OPS=%d ACTOD_VOPR_NODES=%d bin/integration_test, then commit the seed to VOPR_REGRESSION_SEEDS if it reproduces under the default profile)",
		seed,
		g_vopr_max_ops,
		g_vopr_max_nodes,
		reason,
		seed,
		g_vopr_max_ops,
		g_vopr_max_nodes,
	)
}

test_sim_vopr :: proc(t: ^testing.T) {
	g_vopr_seen = make(map[int]int)
	g_vopr_sent = make(map[int]bool)
	g_vopr_ask_issued = make(map[int][2]int)
	g_vopr_ask_replies = make(map[int]int)
	g_vopr_ask_timeouts = make(map[int]int)
	g_vopr_ask_token_to_id = make(map[u64]int)
	g_vopr_pub_sent = make(map[int]bool)
	for slot in 0 ..< VOPR_MAX_NODES {
		g_vopr_pub_seen[slot] = make(map[int]int)
	}
	defer {
		delete(g_vopr_seen)
		delete(g_vopr_sent)
		delete(g_vopr_ask_issued)
		delete(g_vopr_ask_replies)
		delete(g_vopr_ask_timeouts)
		delete(g_vopr_ask_token_to_id)
		delete(g_vopr_pub_sent)
		for slot in 0 ..< VOPR_MAX_NODES {
			delete(g_vopr_pub_seen[slot])
		}
	}

	g_vopr_publisher_type, _ = actod.register_actor_type("vopr_publisher")
	g_vopr_pub_behaviour = actod.Actor_Behaviour(Vopr_Pub_Data) {
		actor_type = g_vopr_publisher_type,
		handle_message = proc(data: ^Vopr_Pub_Data, from: actod.PID, msg: any) {
			if m, ok := msg.(Vopr_Do_Publish); ok {
				actod.broadcast(Integration_Test_Message{id = m.pub_id, payload = "pub"})
			}
		},
	}

	_, g_vopr_verbose = os.lookup_env("ACTOD_VOPR_VERBOSE", context.temp_allocator)
	context.logger.lowest_level = .Info if g_vopr_verbose else context.logger.lowest_level

	g_vopr_max_ops = max(10, int(vopr_env_u64("ACTOD_VOPR_OPS", VOPR_DEFAULT_MAX_OPS)))
	g_vopr_max_nodes = clamp(
		int(vopr_env_u64("ACTOD_VOPR_NODES", VOPR_DEFAULT_MAX_NODES)),
		2,
		VOPR_MAX_NODES,
	)

	if s, has := os.lookup_env("ACTOD_VOPR_SEED", context.temp_allocator); has {
		seed, parsed := strconv.parse_u64(s)
		expect(t, parsed, "ACTOD_VOPR_SEED must be an unsigned integer")
		if parsed {
			ok, reason := run_vopr_scenario(seed)
			expect(t, ok, vopr_failure(seed, reason))
		}
		return
	}

	for seed in VOPR_REGRESSION_SEEDS {
		ok, reason := run_vopr_scenario(seed)
		if !ok {
			expect(t, false, vopr_failure(seed, reason))
			return
		}
		free_all(context.temp_allocator)
	}

	base := vopr_env_u64("ACTOD_VOPR_BASE", 1)
	count := vopr_env_u64("ACTOD_VOPR_COUNT", VOPR_DEFAULT_SWEEP)

	for k in 0 ..< count {
		seed := base + k
		ok, reason := run_vopr_scenario(seed)
		if !ok {
			expect(t, false, vopr_failure(seed, reason))
			return
		}
		free_all(context.temp_allocator)
	}

	if count >= 10 {
		expect(
			t,
			g_vopr_sweep_asks_issued > 0,
			"VOPR sweep issued zero asks; the exactly-one-outcome invariant checked nothing",
		)
	}

	fmt.printfln(
		"VOPR: %d regression seed(s) + %d swept seeds from base %d (ops<=%d nodes<=%d), %d asks issued, all invariants held",
		len(VOPR_REGRESSION_SEEDS),
		count,
		base,
		g_vopr_max_ops,
		g_vopr_max_nodes,
		g_vopr_sweep_asks_issued,
	)
}
