package actod

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

PANIC_MESSAGE_BUF_SIZE :: 512

@(private)
Actor_File_Logger :: struct {
	file_logger: log.Logger,
	file_handle: ^os.File,
	ident_str:   string,
}

@(private)
Actor_Logger_Data :: struct {
	console_logger: log.Logger,
	log_config:     Log_Config,
	name:           string,
	pid:            PID,
	is_node:        bool,
}

@(private, thread_local)
current_actor_context: ^Actor_Context
@(private, thread_local)
current_actor_file_logger: ^Actor_File_Logger

@(private)
actor_logger_data: ^Actor_Logger_Data

@(private)
actor_system_allocator: runtime.Allocator

@(private)
get_system_allocator :: #force_inline proc() -> runtime.Allocator {
	if actor_system_allocator.procedure == nil {
		actor_system_allocator = runtime.heap_allocator()
	}
	return actor_system_allocator
}

@(thread_local)
spawning_blocking_child: bool

@(private)
init_logger :: proc(config: Log_Config) -> log.Logger {
	actor_system_allocator = runtime.heap_allocator()
	actor_logger_data = new(Actor_Logger_Data, actor_system_allocator)

	actor_logger_data.log_config = config
	actor_logger_data.is_node = true

	actor_logger_data.console_logger = log.create_console_logger(
		lowest = config.level,
		opt = config.console_opts,
		ident = NODE.name,
		allocator = actor_system_allocator,
	)

	if config.enable_file {
		os.make_directory(config.log_path)
	}

	return log.Logger {
		procedure = actor_logger_proc,
		data = actor_logger_data,
		lowest_level = config.level,
		options = config.console_opts,
	}
}

cleanup_logger_and_context :: proc() {
	if actor_logger_data != nil {
		if actor_logger_data.log_config.custom_flush != nil {
			actor_logger_data.log_config.custom_flush()
		}
		log.destroy_console_logger(actor_logger_data.console_logger, actor_system_allocator)
		free(actor_logger_data, actor_system_allocator)
		actor_logger_data = nil
	}

	if current_actor_context != nil {
		cleanup_actor_context(current_actor_context)
		current_actor_context = nil
	}
}

@(private)
actor_logger_proc :: proc(
	logger_data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	data := cast(^Actor_Logger_Data)logger_data
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	final_text: string
	if data.is_node {
		final_text = fmt.tprintf(
			"[actod|%s] %s",
			SYSTEM_CONFIG.network.port > 0 ? fmt.tprint(SYSTEM_CONFIG.network.port) : "local",
			text,
		)
	} else {
		final_text = fmt.tprintf("[%s|%s] %s", data.name, data.pid, text)
	}

	data.console_logger.procedure(data.console_logger.data, level, final_text, options, location)

	if current_actor_file_logger != nil && current_actor_file_logger.file_logger.procedure != nil {
		file_options := options - {.Terminal_Color}
		current_actor_file_logger.file_logger.procedure(
			current_actor_file_logger.file_logger.data,
			level,
			final_text,
			file_options,
			location,
		)
	}

	if data.log_config.custom_logger != nil {
		data.log_config.custom_logger(level, final_text, location)
	}
}

