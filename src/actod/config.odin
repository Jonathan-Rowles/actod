package actod

import "../pkgs/coro"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:time"

CACHE_LINE_SIZE :: 64
SYSTEM_MAILBOX_SIZE :: 16

DEFAULT_CORO_STACK_SIZE :: mem.Kilobyte * 56 when !coro.ASAN_FIBERS else mem.Kilobyte * 512

Network_Config :: struct {
	auth_password:           string,
	bind_address:            string,
	port:                    int,
	udp_port:                int,
	udp_max_datagram:        int,
	enable_encryption:       bool,
	heartbeat_interval:      time.Duration,
	heartbeat_timeout:       time.Duration,
	reconnect_initial_delay: time.Duration,
	reconnect_retry_delay:   time.Duration,
	connection_ring:         Connection_Ring_Config,
}

DEFAULT_NETWORK_CONFIG := Network_Config {
	auth_password           = "",
	bind_address            = "127.0.0.1",
	port                    = 0,
	udp_port                = 0,
	udp_max_datagram        = 1400,
	enable_encryption       = false,
	heartbeat_interval      = 30 * time.Second,
	heartbeat_timeout       = 90 * time.Second,
	reconnect_initial_delay = 2 * time.Second,
	reconnect_retry_delay   = 3 * time.Second,
	connection_ring         = DEFAULT_CONNECTION_RING_CONFIG,
}

