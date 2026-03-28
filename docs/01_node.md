# Node

## Design Philosophy

Actod trades lightweight actors for consistent latency. Actors run as coroutines on a fixed pool of worker threads, but each actor owns its memory — a dedicated virtual memory arena, a pre-allocated message pool, and its own MPSC mailbox ring buffers. This makes actors heavier than minimal coroutine-based systems, but it means message sends are bounded-time operations with no shared allocator contention. Small messages (<=32 bytes) are inline with zero allocation. Larger messages come from the actor's own pool. Maps and dynamic arrays are excluded from messages intentionally — every send has predictable cost regardless of payload content.

## Memory Model

You don't manage memory for messages. The framework handles it:

- **Sending**: When you call `send_message(pid, my_struct)`, the framework copies the struct into the receiver's memory. You don't allocate, and you don't free. The sender's copy is untouched.
- **Receiving**: The `content: any` in `handle_message` points to the framework's copy. It's valid for the duration of the callback. Don't store the pointer — the memory is recycled after the callback returns.
- **Actor state**: Your data struct (the `$T` in `Actor_Behaviour(T)`) lives in a per-actor virtual memory arena. The framework allocates it during `spawn` and frees it during termination. You don't call `new` or `free` for actor state.
- **Children and config**: Dynamic arrays in actor config (like `children`) are cloned into the actor's arena. The original can be freed after `spawn` returns.

## Overview

The node is the root of the actor system. It manages worker threads, the actor registry, and system actors (timer, observer, hot reload).

## Lifecycle

```odin
import act "actod"

main :: proc() {
    act.NODE_INIT("myapp", act.make_node_config(
        worker_count = 4,
        actor_config = act.make_actor_config(
            children = act.make_children(spawn_worker),
        ),
    ))

    act.await_signal() // blocks until SIGINT/SIGTERM
}
```

`NODE_INIT` must be called before spawning any actors. It:

1. Initializes the actor registry
2. Starts the worker pool (coroutine schedulers)
3. Spawns the node actor and its children
4. Starts system actors (timer, optionally observer and hot reload)

`SHUTDOWN_NODE` gracefully terminates all actors through the supervision hierarchy. `await_signal` blocks until an OS signal is received, then calls `SHUTDOWN_NODE` automatically.

## API

```odin
NODE_INIT :: proc(name: string, opts: System_Config = SYSTEM_CONFIG)
SHUTDOWN_NODE :: proc()
await_signal :: proc()
get_local_node_name :: proc() -> string
get_local_node_pid :: proc() -> PID
```

## Configuration

```odin
act.make_node_config(
    worker_count          = 0,      // 0 = auto (CPU count)
    actor_registry_size   = 256,    // Initial capacity (power-of-2)
    allow_registry_growth = true,   // Dynamic expansion
    actor_config          = ...,    // Default config for all actors
    network               = ...,    // Network_Config for distributed mode
    enable_observer       = false,  // Stats collection
    observer_interval     = 0,      // 0 = manual collection only
    blocking_child        = nil,    // Main-thread blocking actor
    hot_reload_dev        = false,  // File watching + auto-reload
    hot_reload_watch_path = "",     // Override actors directory
)
```

The `actor_config` set on the node becomes the default for every actor. Individual actors override it by passing their own config to `spawn`.

## Worker Pool

Workers are OS threads that run actor coroutines cooperatively. Each worker has:

- A ready queue for pending actors
- A `runnext` fast-path slot for same-worker wakeups
- A semaphore for sleeping when idle

The number of workers defaults to the CPU core count. Workers are pinned to cores for cache locality.

---
[< Getting Started](00_getting-started.md) | [Actor >](02_actor.md)