@(private)
setup_actor_context :: proc(
	pid: PID,
	name: string,
	config: Log_Config = SYSTEM_CONFIG.actor_config.logging,
	actor_allocator: mem.Allocator,
) -> (
	log.Logger,
	^Actor_Context,
) {
	actor_ctx := new(Actor_Context, actor_allocator)
	actor_ctx.pid = pid
	actor_ctx.name = strings.clone(name, actor_allocator)
	actor_ctx.send_priority = .NORMAL

	actor_ctx.subscriptions = make([dynamic]Subscription, actor_allocator)
	actor_ctx.topic_subscriptions = make([dynamic]Topic_Subscription, actor_allocator)
	actor_ctx.timers = make([dynamic]Timer_Registration, actor_allocator)
	actor_ctx.stats.messages_received = 0
	actor_ctx.stats.messages_sent = 0
	actor_ctx.stats.received_list = make([dynamic]PID, actor_allocator)
	actor_ctx.stats.sent_list = make([dynamic]PID, actor_allocator)
	actor_ctx.stats.received_from = nil
	actor_ctx.stats.sent_to = nil
	actor_ctx.stats.start_time = time.now()
	actor_ctx.stats.max_mailbox_size = 0

	current_actor_context = actor_ctx

	if config.enable_file {
		os.make_directory(config.log_path)
		file_logger := new(Actor_File_Logger, actor_allocator)
		file_logger.file_handle = nil

		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		filename := strings.concatenate(
			[]string{config.log_path, "/", name, "-", fmt.tprint(pid), ".log"},
			context.temp_allocator,
		)

		handle, err := os.open(
			filename,
			os.O_CREATE | os.O_WRONLY | os.O_APPEND,
			os.perm_number(0o666),
		)

		if err == os.ERROR_NONE {
			file_logger.file_handle = handle

			if name == NODE.name || pid == NODE.pid {
				port_str :=
					SYSTEM_CONFIG.network.port > 0 ? fmt.tprint(SYSTEM_CONFIG.network.port) : "local"
				file_logger.ident_str = fmt.aprintf(
					"[actod|%s]",
					port_str,
					allocator = actor_allocator,
				)
			} else {
				file_logger.ident_str = fmt.aprintf(
					"[%s|%s]",
					name,
					pid,
					allocator = actor_allocator,
				)
			}

			file_logger.file_logger = log.create_file_logger(
				handle,
				config.level,
				config.file_opts,
				file_logger.ident_str,
				actor_allocator,
			)

			current_actor_file_logger = file_logger

			header := fmt.tprintf("\n\n=== Actor Log Started: %s (PID: %v) ===\n\n", name, pid)
			os.write_string(handle, header)
		} else {
			fmt.eprintln("Failed to create log file for actor:", name, "Error:", err)
			current_actor_file_logger = nil
		}
	}

	actor_log_data := new(Actor_Logger_Data, actor_allocator)
	actor_log_data.console_logger = log.create_console_logger(
		lowest = config.level,
		opt = config.console_opts,
		ident = NODE.name,
		allocator = actor_allocator,
	)
	actor_log_data.log_config = config
	actor_log_data.name = actor_ctx.name
	actor_log_data.pid = pid
	actor_log_data.is_node = (name == NODE.name || pid == NODE.pid)

	return log.Logger {
			procedure = actor_logger_proc,
			data = actor_log_data,
			lowest_level = config.level,
			options = config.console_opts,
		},
		actor_ctx
}

@(private)
cleanup_actor_context :: proc(actor_ctx: ^Actor_Context) {
	if current_actor_context != actor_ctx {
		return
	}

	if context.logger.data != nil {
		logger_data := cast(^Actor_Logger_Data)context.logger.data
		if logger_data.log_config.custom_flush != nil {
			logger_data.log_config.custom_flush()
		}
	}

	if current_actor_file_logger != nil {
		if current_actor_file_logger.file_handle != nil {
			footer := fmt.tprintf("\n=== Actor Log Ended ===\n")
			os.write_string(current_actor_file_logger.file_handle, footer)
			os.flush(current_actor_file_logger.file_handle)
			os.close(current_actor_file_logger.file_handle)
		}
	}

	current_actor_context = nil
	current_actor_file_logger = nil
}

is_log_level_enabled :: proc(level: log.Level) -> bool {
	return context.logger.lowest_level <= level
}

set_log_level :: proc(level: log.Level) {
	if actor_logger_data != nil {
		actor_logger_data.console_logger.lowest_level = level
		actor_logger_data.log_config.level = level
	}
	context.logger.lowest_level = level
}

get_current_log_config :: proc() -> Log_Config {
	if actor_logger_data != nil {
		return actor_logger_data.log_config
	}
	return SYSTEM_CONFIG.actor_config.logging
}
