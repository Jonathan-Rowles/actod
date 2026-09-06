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
    on_idle:        proc(data: ^T),                             // optional, dedicated thread only
    on_wake:        proc "contextless" (data: ^T),              // optional, pairs with on_idle
    actor_type:     Actor_Type,                                 // 0 = untyped

    // supervisor callbacks (optional)
    on_child_started:         proc(data: ^T, child_pid: PID),
    on_child_terminated:      proc(data: ^T, child_pid: PID, child_name: string, reason: Termination_Reason, will_restart: bool),
    on_child_restarted:       proc(data: ^T, old_pid: PID, new_pid: PID, restart_count: int),
    on_max_restarts_exceeded: proc(data: ^T, child_pid: PID, child_name: string),
}
```

Only `handle_message` is required. All callbacks receive a pointer to the actor's typed state.

The two termination callbacks carry `child_name` because the child is already dead when they fire and the node reaps its registry entry asynchronously, so `get_actor_name(child_pid)` there is a race: sometimes the name, sometimes `"<unknown>"`. The parameter is the only reliable answer. It is borrowed for the duration of the call, exactly like `content: any`: copy it if you keep it. A local child's name arrives truncated to 64 bytes (`STOP_SIGNAL_NAME_CAP`), while a remote child's arrives in full, so do not key a supervisor off `child_name` for names that long. `on_child_started` and `on_child_restarted` take no name because the child is live at that point and `get_actor_name` resolves.

## Sending Messages

```odin
if err := act.send_message(target_pid, MyMessage{value = 42}); err != .OK {
    log.errorf("send failed: %v", err)
}
```

Messages are copied into the receiver's memory. The receiver owns the copy. Any struct can be a message. Complex types with pointers (maps, dynamic arrays) are not allowed.

Every send proc is `@(require_results)`: the compiler rejects a bare call, so handle the `Send_Error` or discard it deliberately with `_ =`. See [Delivery Semantics](14_delivery-semantics.md) for what each result promises.

### Send Variants

```odin
// By PID (most common)
err := act.send_message(target_pid, MyMessage{value = 42})

// By name (local or remote with "actor@node" format)
err = act.send_message_name("worker", MyMessage{value = 42})
err = act.send_message_name("worker@nodeA", MyMessage{value = 42})

// Explicit remote: actor name + node name
err = act.send_to("worker", "nodeA", MyMessage{value = 42})

// Convenience, must be called from within an actor
err = act.send_self(MyMessage{value = 42})
err = act.send_message_to_parent(MyMessage{value = 42})
err = act.send_message_to_children(MyMessage{value = 42})
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
    NOT_ASKED,           // reply() without a pending ask, or ask() outside an actor
}
```

## Ask / Reply

`ask` sends a request carrying a correlation token; the reply arrives later as a normal message. There is no blocking call: the actor keeps processing its mailbox, and actor state carries any per-request context.

```odin
// Requester
handle_message = proc(d: ^Trader, from: act.PID, msg: any) {
    switch m in msg {
    case Do_Trade:
        token, err := act.ask(d.pricer, Quote{symbol = m.symbol}, 500 * time.Millisecond)
        if err == .OK {
            d.pending[token] = m.symbol
        }
    case Price:
        token, _ := act.replying_to()
        symbol := d.pending[token]
        delete_key(&d.pending, token)
        execute(d, symbol, m.value)
    case act.Ask_Timeout:
        delete_key(&d.pending, m.token)
    }
}

// Responder
handle_message = proc(d: ^Pricer, from: act.PID, msg: any) {
    switch m in msg {
    case Quote:
        _ = act.reply(Price{value = lookup(d, m.symbol)})
    }
}
```

- The reply arrives raw: match its type in the switch, then `replying_to()` returns the token when the current message answers one of this actor's asks.
- If no reply lands within the timeout (default 5s), `Ask_Timeout{token}` is delivered instead. A reply arriving after the timeout is dropped; the requester never sees both.
- `reply` targets the sender of the ask currently being handled and returns `NOT_ASKED` when the current message is not an ask. Replying is optional: an unanswered ask just times out.
- Works across nodes: the token rides the wire and the reply routes back to the asking PID.
- Ask and reply messages always use the message pool, never the inline fast path.
- Like other generic send helpers, `ask` and `reply` are not callable from hot-reloaded modules.

## Mailboxes

Each actor has a single mailbox plus a dedicated system mailbox. Messages from the
same sender are delivered in send order. A full mailbox blocks the sender (coroutine
senders yield, dedicated threads sleep) for as long as the receiver keeps draining;
`RECEIVER_BACKLOGGED` is returned only after the receiver has made no progress for
`-define:ACTOD_SEND_STALL_TIMEOUT_MS` (default 100), never as a reorder or a silent
drop.

Mailbox capacity is a compile-time constant, fixed for the actor's lifetime: the
mailbox never grows, shrinks, or reallocates.

```odin
// Global default: 64 slots, overridable at build time.
// odin build . -define:ACTOD_MAILBOX_SIZE=1024

// Per actor: pass a compile-time power of two to spawn_sized.
pid, ok := act.spawn_sized("ingest", Ingest{}, ingest_behaviour, 4096)
pid, ok = act.spawn_child_sized("burst-worker", Worker{}, worker_behaviour, 2048)
```

The per-actor message pool scales with the mailbox: an actor that can queue N
messages can also hold N non-inline payloads in flight.

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

**Pooled (default):** Actor runs as a coroutine on a worker thread. Shares CPU time with other actors on the same worker. Non-blocking, yields cooperatively.

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

### Foreign event loops: `on_idle` and `on_wake`

A dedicated-thread actor normally sleeps on its mailbox semaphore when the mailbox is
empty. An actor that owns something else to wait on (a window system, a socket, a pipe)
cannot sleep in both, so `on_idle` replaces the semaphore wait: actod calls it with an
empty mailbox, the actor sleeps in its own wait, and returns so the loop can drain. It is
never reached by a pooled actor.

On its own that sleep is deaf to the mailbox. `on_wake` is the other half: a callback
actod invokes from the **sender's** thread whenever a message lands on the actor, so the
foreign wait can be interrupted.

```odin
behaviour := act.Actor_Behaviour(App) {
    init           = init,
    handle_message = handle,
    on_idle        = on_idle,
    on_wake        = on_wake,
}

init :: proc(a: ^App) {
    a.wake_fd = eventfd()
}

on_wake :: proc "contextless" (a: ^App) {
    if a.wake_fd > 0 {          // a send can land before init has run
        write_one(a.wake_fd)
    }
}

on_idle :: proc(a: ^App) {
    poll([a.wake_fd, a.socket_fd], timeout = -1)   // interrupted by any send, Terminate included
    drain(a.wake_fd)
    read_socket_if_ready(a)
}
```

Rules: the callback runs on another thread, so it must be cheap, thread safe, and must
not touch the actor's data beyond what it needs to signal. It can fire before `init` has
finished, so guard on what `init` creates. It fires for every delivery, including actod's
own `Terminate`, timer ticks and supervision messages, which is what makes the pairing
sound. Pooled actors never call it. Without `on_wake`, an `on_idle` wait must use a
timeout.

## Lifecycle States

```
ZERO -> INIT -> RUNNING -> STOPPING -> THREAD_STOPPED -> TERMINATED
                  ^  |
                  |  v
                 IDLE
```

- **INIT**: Running init callback
- **RUNNING**: Processing messages
- **IDLE**: Waiting for messages (dedicated thread only)
- **STOPPING**: Received terminate, running cleanup
- **TERMINATED**: Fully cleaned up

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
