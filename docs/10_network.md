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
act.send_unreliable(remote_pid, Telemetry{...})
```

`send_unreliable` transparently falls back to the reliable TCP path when UDP cannot be used: for local PIDs, for messages too large for a single datagram, or for peers that have no UDP lane. A UDP send that is attempted but lost in the network is *not* retried and reports `.OK`.

Notes:

- **Small size cap.** The effective per-message size limit is about 2 KB (`UDP_FRAME_BUFFER` in `network_udp.odin`), regardless of the `udp_max_datagram` you request. Larger messages fall back to TCP.
- **Pair it with encryption.** UDP datagrams are authenticated and encrypted using keys established during the (encrypted) TCP handshake. Plaintext UDP (UDP lane on, encryption off) is unauthenticated and is not a recommended mode; run the UDP lane together with `enable_encryption`.

## Sending to Remote Actors

```odin
// Transparent, same API as local
act.send_message(remote_pid, MyMessage{data = 42})

// Or by name
act.send_message_name("worker@nodeA", MyMessage{data = 42})
```

The PID encodes the node ID in the upper 16 bits. `send_message` checks `is_local_pid(to)` and routes to the connection ring automatically.

**`.OK` means buffered, not delivered.** For a remote send, `send_message` returns `.OK` as soon as the message is accepted into that node's per-node send buffer. The buffer keeps filling even while the peer is disconnected, and its contents are flushed when the connection (re)establishes. So `.OK` does *not* mean the message was delivered, or even that the peer is currently reachable. There is no "is this node connected?" helper yet; design for messages that may sit buffered until a peer comes back. A remote send only returns an error (for example `.NODE_DISCONNECTED` or `.NETWORK_RING_FULL`) when it cannot even be buffered.

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
act.send_message(remote_pid, Work_Item{...})
```

`spawn_remote` sends a request to the target node, which calls the registered spawn function and returns the new PID. The calling node creates a remote proxy in its local registry.

## Actor Lifecycle Broadcasting

When nodes are connected, actor lifecycle events are broadcast across the mesh automatically:

**On spawn:** Every node is notified when an actor is spawned on any connected node. The broadcast includes the PID, name, actor type, and parent PID. Remote nodes register a proxy in their local registry so they can route messages to the new actor.

**On termination:** When an actor terminates, all connected nodes receive a termination broadcast with the PID, name, and reason. Remote nodes clean up their proxy entries.

This means each node has a view of the actors across the mesh. You can `send_message` to any remote actor by PID without manually tracking which node it lives on. The registry already knows.

### Mesh Propagation

Lifecycle broadcasts propagate through the mesh via gossip. Each broadcast carries a TTL (default 3). When a node receives a broadcast, it registers the actor locally and forwards the message to its other peers with TTL decremented. This means nodes that aren't directly connected still learn about each other's actors through intermediate hops:

```
Node A spawns "worker-1"
  → broadcast to Node B (direct connection), TTL=3
  → Node B registers proxy, forwards to Node C (TTL=2)
  → Node C registers proxy, forwards to Node D (TTL=1)
  → Node D registers proxy, even though A and D are not directly connected
```

The same applies to termination. Proxy entries are cleaned up across the entire mesh, not just direct peers. Duplicate broadcasts are ignored (if the actor is already registered or already removed).

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

Subscription state is synced between nodes. Each node tracks remote subscriber counts per actor type.

## Failure Handling

- **Heartbeats**: Sent at `heartbeat_interval` (default 30s). Node marked dead after `heartbeat_timeout` (default 90s).
- **Reconnection**: Automatic with exponential backoff. `reconnect_initial_delay` (2s) then `reconnect_retry_delay` (3s) between attempts.
- **Cleanup**: Remote actor proxies are removed from the registry when a node disconnects. Local actors sending to dead remotes get `NODE_DISCONNECTED` errors.

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
send_message :: proc(to: PID, content: $T, priority: Message_Priority = .NORMAL) -> Send_Error // routes automatically
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
