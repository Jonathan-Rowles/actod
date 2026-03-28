# Logging

Each actor has its own logger with configurable level and output options. Logging uses Odin's `core:log` package — actors call `log.infof(...)` etc. as normal, and the runtime routes output through the actor's configured logger.

## Configuration

Set logging defaults at the node level, override per actor:

```odin
act.NODE_INIT("myapp", act.make_node_config(
    actor_config = act.make_actor_config(
        logging = act.make_log_config(
            level       = .Info,
            enable_file = true,
            log_path    = "logs",
        ),
    ),
))

// This actor logs at Debug level with a custom ident
act.spawn("verbose_worker", Worker{}, worker_behaviour, act.make_actor_config(
    logging = act.make_log_config(
        level = .Debug,
        ident = "worker",
    ),
))
```

## Log Config

```odin
act.make_log_config(
    level         = .Info,           // minimum log level
    console_opts  = ...,             // log.Options for console output
    file_opts     = ...,             // log.Options for file output
    ident         = "",              // prefix added to log lines
    enable_file   = false,           // write to file
    log_path      = "log",           // directory for log files
    custom_logger = nil,             // custom callback: proc(level, text, location)
    custom_flush  = nil,             // custom flush callback
)
```

## Runtime Control

From within an actor, change the log level at runtime:

```odin
handle_message = proc(d: ^Data, from: act.PID, msg: any) {
    switch m in msg {
    case Enable_Debug:
        act.set_log_level(.Debug)
    case Disable_Debug:
        act.set_log_level(.Info)
    }
},
```

## API

```odin
// Set the log level for the current actor. Must be called from within an actor.
set_log_level :: proc(level: log.Level)

// Check if a level would produce output at the current setting.
is_log_level_enabled :: proc(level: log.Level) -> bool

// Get the current actor's log config.
get_current_log_config :: proc() -> Log_Config

// Build a log config with defaults.
make_log_config :: proc(...) -> Log_Config
```

## Custom Logger

For integration with external logging systems, provide a callback:

```odin
act.make_log_config(
    custom_logger = proc(level: log.Level, text: string, location: runtime.Source_Code_Location) {
        // forward to your logging system
    },
    custom_flush = proc() {
        // flush buffered output
    },
)
```

---
[< Observer](08_observer.md) | [Networking >](10_network.md)
