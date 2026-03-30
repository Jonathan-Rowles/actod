# Actod <sub><sup>(WIP)</sup></sub>

**High-performance actor runtime for the [Odin programming language](https://odin-lang.org/).**

Actors run as coroutines on a fixed worker pool — no thread-per-actor overhead. Messages are copied into the receiver's memory buffer via lock-free MPSC queues. The receiver owns the message.

See [docs](docs/00_getting-started.md) for the full reference.

## Performance (10 cores)

| Test | Category | Throughput |
|------|----------|-----------|
| 1:1 Empty | Base | 92M msgs/sec |
| 1:1 32B | Base | 84M msgs/sec |
| 1:1 1KB | Base | 20M msgs/sec |
| 4x Empty parallel | Parallel | 304M msgs/sec |
| 4x 32B parallel | Parallel | 236M msgs/sec |
| 4x 1KB parallel | Parallel | 63M msgs/sec |
| 4:1 32KB fan-in | Fan-in | 2.3M msgs/sec (70 GB/s) |
| 2:2 Ping-Pong | Contention | 42M msgs/sec | 24ns |
| 10:4 32KB stress | Stress | 8.8M msgs/sec (34 GB/s) |
| Mesh 10:5 | Stress | 13M msgs/sec | 77ns |
| 20:1 Empty contention | Contention | 37M msgs/sec |

### Ping-Pong Latency

| Size | p50 | p99 | p99.9 |
|------|-----|-----|-------|
| 32B | 83ns | 146ns | 146ns |
| 256B | 146ns | 291ns | 333ns |
| 1KB | 187ns | 312ns | 333ns |
| 4KB | 271ns | 437ns | 479ns |

### Network (TCP loopback)

| Test | Throughput|
|------|-----------|
| 1:1 Empty | 18.25M msgs/sec |
| 1:1 32B | 18.87M msgs/sec |
| 1:1 256B | 12.35M msgs/sec |
| 1:1 1KB | 4.81M msgs/sec |
| 4x Empty parallel | 7.6M msgs/sec |
| 4x 32 parallel | 6.0M msgs/sec |
| 4x 256B parallel | 4.1M msgs/sec |
| 4x 1KB parallel | 1.8M msgs/sec |

## Usage

### Installation

```bash
# Add as a submodule or copy to your project
git clone https://github.com/jonathan-rowles/actod.git
```

### Minimal Application

```odin
import act "actod"

Worker :: struct { count: int }

worker_behaviour := act.Actor_Behaviour(Worker){
    handle_message = proc(d: ^Worker, from: act.PID, msg: any) {
        switch m in msg {
        case string:
            d.count += 1
            act.send_message(from, d.count)
        }
    },
}

spawn_worker :: proc(_name: string, _parent: act.PID) -> (act.PID, bool) {
    return act.spawn("worker", Worker{}, worker_behaviour)
}

main :: proc() {
    act.NODE_INIT("myapp", act.make_node_config(
        actor_config = act.make_actor_config(
            children = act.make_children(spawn_worker),
        ),
    ))

    act.await_signal() // block until SIGINT/SIGTERM
}
```

## What's included

**Supervision.** Any actor with children is a supervisor. Three restart strategies (one-for-one, one-for-all, rest-for-one), configurable restart limits and windows, and callbacks for every lifecycle transition.

```odin
act.make_actor_config(
    children             = act.make_children(spawn_worker1, spawn_worker2),
    supervision_strategy = .ONE_FOR_ONE,
    restart_policy       = .PERMANENT,
    max_restarts         = 3,
    restart_window       = 5 * time.Second,
)
```

**Distributed actors.** Remote and local sends use the same API. PIDs encode the node ID — `send_message` routes transparently. Actor lifecycle events gossip across the mesh so every node maintains a proxy registry.

```odin
// Node A
act.NODE_INIT("nodeA", act.make_node_config(
    network = act.make_network_config(port = 5000),
))
act.register_spawn_func("worker", spawn_worker)

// Node B — same send API as local
remote_pid, ok := act.spawn_remote("worker", "w1", "nodeA")
act.send_message(remote_pid, Work_Item{})
```

**Priority mailboxes.** Three per-actor mailboxes (high, normal, low) plus a dedicated system mailbox processed first. Send at priority with `send_message_high` / `send_message_low`, or set priority once for a batch.

**Pub/sub.** Type-based (global, up to 16384 subscribers) and topic-based (scoped to a struct field, up to 64 subscribers). Cross-node for type-based.

**Timers.** One-shot and repeating, managed by a dedicated system actor. `act.now()` returns virtual time in tests, real time in production.

**Hot reload.** Swap `handle_message` and other behaviour callbacks on live actors without restarting the node. State is preserved.
See `docs/hot_reload_example/` for a working example you can run and edit live.

**Observer.** Per-actor stats (message counts, mailbox depths, uptime, per-sender/recipient breakdowns) collected on a configurable interval and broadcast to subscribers.

**Test harness.** Two layers: a unit harness for single actors (synchronous, no threads, virtual time) and a simulation framework for multi-actor scenarios with deterministic message delivery, fault injection, and virtual time.

```odin
// Drop 30% of messages to "receiver", 5 times
sim.add_fault(&s, {
    match       = { to_name = "receiver", msg_type = MyMessage },
    action      = .Drop,
    remaining   = 5,
    probability = 0.3,
})
```

---

## Memory model

- **Sending**: `send_message(pid, my_struct)` copies the struct into the receiver's memory. You don't allocate. You don't free. The sender's copy is untouched.
- **Receiving**: `content: any` in `handle_message` is valid for the duration of the callback. Don't store the pointer — memory is recycled when the callback returns.
- **Actor state**: Lives in a per-actor arena. Allocated on `spawn`, freed on termination.

Maps and dynamic arrays are excluded from messages intentionally — every send has predictable cost regardless of payload.

---

## Configuration

Three config builders, all with sensible defaults:

```odin
act.NODE_INIT("myapp", act.make_node_config(
    worker_count = 0,              // 0 = auto (CPU count)
    actor_config = act.make_actor_config(
        message_batch = 64,
        restart_policy = .PERMANENT,
    ),
    network = act.make_network_config(
        port = 5000,
        auth_password = "secret",
    ),
    enable_observer = true,
    observer_interval = 5 * time.Second,
    hot_reload_dev = true,
))
```

The `actor_config` on the node is the default for every actor. Individual actors override by passing their own config to `spawn`.

---

## Execution models

**Pooled (default).** Actor runs as a coroutine on a worker thread. Shares CPU with other actors on the same worker. Yields cooperatively.

**Dedicated thread.** Actor gets its own OS thread. Use for blocking I/O or CPU-intensive work.

```odin
act.make_actor_config(
    use_dedicated_os_thread = true,
)
```

**Worker affinity.** Actors on the same worker communicate ~3x faster. Use `affinity` to co-locate actors that talk to each other:

```odin
receiver, _ := act.spawn("receiver", Receiver{}, receiver_behaviour)
sender, _   := act.spawn("sender", Sender{}, sender_behaviour,
    act.make_actor_config(affinity = act.Actor_Ref(receiver)),
)
```

---

## TODO
- TLS encryption for node-to-node communication
- Cross-node topics
- UDP Support
- Cross-node log config via system messages?

### Open Questions

- Do we need priority mailboxes??
- Ensure-once delivery ??
- Process memory sharing / actor spawn process?
- MPMC queue as actor config option?
- State snapshotting — provide call backs, or leave to user code?
- Actor registry max size appropriate for global mesh?
- Network discovery
- Dead letter queue with retry semantics
- Crash recovery (per-node, network-aware)??