make_network_config :: proc(
	port: int = NODE.config.network.port,
	bind_address: string = NODE.config.network.bind_address,
	auth_password: string = NODE.config.network.auth_password,
	enable_encryption: bool = NODE.config.network.enable_encryption,
	udp_port: int = NODE.config.network.udp_port,
	udp_max_datagram: int = NODE.config.network.udp_max_datagram,
	heartbeat_interval: time.Duration = NODE.config.network.heartbeat_interval,
	heartbeat_timeout: time.Duration = NODE.config.network.heartbeat_timeout,
	reconnect_initial_delay: time.Duration = NODE.config.network.reconnect_initial_delay,
	reconnect_retry_delay: time.Duration = NODE.config.network.reconnect_retry_delay,
	connection_ring: Connection_Ring_Config = NODE.config.network.connection_ring,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Network_Config {
	if port < 0 || port > 65535 {
		panic_at(loc, "make_network_config: port must be 0-65535, got %d", port)
	}
	if _, bind_ok := parse_bind_address(bind_address); !bind_ok {
		panic_at(
			loc,
			"make_network_config: bind_address must be an IP address (e.g. \"127.0.0.1\", \"0.0.0.0\", \"::\"), got %q",
			bind_address,
		)
	}
	if udp_port < 0 || udp_port > 65535 {
		panic_at(loc, "make_network_config: udp_port must be 0-65535, got %d", udp_port)
	}
	if udp_max_datagram <= 0 {
		panic_at(
			loc,
			"make_network_config: udp_max_datagram must be > 0, got %d",
			udp_max_datagram,
		)
	}
	if connection_ring.send_slot_count != 0 && !is_power_of_two(connection_ring.send_slot_count) {
		panic_at(
			loc,
			"make_network_config: connection_ring.send_slot_count must be a power of 2, got %d",
			connection_ring.send_slot_count,
		)
	}
	if connection_ring.recv_buffer_size < 0 {
		panic_at(
			loc,
			"make_network_config: connection_ring.recv_buffer_size must be >= 0, got %d",
			connection_ring.recv_buffer_size,
		)
	}

	return Network_Config {
		auth_password = auth_password,
		bind_address = bind_address,
		port = port,
		udp_port = udp_port,
		udp_max_datagram = udp_max_datagram,
		enable_encryption = enable_encryption,
		heartbeat_interval = heartbeat_interval,
		heartbeat_timeout = heartbeat_timeout,
		reconnect_initial_delay = reconnect_initial_delay,
		reconnect_retry_delay = reconnect_retry_delay,
		connection_ring = connection_ring,
	}
}

System_Config :: struct {
	actor_registry_size:   int,
	actor_slab_slots:      int,
	enable_observer:       bool,
	observer_interval:     time.Duration,
	network:               Network_Config,
	actor_config:          Actor_Config,
	blocking_child:        SPAWN,
	worker_count:          int,
	hot_reload_dev:        bool,
	hot_reload_watch_path: string,
	sim_mode:              bool,
	loc:                   runtime.Source_Code_Location,
}

DEFAULT_SYSTEM_CONFIG := System_Config {
	actor_registry_size = 256,
	actor_slab_slots = DEFAULT_ACTOR_SLAB_SLOTS,
	enable_observer = false,
	observer_interval = 0,
	network = DEFAULT_NETWORK_CONFIG,
	blocking_child = nil,
	actor_config = Actor_Config {
		children = nil,
		page_size = DEFAULT_PAGE_SIZE,
		arena_headroom = DEFAULT_ARENA_HEADROOM,
		logging = Log_Config {
			level = .Info,
			console_opts = log.Options{.Level, .Terminal_Color, .Short_File_Path, .Line} |
			log.Full_Timestamp_Opts,
			file_opts = log.Options{.Level, .Short_File_Path, .Line} | log.Full_Timestamp_Opts,
			ident = "",
			enable_file = false,
			log_path = "log",
		},
		supervision_strategy = Supervision_Strategy.ONE_FOR_ONE,
		restart_policy = Restart_Policy.PERMANENT,
		max_restarts = 3,
		restart_window = 5 * time.Second,
		home_worker = -1,
		affinity = nil,
		stack_size_dedicated_os_thread = mem.Kilobyte * 128,
		coro_stack_size = DEFAULT_CORO_STACK_SIZE,
		use_dedicated_os_thread = false,
	},
}

make_node_config :: proc(
	worker_count: int = NODE.config.worker_count,
	actor_config: Actor_Config = NODE.config.actor_config,
	network: Network_Config = NODE.config.network,
	enable_observer: bool = NODE.config.enable_observer,
	observer_interval: time.Duration = NODE.config.observer_interval,
	actor_registry_size: int = NODE.config.actor_registry_size,
	actor_slab_slots: int = NODE.config.actor_slab_slots,
	hot_reload_dev: bool = NODE.config.hot_reload_dev,
	hot_reload_watch_path: string = NODE.config.hot_reload_watch_path,
	blocking_child: SPAWN = NODE.config.blocking_child,
	sim_mode: bool = NODE.config.sim_mode,
	loc: runtime.Source_Code_Location = #caller_location,
) -> System_Config {
	if actor_registry_size <= 0 {
		panic_at(
			loc,
			"make_node_config: actor_registry_size must be > 0, got %d (it is rounded up to a power of two)",
			actor_registry_size,
		)
	}
	if next_power_of_two(actor_registry_size) > REGISTRY_MAX_CAPACITY {
		panic_at(
			loc,
			"make_node_config: actor_registry_size %d rounds up to %d, above REGISTRY_MAX_CAPACITY %d",
			actor_registry_size,
			next_power_of_two(actor_registry_size),
			REGISTRY_MAX_CAPACITY,
		)
	}
	if worker_count < 0 {
		panic_at(
			loc,
			"make_node_config: worker_count must be >= 0 (0 = one per CPU), got %d",
			worker_count,
		)
	}
	if actor_slab_slots < 0 {
		panic_at(
			loc,
			"make_node_config: actor_slab_slots must be >= 0 (0 disables the slab), got %d",
			actor_slab_slots,
		)
	}

	return System_Config {
		loc = loc,
		actor_registry_size = actor_registry_size,
		actor_slab_slots = actor_slab_slots,
		enable_observer = enable_observer,
		observer_interval = observer_interval,
		network = network,
		actor_config = actor_config,
		blocking_child = blocking_child,
		worker_count = worker_count,
		hot_reload_dev = hot_reload_dev,
		hot_reload_watch_path = hot_reload_watch_path,
		sim_mode = sim_mode,
	}
}

DEFAULT_ARENA_HEADROOM :: #config(ACTOD_ARENA_HEADROOM, mem.Megabyte * 16)

Actor_Config :: struct {
	children:                       [dynamic]SPAWN,
	logging:                        Log_Config,
	page_size:                      int,
	arena_headroom:                 int,
	supervision_strategy:           Supervision_Strategy,
	restart_policy:                 Restart_Policy,
	max_restarts:                   int,
	restart_window:                 time.Duration,
	home_worker:                    int,
	affinity:                       Actor_Ref,
	coro_stack_size:                int,
	use_dedicated_os_thread:        bool,
	stack_size_dedicated_os_thread: int,
	loc:                            runtime.Source_Code_Location,
}

// user overrides config sent to node in actor.node_init
make_actor_config :: proc(
	logging: Log_Config = NODE.config.actor_config.logging,
	restart_policy: Restart_Policy = NODE.config.actor_config.restart_policy,
	max_restarts: int = NODE.config.actor_config.max_restarts,
	restart_window: time.Duration = NODE.config.actor_config.restart_window,
	supervision_strategy: Supervision_Strategy = NODE.config.actor_config.supervision_strategy,
	children: [dynamic]SPAWN = nil,
	page_size: int = NODE.config.actor_config.page_size,
	arena_headroom: int = NODE.config.actor_config.arena_headroom,
	coro_stack_size: int = NODE.config.actor_config.coro_stack_size,
	home_worker: int = NODE.config.actor_config.home_worker,
	affinity: Actor_Ref = NODE.config.actor_config.affinity,
	use_dedicated_os_thread: bool = NODE.config.actor_config.use_dedicated_os_thread,
	stack_size_dedicated_os_thread: int = NODE.config.actor_config.stack_size_dedicated_os_thread,
	loc: runtime.Source_Code_Location = #caller_location,
) -> Actor_Config {
	if page_size < CACHE_LINE_SIZE * 2 {
		panic_at(
			loc,
			"make_actor_config: page_size must be at least %d B, got %d",
			CACHE_LINE_SIZE * 2,
			page_size,
		)
	}
	if home_worker < -1 {
		panic_at(
			loc,
			"make_actor_config: home_worker must be -1 (auto) or a worker index, got %d",
			home_worker,
		)
	}
	if max_restarts < 0 {
		panic_at(loc, "make_actor_config: max_restarts must be >= 0, got %d", max_restarts)
	}
	if arena_headroom < 0 {
		panic_at(loc, "make_actor_config: arena_headroom must be >= 0, got %d", arena_headroom)
	}
	if stack_size_dedicated_os_thread < 0 {
		panic_at(
			loc,
			"make_actor_config: stack_size_dedicated_os_thread must be >= 0, got %d",
			stack_size_dedicated_os_thread,
		)
	}

	return Actor_Config {
		loc = loc,
		logging = logging,
		children = children,
		page_size = page_size,
		arena_headroom = arena_headroom,
		supervision_strategy = supervision_strategy,
		restart_policy = restart_policy,
		max_restarts = max_restarts,
		restart_window = restart_window,
		home_worker = home_worker,
		affinity = affinity,
		coro_stack_size = coro_stack_size,
		use_dedicated_os_thread = use_dedicated_os_thread,
		stack_size_dedicated_os_thread = stack_size_dedicated_os_thread,
	}
}

Log_Callback :: proc(level: log.Level, text: string, location: runtime.Source_Code_Location)
Log_Flush :: proc()

Log_Config :: struct {
	level:         log.Level,
	console_opts:  log.Options,
	file_opts:     log.Options,
	ident:         string,
	enable_file:   bool,
	log_path:      string,
	custom_logger: Log_Callback,
	custom_flush:  Log_Flush,
}

make_log_config :: proc(
	level: log.Level = NODE.config.actor_config.logging.level,
	ident: string = NODE.config.actor_config.logging.ident,
	enable_file: bool = NODE.config.actor_config.logging.enable_file,
	log_path: string = NODE.config.actor_config.logging.log_path,
	console_opts: log.Options = NODE.config.actor_config.logging.console_opts,
	file_opts: log.Options = NODE.config.actor_config.logging.file_opts,
	custom_logger: Log_Callback = NODE.config.actor_config.logging.custom_logger,
	custom_flush: Log_Flush = NODE.config.actor_config.logging.custom_flush,
) -> Log_Config {
	return Log_Config {
		level = level,
		console_opts = console_opts,
		file_opts = file_opts,
		ident = ident,
		enable_file = enable_file,
		log_path = log_path,
		custom_logger = custom_logger,
		custom_flush = custom_flush,
	}
}

make_children :: proc(spawns: ..SPAWN) -> [dynamic]SPAWN {
	result: [dynamic]SPAWN
	for s in spawns {
		append(&result, s)
	}
	return result
}

is_power_of_two :: #force_inline proc(n: $T) -> bool where intrinsics.type_is_integer(T) {
	return n > 0 && (n & (n - 1)) == 0
}

next_power_of_two :: proc(n: int) -> int {
	if n <= 0 do return 1
	v := n - 1
	v |= v >> 1
	v |= v >> 2
	v |= v >> 4
	v |= v >> 8
	v |= v >> 16
	when size_of(int) == 8 {
		v |= v >> 32
	}
	return v + 1
}
