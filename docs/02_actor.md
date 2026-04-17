# Actor

Actors are the fundamental unit of concurrency. Each actor has typed state, a behaviour (message handler), and its own mailbox. Actors communicate exclusively through message passing.

## Spawning

```odin
import act "actod"

Counter :: struct {
    count: int,
}

counter_behaviour := act.Actor_Behaviour(Counter){
    handle_message = proc(d: ^Counter, from: act.PID, msg: any) {
        switch m in msg {
        case string:
            d.count += 1
            act.send_message(from, d.count)
        }
    },
    init = proc(d: ^Counter) {
        // called once after spawn
    },
    terminate = proc(d: ^Counter) {
        // called during shutdown
    },
}

pid, ok := act.spawn("counter", Counter{}, counter_behaviour)
```

`spawn` takes a name, initial state, and behaviour. Returns a PID and success flag.

### Worker Affinity

Actors on the same worker communicate ~3x faster. Use `affinity` to co-locate actors that communicate heavily:

```odin
// By pid
sender, _   := act.spawn("sender", Sender{}, sender_behaviour,
    act.make_actor_config(affinity = act.Actor_Ref(pid)),
)

// Also works by name
sender, _   := act.spawn("sender", Sender{}, sender_behaviour,
    act.make_actor_config(affinity = act.Actor_Ref("receiver")),
)
```

If the target actor can't be resolved, falls through to the default round-robin placement. For explicit control, use `home_worker` in actor config.

### Spawn Variants

```odin
// Standard spawn
pid, ok := act.spawn("worker", Worker{}, worker_behaviour)

// Spawn as child of the current actor (sets parent automatically)
child_pid, ok := act.spawn_child("child", Child{}, child_behaviour)

// Spawn using a registered spawn function by name
pid, ok := act.spawn_by_name("worker", "worker-1")

// Spawn on a remote node (see network.md)
pid, ok := act.spawn_remote("worker", "worker-1", "nodeA")
```

## Behaviour

```odin
Actor_Behaviour :: struct($T: typeid) {
    handle_message: proc(data: ^T, from: PID, content: any),  // required
    init:           proc(data: ^T),                             // optional
    terminate:      proc(data: ^T),                             // optional
    actor_type:     Actor_Type,                                 // 0 = untyped

    // supervisor callbacks (optional)
    on_child_started:         proc(data: ^T, child_pid: PID),
    on_child_terminated:      proc(data: ^T, child_pid: PID, reason: Termination_Reason, will_restart: bool),
    on_child_restarted:       proc(data: ^T, old_pid: PID, new_pid: PID, restart_count: int),
    on_max_restarts_exceeded: proc(data: ^T, child_pid: PID),
}
```

Only `handle_message` is required. All callbacks receive a pointer to the actor's typed state.

## Sending Messages

```odin
act.send_message(target_pid, MyMessage{value = 42})
```

Messages are copied into the receiver's memory. The receiver owns the copy. Any struct can be a message — complex types with pointers (maps, dynamic arrays) are not allowed.

### Send Variants

```odin
// By PID (most common)
act.send_message(target_pid, MyMessage{value = 42})

// By name (local or remote with "actor@node" format)
act.send_message_name("worker", MyMessage{value = 42})
act.send_message_name("worker@nodeA", MyMessage{value = 42})

// By name with PID cache — skips lookup on repeated sends to the same name.
// Auto-refreshes if the actor restarts with a new PID.
act.send_by_name_cached("worker", MyMessage{value = 42})

// Explicit remote: actor name + node name
act.send_to("worker", "nodeA", MyMessage{value = 42})

// Convenience — must be called from within an actor
act.send_self(MyMessage{value = 42})
act.send_message_to_parent(MyMessage{value = 42})
act.send_message_to_children(MyMessage{value = 42})

// Priority sends
act.send_message_high(target_pid, Urgent{})   // mailbox[0], processed first
act.send_message_low(target_pid, Background{}) // mailbox[2], processed last
```

All send functions return `Send_Error`:

```odin
Send_Error :: enum {
    OK,
    ACTOR_NOT_FOUND,
    RECEIVER_BACKLOGGED, // mailbox full or message pool exhausted
    MESSAGE_TOO_LARGE,   // message exceeds actor's configured page_size
    SYSTEM_SHUTTING_DOWN,
    NETWORK_ERROR,
    NETWORK_RING_FULL,
    NODE_NOT_FOUND,
    NODE_DISCONNECTED,
}
```

### Batch Priority Control

For sending multiple messages at the same priority, set it once:

```odin
act.set_send_priority(.HIGH)
for target in targets {
    act.send_message(target, msg)
}
act.reset_send_priority()  // back to NORMAL
```

## Priority Mailboxes

Each actor has three priority mailboxes (HIGH, NORMAL, LOW) plus a system mailbox.

```odin
Message_Priority :: enum u8 {
    HIGH   = 0,
    NORMAL = 1,  // default
    LOW    = 2,
}
```

System messages (terminate, supervision) use the dedicated system mailbox and are always processed first.

## Actor Context

Within an actor's callbacks:

```odin
act.get_self_pid() -> PID
act.get_self_name() -> string
act.get_parent_pid() -> PID
act.self_terminate(reason)
act.yield()  // cooperatively yield for pooled actors
act.now()    // current time (virtual in tests, real in production)
```

### Renaming

Actors can be renamed at runtime. This updates the registry so `get_actor_pid` resolves the new name.

```odin
// From outside
act.rename_actor(pid, "new-name")

// From within the actor
act.self_rename("new-name")
```

## Execution Models

**Pooled (default):** Actor runs as a coroutine on a worker thread. Shares CPU time with other actors on the same worker. Non-blocking — yields cooperatively.

```odin
act.make_actor_config(
    coro_stack_size = 56 * 1024,  // coroutine stack (default 56KB)
)
```

**Dedicated thread:** Actor gets its own OS thread. Use for blocking I/O or CPU-intensive work.

```odin
act.make_actor_config(
    use_dedicated_os_thread = true,
    stack_size_dedicated_os_thread = 128 * 1024,
)
```

## Lifecycle States

```
ZERO -> INIT -> RUNNING -> STOPPING -> THREAD_STOPPED -> TERMINATED
                  ^  |
                  |  v
                 IDLE
```

- **INIT** — Running init callback
- **RUNNING** — Processing messages
- **IDLE** — Waiting for messages (dedicated thread only)
- **STOPPING** — Received terminate, running cleanup
- **TERMINATED** — Fully cleaned up

## Termination

```odin
act.terminate_actor(pid, reason)
```

Termination reasons:

```odin
Termination_Reason :: enum {
    NORMAL,          // clean shutdown
    ABNORMAL,        // crash or panic
    SHUTDOWN,        // parent/system requested
    MAX_RESTARTS,    // exceeded restart limit
    INTERNAL_ERROR,  // actor detected error
    KILLED,          // forcefully killed
}
```

Actors recover from panics automatically. The panic is caught, the actor transitions to STOPPING, and the supervisor decides whether to restart based on the restart policy.

---
[< Node](01_node.md) | [Message Registration >](03_message-registration.md)
