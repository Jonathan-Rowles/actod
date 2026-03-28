# Actor Registry

The actor registry maps PIDs to actor pointers. It supports lookup by PID (O(1)) and by name (hash-based).

## PID Structure

PIDs are 64-bit identifiers encoding the node, actor type, generation, and index:

```
[node_id:16][actor_type:8][generation:16][index:24]
```

- **node_id** — 0 = reserved, 1 = local, 2+ = remote nodes
- **actor_type** — User-defined type tag (0 = untyped, 1-255)
- **generation** — Incremented on reuse to detect stale PIDs
- **index** — Position in the registry array

## Lookup

```odin
// By name
pid, ok := act.get_actor_pid("my_actor")

// Get name from PID
name := act.get_actor_name(pid)

// Check if local
is_local := act.is_local_pid(pid)

// Get node
node_id := act.get_node_id(pid)

// Get actor type
actor_type := act.get_pid_actor_type(pid)
```

## Capacity

The registry starts at a configurable size (default 256) and grows dynamically when full (if `allow_registry_growth` is enabled).

```odin
act.make_node_config(
    actor_registry_size   = 256,   // initial capacity (power-of-2)
    allow_registry_growth = true,  // double on overflow
)
```

---
[< Hot Reload](11_hot-reload.md) | [Test Harness >](13_test-harness.md)
