package actod

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:time"

CACHE_LINE_SIZE :: 64 // TODO:
SYSTEM_MAILBOX_SIZE :: 16

SPIN_STRATEGY :: enum {
	CPU_RELAX,
	WAKE_SEMA,
}

Network_Config :: struct {
	auth_password:           string,
	port:                    int,
	heartbeat_interval:      time.Duration,
	heartbeat_timeout:       time.Duration,
	reconnect_initial_delay: time.Duration,
	reconnect_retry_delay:   time.Duration,
	connection_ring:         Connection_Ring_Config,
}

DEFAULT_NETWORK_CONFIG := Network_Config {
	auth_password           = "",
	port                    = 0,
	heartbeat_interval      = 30 * time.Second,
	heartbeat_timeout       = 90 * time.Second,
	reconnect_initial_delay = 2 * time.Second,
	reconnect_retry_delay   = 3 * time.Second,
	connection_ring         = DEFAULT_CONNECTION_RING_CONFIG,
}

make_network_config :: proc(
	auth_password: string = DEFAULT_NETWORK_CONFIG.auth_password,
	port: int = DEFAULT_NETWORK_CONFIG.port,
	heartbeat_interval: time.Duration = DEFAULT_NETWORK_CONFIG.heartbeat_interval,
	heartbeat_timeout: time.Duration = DEFAULT_NETWORK_CONFIG.heartbeat_timeout,
	reconnect_initial_delay: time.Duration = DEFAULT_NETWORK_CONFIG.reconnect_initial_delay,
	reconnect_retry_delay: time.Duration = DEFAULT_NETWORK_CONFIG.reconnect_retry_delay,
	connection_ring: Connection_Ring_Config = DEFAULT_NETWORK_CONFIG.connection_ring,
) -> Network_Config {
	return Network_Config {
		auth_password = auth_password,
		port = port,
		heartbeat_interval = heartbeat_interval,
		heartbeat_timeout = heartbeat_timeout,
		reconnect_initial_delay = reconnect_initial_delay,
		reconnect_retry_delay = reconnect_retry_delay,
		connection_ring = connection_ring,
	}
}

System_Config :: struct {
	actor_registry_size:   int,
	allow_registry_growth: bool,
	messages_to_register:  []typeid,
	enable_observer:       bool,
	observer_interval:     time.Duration, // Collection interval, 0 for manual only
	network:               Network_Config,
	actor_config:          Actor_Config,
	blocking_child:        SPAWN, // For main thread blocking actor
	worker_count:          int, // 0 = auto (CPU count)
	hot_reload_dev:        bool, // Spawns Hot_Reload_Actor, enables file watching + auto-reload
	hot_reload_watch_path: string, // Override actors directory (default "" = auto-discover)
}

