# Networking

Actod supports distributed actor systems where multiple nodes communicate over TCP. Actors on different nodes interact transparently. `send_message` routes based on the PID's embedded node ID.

## Architecture

```
Node A (:5000)                    Node B (:5001)
  [Actor 1] ──send_message──→ [Actor 3]
  [Actor 2] ←─send_message─── [Actor 4]
         ↕ TCP connection ring ↕
```

Each node-to-node link uses a connection actor that manages the TCP socket, heartbeats, and message serialization.

## Setup

```odin
// Node A, listen and register spawn functions
act.node_init("nodeA", opts = act.make_node_config(
    network = act.make_network_config(port = 5000, auth_password = "secret"),
))
act.register_spawn_func("worker", spawn_worker)

// Node B, connect to Node A
act.node_init("nodeB", opts = act.make_node_config(
    network = act.make_network_config(port = 5001, auth_password = "secret"),
))
_, _ = act.register_node("nodeA", net.Endpoint{address = ..., port = 5000})
```

> **Note:** the current `register_node` still takes a trailing `transport: Transport_Strategy` argument (pass `.TCP_Custom_Protocol`). That argument is slated for removal, so treat `register_node(name, address)` as the stable shape and don't build code around the transport value.

## Configuration

```odin
act.make_network_config(
    port                    = 0,             // 0 = networking disabled
    bind_address            = "127.0.0.1",   // loopback by default; see Trust boundary
    auth_password           = "",            // empty = no auth
    enable_encryption       = false,         // Noise NNpsk0 over the TCP link
    udp_port                = 0,             // 0 = no UDP lane
    udp_max_datagram        = 1400,          // requested cap (see UDP Lane)
    heartbeat_interval      = 30 * time.Second,
    heartbeat_timeout       = 90 * time.Second,
    reconnect_initial_delay = 2 * time.Second,
    reconnect_retry_delay   = 3 * time.Second,
)
```

`connection_ring` is a `Connection_Ring_Config` field for expert tuning of the per-node send ring (slot counts, buffer sizes, Nagle). It has working defaults; leave it unset unless you have a measured reason to change it. There is no builder for it, populate the struct directly if needed.

## Trust boundary

The listener binds `bind_address` (TCP and, when enabled, the UDP lane). The default is `127.0.0.1`, so out of the box only processes on the same host can connect. To accept nodes from other machines, set `bind_address = "0.0.0.0"` (or a specific interface IP) explicitly.

Two rules are enforced at `node_init`:

- **A non-loopback bind requires a password.** `bind_address` beyond loopback with an empty `auth_password` is refused at startup. Any host that reaches the port would otherwise join the mesh with full authority.
- **A non-loopback bind without `enable_encryption` warns.** Plaintext challenge-response proves the peer knows the password, but the exchange is offline-crackable and post-handshake frames carry no integrity protection. Treat plaintext mode as LAN-trusted-only.

Know what the password grants: an authenticated peer is **fully trusted**. It can spawn any registered behaviour on this node, deliver messages to any actor by name, and terminate actors. The password is cluster admission, not per-action authorization; only share it with nodes you would let run arbitrary registered code.

## Encryption

Set `enable_encryption = true` with a shared `auth_password` to encrypt every node-to-node TCP link. The link is secured with a Noise `NNpsk0` handshake (`Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s`); the password is the cluster key, derived into the pre-shared key.

```odin
act.make_network_config(
    port              = 5000,
    enable_encryption = true,
    auth_password     = "shared-cluster-secret",
)
```

Rules:

- **Both nodes must agree.** Both ends must set `enable_encryption` and the *same* `auth_password`. If one side is encrypted and the other is not, the HELLO exchange reports an encryption-mode mismatch and the connection is refused. If both are encrypted but the passwords differ, the Noise handshake fails. Either way the connection never reaches `Ready`, so no messages flow.
- **A mismatch shows up in the logs** as a failed handshake ("Encryption mode mismatch..." or "Noise handshake failed (wrong cluster password?)").
- **A password is required with encryption.** `enable_encryption` needs a non-empty `auth_password` (or the `ACTOD_AUTH_PASSWORD` env var); an empty password would derive a fixed, world-known key, so `node_init` rejects that combination at startup.

Without `enable_encryption`, a non-empty `auth_password` still gives you challenge-response authentication on the link (peers prove they know the password), but the traffic itself is sent in the clear.

