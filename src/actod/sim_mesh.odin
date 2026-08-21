package actod

import "../../test_harness/ti"
import "core:fmt"
import "core:log"
import "core:net"
import "core:sync"
import "core:time"

SIM_MESH_EPOCH_UNIX :: 1_700_000_000

Sim_Mesh :: struct {
	nodes:         [dynamic]^Node_State,
	names:         [dynamic]string,
	ports:         [dynamic]int,
	crashed:       [dynamic]bool,
	graveyard:     [dynamic]^Node_State,
	det:           ti.Det_State,
	prev_det:      ^ti.Det_State,
	prev_node:     ^Node_State,
	worker_count:  int,
	auth_password: string,
	log_level:     log.Level,
	rng:           u64,
	cursor:        int,
}

@(private = "file")
g_sim_active_mesh: ^Sim_Mesh

sim_pump_any :: proc() -> bool {
	if sim_pump() do return true
	mesh := g_sim_active_mesh
	if mesh == nil do return false
	previous := NODE
	progress := sim_mesh_pump(mesh)
	NODE = previous
	return progress
}

sim_mesh_create :: proc(
	node_count: int,
	seed: u64 = 0,
	base_port: int = 21000,
	worker_count: int = 2,
	auth_password: string = "",
	log_level: log.Level = .Warning,
	register_peers: bool = true,
) -> ^Sim_Mesh {
	mesh := new(Sim_Mesh, get_system_allocator())
	mesh.prev_node = NODE
	mesh.prev_det = ti.det
	mesh.worker_count = worker_count
	mesh.auth_password = auth_password
	mesh.log_level = log_level
	mesh.det.virtual_now = time.unix(SIM_MESH_EPOCH_UNIX, 0)
	mesh.det.virtual_tick_ns = 1
	mesh.det.rng_state = seed != 0 ? seed : 0x9E3779B97F4A7C15
	ti.det = &mesh.det
	mesh.rng = seed
	sim_seed(seed)
	sim_transport_reset_counters_if_idle()

	mesh.nodes = make([dynamic]^Node_State, get_system_allocator())
	mesh.names = make([dynamic]string, get_system_allocator())
	mesh.ports = make([dynamic]int, get_system_allocator())
	mesh.crashed = make([dynamic]bool, get_system_allocator())
	mesh.graveyard = make([dynamic]^Node_State, get_system_allocator())

	for i in 0 ..< node_count {
		name := fmt.aprintf("mesh%d", i, allocator = get_system_allocator())
		append(&mesh.names, name)
		append(&mesh.ports, base_port + i)
		append(&mesh.crashed, false)
		append(&mesh.nodes, sim_mesh_boot_node(mesh, i))
	}

	if register_peers {
		for i in 0 ..< node_count {
			_ = sim_bind_node(mesh.nodes[i])
			sim_mesh_register_peers(mesh, i)
		}
	}

	g_sim_active_mesh = mesh
	_ = sim_bind_node(mesh.prev_node)
	return mesh
}

sim_mesh_register :: proc(mesh: ^Sim_Mesh, i, j: int) {
	previous := sim_bind_node(mesh.nodes[i])
	_, _ = register_node(
		mesh.names[j],
		net.Endpoint{address = net.IP4_Loopback, port = mesh.ports[j]},
		.TCP_Custom_Protocol,
	)
	_ = sim_bind_node(previous)
}

