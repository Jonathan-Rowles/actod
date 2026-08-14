# Delivery Semantics

What a send result promises, and what it never promises. Every send proc returns a `Send_Error` and is `@(require_results)`: the compiler rejects a bare call, so you either handle the result or discard it deliberately with `_ =`.

## The Short Version

- `.OK` means **accepted**, never processed. Locally: the message is in the receiver's mailbox. Remotely: the message is in this node's send buffer; the peer may not even be connected.
- **Per-sender FIFO, always.** Messages from one sender to one receiver arrive in send order. Overload never reorders and never silently drops; a send either lands in order or returns an error.
- If you need to know a message was **processed**, have the receiver reply. Nothing else in the runtime tells you. The built-in [`ask`/`reply` pair](02_actor.md#ask--reply) does exactly this, with a correlation token and a timeout.

## Send_Error Reference

| Error | Meaning | Retry? |
|-------|---------|--------|
| `OK` | Accepted: receiver's mailbox (local) or this node's send buffer (remote) | n/a |
| `ACTOR_NOT_FOUND` | No live actor behind that PID or name; a stale PID from before a restart counts | Only after re-resolving the target (`get_actor_pid`) |
| `RECEIVER_BACKLOGGED` | Receiver made no progress for the whole stall window: it is stuck, not busy | Retryable, but treat it as an overload signal (see below) |
| `MESSAGE_TOO_LARGE` | Message exceeds the actor's configured `page_size` | No. Config error: raise `page_size` or shrink the message |
| `SYSTEM_SHUTTING_DOWN` | Node is shutting down | No |
| `NETWORK_ERROR` | Transport failure on a remote send | With backoff |
| `NETWORK_RING_FULL` | This node's send buffer for the peer is full | With backoff; the peer is not draining |
| `NODE_NOT_FOUND` | Target node id is not registered on this node | After `register_node` |
| `NODE_DISCONNECTED` | Peer is known but the message could not be buffered | With backoff; normally the buffer absorbs disconnects |
| `NOT_ASKED` | `reply()` when the current message is not an ask, or `ask()` outside an actor | No, caller bug |

## Local Sends

The message is copied at the call site: inline for small plain structs, into the receiver's own page pool otherwise. The receiver owns the copy; `.OK` means it is queued, nothing more.

When the mailbox or page pool is full, the sender blocks instead of failing: coroutine senders yield and retry, dedicated-thread senders sleep. The sender watches the receiver's progress the whole time. `RECEIVER_BACKLOGGED` is returned only after the receiver has made **no progress for `-define:ACTOD_SEND_STALL_TIMEOUT_MS`** (default 100, wall-clock). A slow-but-healthy receiver costs the sender latency, never messages; a stuck or dead receiver fails the send in about 100ms.

### Supervision Signals

Local termination signals are lossless. A dying actor does not send `Actor_Stopped` through a mailbox: it links its own embedded death record into its supervisor's stop-signal chain, which cannot fill (an actor stops exactly once, so capacity is bounded by construction). Restarts and node-side cleanup never compete with telemetry for mailbox slots and are never dropped under load. Cross-node `Actor_Stopped` rides the wire like any other message and keeps remote-send semantics.

## Remote Sends

`.OK` means the message was committed into this node's send buffer for the peer. The buffer keeps accepting while the peer is disconnected and flushes on (re)connect. There is no peer acknowledgement, and a remote send does not check whether the target actor exists on the peer:

- A remote send to a dead actor still returns `.OK`. The peer drops it there.
- A message whose type the receiving node never registered is dropped on the receiver with a warning in the **receiver's** log; the sender saw `.OK`. Register message types on every node ([Message Registration](03_message-registration.md#cross-node-messages)).
- `send_unreliable` is at-most-once: a datagram lost in flight already returned `.OK`.

Local and remote failure modes differ: local sends can return `ACTOR_NOT_FOUND` and `RECEIVER_BACKLOGGED`; remote sends return the `NODE_*`/`NETWORK_*` errors and never the local pair.

## Handling RECEIVER_BACKLOGGED

`RECEIVER_BACKLOGGED` after a real stall window means sustained overload, not a blip. In order of preference:

1. **Size the receiver for its bursts.** A fan-in receiver that legitimately queues thousands of messages should be spawned with a bigger mailbox: `act.spawn_sized("ingest", Ingest{}, ingest_behaviour, 4096)`. Senders then stay on the fast path instead of parking.
2. **Shed at the edge.** Count and drop the work where it enters the system, while the information about the overload still exists.
3. **Defer, don't spin.** Park the work in your own state and retry on a timer tick; the runtime already spent 100ms retrying for you.

```odin
handle_message = proc(d: ^Router, from: act.PID, msg: any) {
    switch m in msg {
    case Job:
        err := act.send_message(d.worker, m)
        #partial switch err {
        case .OK:
        case .RECEIVER_BACKLOGGED:
            d.shed_count += 1
        case .ACTOR_NOT_FOUND:
            d.worker, _ = act.get_actor_pid("worker")
        case:
            log.errorf("dispatch failed: %v", err)
        }
    }
}
```

Mailbox capacity, the blocking behaviour, and `spawn_sized` are covered in [Actor: Mailboxes](02_actor.md#mailboxes).

---
[< Test Harness](13_test-harness.md)