## UDP Lane

Setting `udp_port` opens a node-wide UDP socket alongside the TCP listener. Once it is enabled, `send_unreliable(pid, msg)` delivers over UDP: **at-most-once, unordered, and silently lossy**. Use it only for data where dropping a message is acceptable (telemetry, position updates, and similar).

```odin
act.node_init("nodeA", opts = act.make_node_config(
    network = act.make_network_config(
        port              = 5000,
        udp_port          = 6000,
        enable_encryption = true,
        auth_password     = "shared-cluster-secret",
    ),
))

// elsewhere, from within an actor
_ = act.send_unreliable(remote_pid, Telemetry{...})
```

`send_unreliable` transparently falls back to the reliable TCP path when UDP cannot be used: for local PIDs, for messages too large for a single datagram, or for peers that have no UDP lane. A UDP send that is attempted but lost in the network is *not* retried and reports `.OK`.

Notes:

- **Small size cap.** The effective per-message size limit is about 2 KB (`UDP_FRAME_BUFFER` in `network_udp.odin`), regardless of the `udp_max_datagram` you request. Larger messages fall back to TCP.
- **Pair it with encryption.** UDP datagrams are authenticated and encrypted using keys established during the (encrypted) TCP handshake. Plaintext UDP (UDP lane on, encryption off) is unauthenticated and is not a recommended mode; run the UDP lane together with `enable_encryption`.

## Sending to Remote Actors

```odin
// Transparent, same API as local
err := act.send_message(remote_pid, MyMessage{data = 42})

// Or by name
err = act.send_message_name("worker@nodeA", MyMessage{data = 42})
```

`actor@node` sends resolve on the owning node and need no mirror.
`get_actor_pid("worker@nodeA")` is a local lookup and only covers registered
nodes' mirrors.

The PID encodes the node ID in the upper 16 bits. `send_message` checks `is_local_pid(to)` and routes to the connection ring automatically.

**`.OK` means buffered, not delivered.** For a remote send, `send_message` returns `.OK` as soon as the message is accepted into that node's per-node send buffer. The buffer keeps filling even while the peer is disconnected, and its contents are flushed when the connection (re)establishes. So `.OK` does *not* mean the message was delivered, or even that the peer is currently reachable. There is no "is this node connected?" helper yet; design for messages that may sit buffered until a peer comes back. A remote send only returns an error (for example `.NODE_DISCONNECTED` or `.NETWORK_RING_FULL`) when it cannot even be buffered. The full local/remote send contract is in [Delivery Semantics](14_delivery-semantics.md).

