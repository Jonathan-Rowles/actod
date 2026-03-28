# Networking

Actod supports distributed actor systems where multiple nodes communicate over TCP. Actors on different nodes interact transparently — `send_message` routes based on the PID's embedded node ID.

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
// Node A — listen and register spawn functions
act.NODE_INIT("nodeA", opts = act.make_node_config(
    network = act.make_network_config(port = 5000, auth_password = "secret"),
))
act.register_spawn_func("worker", spawn_worker)

// Node B — connect to Node A
act.NODE_INIT("nodeB", opts = act.make_node_config(
    network = act.make_network_config(port = 5001, auth_password = "secret"),
))
act.register_node("nodeA", net.Endpoint{address = ..., port = 5000}, .TCP)
```

## Configuration

```odin
act.make_network_config(
    port                    = 0,             // 0 = networking disabled
    auth_password           = "",            // empty = no auth
    heartbeat_interval      = 30 * time.Second,
    heartbeat_timeout       = 90 * time.Second,
    reconnect_initial_delay = 2 * time.Second,
    reconnect_retry_delay   = 3 * time.Second,
    connection_ring         = act.make_connection_ring_config(
        send_slot_count    = 16,             // ring buffer slots (power-of-2)
        send_slot_size     = 64 * 1024,      // 64KB per slot
        recv_buffer_size   = 512 * 1024,     // 512KB receive buffer
        tcp_nodelay        = true,           // disable Nagle
        max_pool_rings     = 8,              // contention scaling
    ),
)
```

## Sending to Remote Actors

```odin
// Transparent — same API as local
act.send_message(remote_pid, MyMessage{data = 42})

// Or by name
act.send_message_name("worker@nodeA", MyMessage{data = 42})
```

The PID encodes the node ID in the upper 16 bits. `send_message` checks `is_local_pid(to)` and routes to the connection ring automatically.

**Important:** Remote message types must be identical across nodes — same struct, same package, same registration. See [Message Registration — Cross-Node Messages](03_message-registration.md#cross-node-messages).

## Remote Spawning

```odin
// From Node B, spawn an actor on Node A
remote_pid, ok := act.spawn_remote(
    "worker",       // registered spawn function name
    "my_worker",    // actor name
    "nodeA",        // target node
)

// Send to it — same API
act.send_message(remote_pid, Work_Item{...})
```

`spawn_remote` sends a request to the target node, which calls the registered spawn function and returns the new PID. The calling node creates a remote proxy in its local registry.

## Actor Lifecycle Broadcasting

When nodes are connected, actor lifecycle events are broadcast across the mesh automatically:

**On spawn:** Every node is notified when an actor is spawned on any connected node. The broadcast includes the PID, name, actor type, and parent PID. Remote nodes register a proxy in their local registry so they can route messages to the new actor.

**On termination:** When an actor terminates, all connected nodes receive a termination broadcast with the PID, name, and reason. Remote nodes clean up their proxy entries.

This means each node has a view of the actors across the mesh. You can `send_message` to any remote actor by PID without manually tracking which node it lives on — the registry already knows.

### Mesh Propagation

Lifecycle broadcasts propagate through the mesh via gossip. Each broadcast carries a TTL (default 3). When a node receives a broadcast, it registers the actor locally and forwards the message to its other peers with TTL decremented. This means nodes that aren't directly connected still learn about each other's actors through intermediate hops:

```
Node A spawns "worker-1"
  → broadcast to Node B (direct connection), TTL=3
  → Node B registers proxy, forwards to Node C (TTL=2)
  → Node C registers proxy, forwards to Node D (TTL=1)
  → Node D registers proxy — even though A and D are not directly connected
```

The same applies to termination — proxy entries are cleaned up across the entire mesh, not just direct peers. Duplicate broadcasts are ignored (if the actor is already registered or already removed).

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

// Node B broadcasts — reaches Node A subscribers
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
register_node :: proc(name: string, address: net.Endpoint, transport: Transport_Strategy) -> (Node_ID, bool)
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
send_message :: proc(to: PID, content: $T) -> Send_Error        // routes automatically
send_message_name :: proc(to: string, content: $T) -> Send_Error // "actor@node" format
send_to :: proc(actor_name: string, node_name: string, content: $T) -> Send_Error

// Node identity
get_local_node_name :: proc() -> string
get_local_node_pid :: proc() -> PID
is_local_pid :: proc(pid: PID) -> bool
get_node_id :: proc(pid: PID) -> Node_ID

// Connection ring config builder
make_connection_ring_config :: proc(
    send_slot_count: u32 = 16,
    send_slot_size: u32 = 65536,
    recv_buffer_size: u32 = 524288,
    tcp_nodelay: bool = true,
    max_pool_rings: u32 = 8,
    scale_up_contention_threshold: u32 = 100,
    scale_down_idle_seconds: u32 = 10,
) -> Connection_Ring_Config
```

---
[< Logging](09_logging.md) | [Hot Reload >](11_hot-reload.md)
