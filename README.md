# Actod

[![CI](https://github.com/Jonathan-Rowles/actod/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Jonathan-Rowles/actod/actions/workflows/ci.yml)

**High-performance actor runtime for the [Odin programming language](https://odin-lang.org/).**

Actors run as coroutines on a fixed worker pool: no thread-per-actor overhead. Messages are copied into the receiver's memory buffer via lock-free MPSC queues. The receiver owns the message.

See [docs](docs/00_getting-started.md) for the full reference.

> **v0.3**, API may change before v1. Tested on Linux x86_64, macOS Apple Silicon, and Windows x86_64.

## Performance

| Test | Category | Apple M4 Air (10c) | Linux x86 (16c) |
|------|----------|---------------|-----------------|
| 1:1 32B | Base | 84M msgs/sec | 61M msgs/sec |
| 1:1 1KB | Base | 20M msgs/sec | 20M msgs/sec |
| 4x 32B parallel | Parallel | 236M msgs/sec | 234M msgs/sec |
| 4:1 32KB fan-in | Fan-in | 2.3M msgs/sec (70 GB/s) | 2.9M msgs/sec (89 GB/s) |
| 2:2 Ping-Pong | Contention | 42M msgs/sec | 46M msgs/sec |

### Round-Trip Latency (Ping-Pong)

| Size | p50 (M4 / x86) | p99 (M4 / x86) |
|------|-----------------|-----------------|
| 32B | 167ns / 300ns | 292ns / 464ns |
| 4KB | 542ns / 420ns | 917ns / 560ns |

### Network (TCP loopback)

| Test | Apple M4 Air (10c) | Linux x86 (16c) |
|------|---------------|-----------------|
| 1:1 32B | 18.87M msgs/sec | 5.16M msgs/sec |
| 1:1 256B | 12.35M msgs/sec | 4.83M msgs/sec |
| 1:1 1KB | 4.81M msgs/sec | 2.14M msgs/sec |

## Usage

### Installation

Vendor actod into your project, pinned to a release tag. Submodule recommended:

```bash
git submodule add https://github.com/Jonathan-Rowles/actod.git vendor/actod
cd vendor/actod && git checkout v0.3.0 && cd -
git commit -am "Vendor actod v0.3.0"
```

Build with a collection flag pointing at the vendored repo:

```bash
odin build . -collection:actod=vendor/actod
```

Then import the public interface (`act.odin`) from anywhere in your project:

```odin
import act "actod"
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
    act.node_init("myapp", act.make_node_config(
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

**Distributed actors.** Remote and local sends use the same API. PIDs encode the node ID. `send_message` routes transparently. Actor lifecycle events gossip across the mesh so every node maintains a proxy registry.

```odin
// Every node must register each message type it sends or receives.
@(init)
register_types :: proc "contextless" () {
    act.register_message_type(Work_Item)
}

// Node A
act.node_init("nodeA", act.make_node_config(
    network = act.make_network_config(port = 5000),
))
act.register_spawn_func("worker", spawn_worker)

// Node B, same send API as local
remote_pid, ok := act.spawn_remote("worker", "w1", "nodeA")
act.send_message(remote_pid, Work_Item{})
```

`send_message` returns `.OK` once the message is accepted into the target node's send buffer, which can happen even while that node is disconnected (it buffers and delivers on reconnect). `.OK` does not mean "delivered" or "peer reachable." See [Networking](docs/10_network.md).

**Priority mailboxes.** Three per-actor mailboxes (high, normal, low) plus a dedicated system mailbox processed first. Send at priority with the optional `priority` argument to `send_message` (`.HIGH` / `.NORMAL` / `.LOW`).

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
- **Receiving**: `content: any` in `handle_message` is valid for the duration of the callback. Don't store the pointer: memory is recycled when the callback returns.
- **Actor state**: Lives in a per-actor arena. Allocated on `spawn`, freed on termination.

Maps and dynamic arrays are excluded from messages intentionally. Every send has predictable cost regardless of payload.

---

## Configuration

Three config builders, all with sensible defaults:

```odin
act.node_init("myapp", act.make_node_config(
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
- Cross-node topics
- Cross-node config changes (system msgs)