**Important:** Remote message types must be identical across nodes, same struct, same package, same registration. See [Message Registration: Cross-Node Messages](03_message-registration.md#cross-node-messages).

Variable-width fields (`string` and `[]u8`) serialize transparently across nodes, deep-copied into the receiver's own memory. Because the wire layout is derived from the struct's field order, every node in a mesh must run the same actod version and the same message definitions.

## Remote Spawning

```odin
// From Node B, spawn an actor on Node A
remote_pid, ok := act.spawn_remote(
    "worker",       // registered spawn function name
    "my_worker",    // actor name
    "nodeA",        // target node
)

// Send to it, same API
_ = act.send_message(remote_pid, Work_Item{...})
```

`spawn_remote` sends a request to the target node, which calls the registered spawn function and returns the new PID. The calling node creates a remote proxy in its local registry.

## Node Discovery and Actor Mirrors

How this node learned about a peer decides what it gets from it:

- **Registered** (`register_node`): the peer's actor mirror: a registry snapshot
  at handshake plus live spawn/terminate broadcasts. `get_actor_pid("worker@nodeA")`
  resolves locally.
- **Discovered** (node directory, incoming connection, gossip): the node is known
  and addressable. `actor@node` sends resolve on the owning node, PIDs route,
  pub/sub works. No mirror.

Mirrors are per direction. Registering a discovered node requests the stream
immediately on a live connection, otherwise at the next handshake.

### Mesh Propagation

Node existence spreads transitively through handshake node directories,
independent of mirrors. Lifecycle broadcasts go only to stream subscribers, carry
a TTL (default 3), and are relayed to a small rotating fanout, not flooded. A
receiver only applies mirror entries from source nodes it registered. Duplicates
are ignored.

The per-source out-of-order window is bounded (`GOSSIP_AHEAD_LIMIT`); on
overflow the frontier skips lost sequences, healed by the next snapshot.

Gossip is trusted per **incarnation** and deduplicated per **event**: a node
generates a random incarnation id at boot, stamps every broadcast it originates
with it plus a dense sequence number, and the handshake carries both with the
current frontier. Receivers drop relays with a stale incarnation, and events
already covered directly or by the frontier; uncovered relays are applied and
forwarded. Broadcasts on the source's own connection are authoritative and
refresh the incarnation. Terminations inferred from a lost connection are
ignored by nodes still connected to the affected node.

## PID Routing

PIDs encode the node ID in the upper 16 bits:

```
[node_id:16][actor_type:8][generation:16][index:24]
```

- `node_id` 0 = reserved, 1 = local, 2+ = remote nodes
- `send_message` checks `is_local_pid(to)`:
  - **Local**: direct mailbox delivery
  - **Remote**: serialize into the connection ring buffer, flush to TCP

## Cross-Node Pub/Sub

Type-based subscriptions work across nodes:

```odin
// Node A subscribes to LOGGER_TYPE
sub, ok := act.subscribe_type(LOGGER_TYPE)

// Node B broadcasts, reaches Node A subscribers
act.broadcast(Log_Entry{text = "hello from B"})
```

Subscription state is synced between nodes. Each node tracks remote subscriber counts per actor type. Subscriptions are announced when they are created and re-announced to every peer whose connection completes a handshake, so subscribers are seen by broadcaster nodes that connect (or reconnect) later. This lane is independent of actor mirrors; no `register_node` is needed on either side.

## Failure Handling

- **Heartbeats**: Sent at `heartbeat_interval` (default 30s). Node marked dead after `heartbeat_timeout` (default 90s).
- **Reconnection**: Automatic with exponential backoff. `reconnect_initial_delay` (2s) then `reconnect_retry_delay` (3s) between attempts.
- **Cleanup**: Mirrored actor proxies (registered nodes) are removed from the registry when a node disconnects. Local actors sending to dead remotes get `NODE_DISCONNECTED` errors.

## Fan-Out and RLIMIT_MEMLOCK (Linux)

Each peer connection runs an IO thread with its own io_uring instance, whose queues count against the process's locked-memory limit (`ulimit -l`, commonly 8MB). With the default nbio queue size (`ODIN_NBIO_QUEUE_SIZE=2048`), a process holding roughly 6 or more connection rings can fail `io_uring_setup` with `Allocation_Failed`; the connection then closes and reconnects in a loop, dropping buffered sends after they returned `.OK`.

If a node talks to many peers (high mesh fan-out), either build with `-define:ODIN_NBIO_QUEUE_SIZE=256` (a 10-node full mesh runs comfortably at this setting) or raise the memlock limit. The runtime error message names both options when it happens.

## API

```odin
// Node management
// The trailing transport argument is being removed; treat register_node(name, address) as stable.
register_node :: proc(name: string, address: net.Endpoint) -> (Node_ID, bool)
get_node_by_name :: proc(name: string) -> (Node_ID, bool)
get_node_info :: proc(node_id: Node_ID) -> (Node_Info, bool)
unregister_node :: proc(node_id: Node_ID)

// Remote spawning
register_spawn_func :: proc(name: string, func: SPAWN) -> bool
spawn_remote :: proc(
    spawn_func_name: string,
    actor_name: string,
    target_node: string,
    parent_pid: PID = 0,
    timeout: time.Duration = SPAWN_REMOTE_TIMEOUT,
) -> (PID, bool)

// Transparent messaging
send_message :: proc(to: PID, content: $T) -> Send_Error // routes automatically
send_unreliable :: proc(to: PID, content: $T) -> Send_Error // UDP lane, falls back to TCP
send_message_name :: proc(to: string, content: $T) -> Send_Error // "actor@node" format
send_to :: proc(actor_name: string, node_name: string, content: $T) -> Send_Error

// Node identity
get_local_node_name :: proc() -> string
get_local_node_pid :: proc() -> PID
is_local_pid :: proc(pid: PID) -> bool
get_node_id :: proc(pid: PID) -> Node_ID
```

---
[< Logging](09_logging.md) | [Hot Reload >](11_hot-reload.md)