@(private = "file")
sim_mesh_boot_node :: proc(mesh: ^Sim_Mesh, i: int) -> ^Node_State {
	node := sim_create_node()
	_ = sim_bind_node(node)
	opts := make_node_config(
		worker_count = mesh.worker_count,
		sim_mode = true,
		network = make_network_config(
			auth_password = mesh.auth_password,
			port = mesh.ports[i],
			connection_ring = Connection_Ring_Config {
				send_slot_count = DEFAULT_CONNECTION_RING_CONFIG.send_slot_count,
				send_slot_size = DEFAULT_CONNECTION_RING_CONFIG.send_slot_size,
				recv_buffer_size = DEFAULT_CONNECTION_RING_CONFIG.recv_buffer_size,
				tcp_nodelay = DEFAULT_CONNECTION_RING_CONFIG.tcp_nodelay,
				max_pool_rings = MAX_POOL_RINGS / 2,
				scale_up_contention_threshold = DEFAULT_CONNECTION_RING_CONFIG.scale_up_contention_threshold,
				scale_down_idle_seconds = DEFAULT_CONNECTION_RING_CONFIG.scale_down_idle_seconds,
			},
		),
		actor_config = make_actor_config(logging = make_log_config(level = mesh.log_level)),
	)
	node_init(mesh.names[i], opts)
	return node
}

@(private = "file")
sim_mesh_register_peers :: proc(mesh: ^Sim_Mesh, i: int) {
	for j in 0 ..< len(mesh.nodes) {
		if j == i do continue
		_, _ = register_node(
			mesh.names[j],
			net.Endpoint{address = net.IP4_Loopback, port = mesh.ports[j]},
			.TCP_Custom_Protocol,
		)
	}
}

sim_mesh_node :: proc(mesh: ^Sim_Mesh, i: int) -> ^Node_State {
	return mesh.nodes[i]
}

sim_mesh_name :: proc(mesh: ^Sim_Mesh, i: int) -> string {
	return mesh.names[i]
}

sim_mesh_bind :: proc(mesh: ^Sim_Mesh, i: int) -> ^Node_State {
	return sim_bind_node(mesh.nodes[i])
}

sim_mesh_pump :: proc(mesh: ^Sim_Mesh) -> bool {
	n := len(mesh.nodes)
	if n == 0 do return false
	start: int
	if mesh.rng != 0 {
		start = int(lcg_next(&mesh.rng) % u64(n))
	} else {
		start = mesh.cursor
		mesh.cursor = (mesh.cursor + 1) % n
	}
	for k in 0 ..< n {
		i := (start + k) % n
		if mesh.crashed[i] do continue
		_ = sim_bind_node(mesh.nodes[i])
		if sim_pump() {
			sim_trace_record(.Node_Step, u64(i), 0)
			return true
		}
	}
	return false
}

sim_mesh_run_until_idle :: proc(mesh: ^Sim_Mesh, max_steps: int = 1_000_000) -> int {
	steps := 0
	for steps < max_steps && sim_mesh_pump(mesh) {
		steps += 1
	}
	return steps
}

sim_mesh_connect_full :: proc(mesh: ^Sim_Mesh, max_rounds: int = 10) -> bool {
	n := len(mesh.nodes)
	for i in 0 ..< n {
		if mesh.crashed[i] do continue
		_ = sim_bind_node(mesh.nodes[i])
		for j in i + 1 ..< n {
			if mesh.crashed[j] do continue
			if node_id, ok := get_node_by_name(mesh.names[j]); ok {
				_ = get_or_create_connection(node_id)
			}
		}
	}
	connected := false
	for _ in 0 ..< max_rounds {
		_ = sim_mesh_run_until_idle(mesh)
		if sim_mesh_all_connected(mesh) {
			connected = true
			break
		}
		sim_mesh_advance_clock(mesh, 3 * time.Second)
	}
	_ = sim_bind_node(mesh.prev_node)
	return connected
}

@(private = "file")
sim_mesh_all_connected :: proc(mesh: ^Sim_Mesh) -> bool {
	n := len(mesh.nodes)
	for i in 0 ..< n {
		if mesh.crashed[i] do continue
		_ = sim_bind_node(mesh.nodes[i])
		for j in 0 ..< n {
			if j == i || mesh.crashed[j] do continue
			node_id, ok := get_node_by_name(mesh.names[j])
			if !ok do return false
			ring := get_connection_ring(node_id)
			if ring == nil || sync.atomic_load(&ring.state) != .Ready do return false
		}
	}
	return true
}

