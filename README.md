# Actod

[![CI](https://github.com/Jonathan-Rowles/actod/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Jonathan-Rowles/actod/actions/workflows/ci.yml)

Actor runtime for [Odin](https://odin-lang.org/). Coroutines on a fixed worker pool (not one thread per actor). Sends copy the message into the receiver's mailbox over lock-free MPSC queues. Receiver owns it; no alloc/free on the hot path.

`sim_mode = true` means zero OS threads: you step the node from the calling thread under a seeded scheduler, so a failed run replays from that seed. The suite uses that for real multi-node setups on one thread (handshakes, wire format, virtual transport) plus a seed-driven fuzzer in the FoundationDB/TigerBeetle VOPR style: partitions, crashes, restarts, clock jumps, per-link frame faults, then checks delivery and convergence.

> **v0.4**, API may still move before v1. Linux x86_64, macOS Apple Silicon, Windows x86_64.

## A first actor

```odin
Counter :: struct { total: int }

counter_behaviour := act.Actor_Behaviour(Counter) {
    init = proc(d: ^Counter) {
        _ = act.send_self(Add{amount = 42})
    },
    handle_message = proc(d: ^Counter, from: act.PID, msg: any) {
        switch m in msg {
        case Add:
            d.total += m.amount
            log.infof("total: %d", d.total)
        }
    },
}

main :: proc() {
    act.node_init("hello", act.make_node_config(
        actor_config = act.make_actor_config(
            children = act.make_children(spawn_counter),
        ),
    ))
    act.await_signal()
}
```

`node_init` takes a config and blocks on `await_signal`. Node children get a supervisor without extra setup. Bigger apps mostly mean more spawn fns in `make_children`.

[`docs/comedy_club.odin`](docs/comedy_club.odin) is a small runnable pair of actors. `cd docs && odin run .`

Walkthrough and reference: [Getting Started](docs/00_getting-started.md).

## Performance

| Test | Apple M4 Air (10c) | Linux x86 (16c) |
|------|--------------------|-----------------|
| 1:1 32B | 84M msgs/sec | 63M msgs/sec |
| 1:1 1KB | 20M msgs/sec | 18M msgs/sec |
| 4x 32B parallel | 236M msgs/sec | 249M msgs/sec |
| 4:1 32KB fan-in | 2.3M msgs/sec (70 GB/s) | 2.6M msgs/sec (79 GB/s) |
| 2:2 ping-pong | 42M msgs/sec | 72M msgs/sec |

Ping-pong RTT, 32B: p50 167ns / 238ns, p99 292ns / 598ns (M4 / x86). At 4KB: p50 542ns / 356ns, p99 917ns / 1.2µs. x86 p99 wanders 0.5-2µs run to run; p50 stays within about ±1%.

TCP loopback 1:1: 18.9M / 19.0M msgs/sec at 32B, 12.4M / 7.7M at 256B, 4.8M / 5.5M at 1KB.

Bench sources live under [`benchmarks/`](benchmarks/). `make bench-single`, `make bench-network`, `make bench-footprint`.

## What's included

**Supervision.** Actor with children is a supervisor. one-for-one, one-for-all, rest-for-one; restart limits/windows; lifecycle callbacks.

**Distributed actors.** Local and remote `send_message` look the same. PID carries the node id; routing is internal. Lifecycle gossip keeps proxy registries filled on every node. `.OK` only means the target node's send buffer took the message (including while that node is offline and buffering for reconnect). It is not "delivered" and not "reachable". [Networking](docs/10_network.md), [Delivery Semantics](docs/14_delivery-semantics.md).

**Mailboxes.** Per actor, plus a system mailbox that runs first. Size is compile-time (default 32; `-define:ACTOD_MAILBOX_SIZE=N` or `act.spawn_sized(...)`). No runtime resize. Same-sender order is preserved. Full mailbox stalls the sender while the receiver drains; `RECEIVER_BACKLOGGED` only if the receiver is stuck. No silent drops, no reordering.

**Pub/sub.** Type-based (global, default cap 16384 subscribers, `-define:ACTOD_MAX_SUBSCRIBERS_PER_TYPE=N`) and topic-based (a `Topic` var/field, cap 64). Type pub/sub crosses nodes: one send per remote node that cares, then local fan-out there. Topics stay on-node.

**Timers.** One-shot and repeating, owned by a system actor. `act.now()` is virtual under sim, wall clock otherwise.

**Hot reload.** Replace `handle_message` (and other behaviour procs) on a live actor; state stays. Opt in with `import _ "actod/hot_reload_dev"`, so programs that never use it do not link it. `docs/hot_reload_example/`.

**Observer.** Interval stats per actor (counts, depths, uptime, per-sender/recipient), pushed to subscribers.

**Execution.** Default is pooled coroutines. `use_dedicated_os_thread` for blocking I/O or heavy CPU. `affinity` pins chatty actors onto the same worker (often up to ~2x on small messages).

**Test harness.** Single-actor unit harness (sync, no threads, virtual time) and multi-actor sim with deterministic delivery, faults, and a virtual clock that squishes timer races into microseconds. [Test Harness](docs/13_test-harness.md).

```odin
// Drop 30% of messages to "receiver", 5 times
sim.add_fault(&s, {
    match       = { to_name = "receiver", msg_type = MyMessage },
    action      = .Drop,
    count       = 5,
    probability = 0.3,
})
```

## Memory model

- **Sending**: `send_message(pid, my_struct)` copies into receiver memory. You neither allocate nor free; your local copy is left alone.
- **Receiving**: the `any` in `handle_message` lives for that call only. Do not stash the pointer; that slot is reused when you return.
- **Actor state**: per-actor arena, alloc on spawn, free on terminate.

Maps and dynamic arrays are not valid message payloads. That keeps send cost predictable.

## Install

Odin `dev-2026-07a` or newer (whatever CI pins under `release:` in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) wins). Pin actod to a tag:

```bash
git submodule add https://github.com/Jonathan-Rowles/actod.git vendor/actod
cd vendor/actod && git checkout v0.4.0 && cd -
odin build . -collection:actod=vendor/actod
```

`import act "actod"` after that. Node knobs: [Node](docs/01_node.md).

## Roadmap

- Cross-node topics
- Cross-node config changes (system msgs)