SYSTEM_CONFIG := System_Config {
	actor_registry_size = 256, // Default: 16K actors (power-of-2)
	allow_registry_growth = true, // Enable auto-growth
	messages_to_register = []typeid{},
	enable_observer = false,
	observer_interval = 0,
	network = DEFAULT_NETWORK_CONFIG,
	blocking_child = nil,
	actor_config = Actor_Config {
		children = nil,
		page_size = mem.Kilobyte * 64,
		spin_strategy = .WAKE_SEMA,
		message_batch = BATCH_SIZE,
		logging = Log_Config {
			level = .Info,
			console_opts = log.Options{.Level, .Terminal_Color} | log.Full_Timestamp_Opts,
			file_opts = log.Options{.Level, .Short_File_Path} | log.Full_Timestamp_Opts,
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
		coro_stack_size = mem.Kilobyte * 56,
		use_dedicated_os_thread = false,
	},
}

make_node_config :: proc(
	actor_registry_size: int = SYSTEM_CONFIG.actor_registry_size,
	allow_registry_growth: bool = SYSTEM_CONFIG.allow_registry_growth,
	enable_observer: bool = SYSTEM_CONFIG.enable_observer,
	observer_interval: time.Duration = SYSTEM_CONFIG.observer_interval,
	network: Network_Config = SYSTEM_CONFIG.network,
	actor_config: Actor_Config = SYSTEM_CONFIG.actor_config,
	blocking_child: SPAWN = SYSTEM_CONFIG.blocking_child,
	worker_count: int = SYSTEM_CONFIG.worker_count,
	hot_reload_dev: bool = SYSTEM_CONFIG.hot_reload_dev,
	hot_reload_watch_path: string = SYSTEM_CONFIG.hot_reload_watch_path,
) -> System_Config {
	return System_Config {
		actor_registry_size = actor_registry_size,
		allow_registry_growth = allow_registry_growth,
		enable_observer = enable_observer,
		observer_interval = observer_interval,
		network = network,
		actor_config = actor_config,
		blocking_child = blocking_child,
		worker_count = worker_count,
		hot_reload_dev = hot_reload_dev,
		hot_reload_watch_path = hot_reload_watch_path,
	}
}

Actor_Config :: struct {
	children:                       [dynamic]SPAWN,
	spin_strategy:                  SPIN_STRATEGY,
	message_batch:                  int,
	logging:                        Log_Config,
	page_size:                      int,
	// Supervision configuration
	supervision_strategy:           Supervision_Strategy,
	restart_policy:                 Restart_Policy,
	max_restarts:                   int,
	restart_window:                 time.Duration,
	home_worker:                    int, // -1 = auto round-robin (default), 0+ = pin to worker index
	affinity:                       Actor_Ref, // co-locate with this actor (by PID or name)
	// Coroutine stack size for pooled actors (default 16KB)
	coro_stack_size:                int,
	// Run on a dedicated OS thread instead of the worker pool
	use_dedicated_os_thread:        bool,
	// Internal use only - set via blocking_child in node config
	blocking:                       bool,
	// Stack size per actor thread in bytes (0 = OS default)
	stack_size_dedicated_os_thread: int,
}

// user overrides config sent to node in actor.NODE_INIT
make_actor_config :: proc(
	children: [dynamic]SPAWN = nil,
	spin_strategy: SPIN_STRATEGY = SYSTEM_CONFIG.actor_config.spin_strategy,
	logging: Log_Config = SYSTEM_CONFIG.actor_config.logging,
	message_batch: int = SYSTEM_CONFIG.actor_config.message_batch,
	page_size: int = SYSTEM_CONFIG.actor_config.page_size,
	supervision_strategy: Supervision_Strategy = SYSTEM_CONFIG.actor_config.supervision_strategy,
	restart_policy: Restart_Policy = SYSTEM_CONFIG.actor_config.restart_policy,
	max_restarts: int = SYSTEM_CONFIG.actor_config.max_restarts,
	restart_window: time.Duration = SYSTEM_CONFIG.actor_config.restart_window,
	home_worker: int = SYSTEM_CONFIG.actor_config.home_worker,
	affinity: Actor_Ref = SYSTEM_CONFIG.actor_config.affinity,
	coro_stack_size: int = SYSTEM_CONFIG.actor_config.coro_stack_size,
	use_dedicated_os_thread: bool = SYSTEM_CONFIG.actor_config.use_dedicated_os_thread,
	stack_size_dedicated_os_thread: int = SYSTEM_CONFIG.actor_config.stack_size_dedicated_os_thread,
) -> Actor_Config {
	return Actor_Config {
		logging = logging,
		spin_strategy = spin_strategy,
		children = children,
		message_batch = message_batch,
		page_size = page_size,
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
	level: log.Level = SYSTEM_CONFIG.actor_config.logging.level,
	console_opts: log.Options = SYSTEM_CONFIG.actor_config.logging.console_opts,
	file_opts: log.Options = SYSTEM_CONFIG.actor_config.logging.file_opts,
	ident: string = SYSTEM_CONFIG.actor_config.logging.ident,
	enable_file: bool = SYSTEM_CONFIG.actor_config.logging.enable_file,
	log_path: string = SYSTEM_CONFIG.actor_config.logging.log_path,
	custom_logger: Log_Callback = SYSTEM_CONFIG.actor_config.logging.custom_logger,
	custom_flush: Log_Flush = SYSTEM_CONFIG.actor_config.logging.custom_flush,
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