sim_mesh_settle_pools :: proc(mesh: ^Sim_Mesh, max_rounds: int = 10) -> bool {
	for _ in 0 ..< max_rounds {
		if sim_mesh_pools_primary_only(mesh) {
			_ = sim_bind_node(mesh.prev_node)
			return true
		}
		sim_mesh_advance_clock(mesh, 30 * time.Second)
		_ = sim_mesh_run_until_idle(mesh)
	}
	settled := sim_mesh_pools_primary_only(mesh)
	_ = sim_bind_node(mesh.prev_node)
	return settled
}

@(private = "file")
sim_mesh_pools_primary_only :: proc(mesh: ^Sim_Mesh) -> bool {
	for i in 0 ..< len(mesh.nodes) {
		if mesh.crashed[i] do continue
		_ = sim_bind_node(mesh.nodes[i])
		for node_id in 1 ..< Node_ID(MAX_NODES) {
			pool := get_connection_pool(node_id)
			if pool == nil do continue
			if sync.atomic_load_explicit(&pool.ring_count, .Acquire) > 1 do return false
		}
	}
	return true
}

sim_mesh_advance_clock :: proc(mesh: ^Sim_Mesh, d: time.Duration) {
	mesh.det.virtual_now = time.time_add(mesh.det.virtual_now, d)
	if mesh.det.virtual_tick_ns != 0 do mesh.det.virtual_tick_ns += i64(d)
	sim_wake_transport_waiters()
}

sim_mesh_partition :: proc(mesh: ^Sim_Mesh, i, j: int) {
	sim_block_link(mesh.nodes[i], mesh.nodes[j])
}

sim_mesh_sever :: proc(mesh: ^Sim_Mesh, i, j: int, deliver_error := false) {
	sim_sever_link(mesh.nodes[i], mesh.nodes[j], deliver_error)
}

sim_mesh_heal :: proc(mesh: ^Sim_Mesh, i, j: int) {
	sim_unblock_link(mesh.nodes[i], mesh.nodes[j])
}

sim_mesh_crash :: proc(mesh: ^Sim_Mesh, i: int) {
	if mesh.crashed[i] do return
	mesh.crashed[i] = true
	node := mesh.nodes[i]
	sim_transport_drop_node(node)
	for j in 0 ..< len(mesh.nodes) {
		if j != i do sim_unblock_link(node, mesh.nodes[j])
	}
	append(&mesh.graveyard, node)
}

sim_mesh_restart :: proc(mesh: ^Sim_Mesh, i: int) -> ^Node_State {
	if !mesh.crashed[i] do return mesh.nodes[i]
	mesh.nodes[i] = sim_mesh_boot_node(mesh, i)
	mesh.crashed[i] = false
	sim_mesh_register_peers(mesh, i)
	_ = sim_bind_node(mesh.prev_node)
	return mesh.nodes[i]
}

sim_mesh_destroy :: proc(mesh: ^Sim_Mesh) {
	if g_sim_active_mesh == mesh do g_sim_active_mesh = nil
	for i in 0 ..< len(mesh.nodes) {
		for j in i + 1 ..< len(mesh.nodes) {
			sim_unblock_link(mesh.nodes[i], mesh.nodes[j])
		}
	}
	for i in 0 ..< len(mesh.nodes) {
		if !mesh.crashed[i] do sim_transport_drop_node(mesh.nodes[i])
	}
	for i in 0 ..< len(mesh.nodes) {
		if mesh.crashed[i] do continue
		_ = sim_bind_node(mesh.nodes[i])
		node_shutdown()
		sim_destroy_node(mesh.nodes[i])
	}
	for node in mesh.graveyard {
		_ = sim_bind_node(node)
		node_shutdown()
		sim_destroy_node(node)
	}
	sim_transport_assert_quiescent()
	for name in mesh.names {
		delete(name, get_system_allocator())
	}
	delete(mesh.nodes)
	delete(mesh.names)
	delete(mesh.ports)
	delete(mesh.crashed)
	delete(mesh.graveyard)
	ti.det = mesh.prev_det
	sim_seed(0)
	NODE = mesh.prev_node
	free(mesh, get_system_allocator())
}
