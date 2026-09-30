# Supervisor

Any actor with children is a supervisor. Supervisors monitor their children and apply restart strategies when children terminate.

## Configuration

```odin
cfg := act.make_actor_config(
    children             = act.make_children(spawn_worker1, spawn_worker2),
    supervision_strategy = .ONE_FOR_ONE,
    max_restarts         = 3,
    restart_window       = 5 * time.Second,
)

pid, ok := act.spawn("supervisor", Supervisor_Data{}, supervisor_behaviour, cfg)
```

The strategy, `max_restarts` and `restart_window` are the supervisor's. Whether a child is restarted at all is the child's: see [Restart Policies](#restart-policies).

## Strategies

```odin
Supervision_Strategy :: enum {
    ONE_FOR_ONE,   // only restart the failed child
    ONE_FOR_ALL,   // restart all children if one fails
    REST_FOR_ONE,  // restart failed child + all started after it
}
```

## Restart Policies

```odin
Restart_Policy :: enum {
    PERMANENT,  // always restart on any termination
    TRANSIENT,  // restart only on abnormal termination
    TEMPORARY,  // never restart
}
```

The policy belongs to the child, OTP style. When a child terminates, its supervisor reads the `restart_policy` from the config the child was spawned with, so one supervisor can hold PERMANENT, TRANSIENT and TEMPORARY children side by side. A supervisor's own `restart_policy` says only how its own supervisor treats it; it never applies to its children.

```odin
spawn_worker :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
    return act.spawn(
        "worker",
        Worker{},
        worker_behaviour,
        act.make_actor_config(restart_policy = .TRANSIENT),
        parent_pid = parent,
    )
}
```

A child that sets no policy of its own gets the node's `actor_config` policy, `.PERMANENT` unless the node sets otherwise: `spawn` and `spawn_child` default their config to the node's `actor_config`, and `make_actor_config` defaults `restart_policy` to the node's, each read when it is called (so a `make_actor_config` called before `node_init` gets `.PERMANENT`). Inside a hot-reloaded module that does not hold. There `spawn` and `spawn_child` default to an empty config, which `spawn` rejects with a panic, so a child has to be given a `make_actor_config(...)`, and that module's `make_actor_config` defaults `restart_policy` to `.PERMANENT` whatever the node sets. A child spawned from a hot-reloaded module that names no policy is therefore `.PERMANENT`.

A child ending with `.SHUTDOWN` is never restarted, whatever its policy. A child whose policy says not to restart it is removed from the supervisor's children, and `on_child_terminated` fires with `will_restart = false`.

### Directly spawned children

A child spawned with `spawn_child`, or with `spawn` and a `parent_pid`, rather than declared in `children` or added with `add_child`, has no spawn function the supervisor could restart it from. Spawn such children `.TEMPORARY`: a short-lived worker that ends with `terminate()` is then removed from the supervisor when it ends, with no restart attempted. Given a policy that asks for a restart there is nothing to restart it from. Under ONE_FOR_ONE the supervisor logs "Invalid child index" and the dead pid stays in its children. ONE_FOR_ALL and REST_FOR_ONE still stop the siblings they cover and restart those that have a spawn function, while the dying child and any directly spawned sibling they stopped stay in the children as dead pids, with no error logged.

Known defect: when a supervisor has a directly spawned child and then gains a child through `add_child`, removing the direct child deletes that sibling's spawn function, and the sibling is not restarted afterwards. While both are present, restarting the direct child runs the sibling's spawn function instead.

## Restart Limits

The supervisor tracks restarts within a sliding window. If `max_restarts` is exceeded within `restart_window`, the supervisor stops restarting and fires `on_max_restarts_exceeded`. The limit and window are the supervisor's, counted per child.

## Dynamic Children

```odin
// Add a child at runtime
new_pid, ok := act.add_child(supervisor_pid, spawn_new_worker)

// Add an existing actor as a child
pid, ok := act.add_child_existing(supervisor_pid, existing_pid, spawn_func)

// Remove a child
act.remove_child(supervisor_pid, child_pid)

// List children
children := act.get_children(supervisor_pid)
```

## Callbacks

```odin
supervisor_behaviour := act.Actor_Behaviour(Data){
    handle_message = ...,

    on_child_started = proc(d: ^Data, child_pid: act.PID) {
        // child spawned or restarted
    },

    on_child_terminated = proc(d: ^Data, child_pid: act.PID, child_name: string, reason: act.Termination_Reason, will_restart: bool) {
        // child stopped, will_restart indicates if supervisor will respawn
        // child_name is borrowed for this call only, copy it if you keep it
    },

    on_child_restarted = proc(d: ^Data, old_pid: act.PID, new_pid: act.PID, restart_count: int) {
        // child was restarted, old PID is invalid, use new_pid
    },

    on_max_restarts_exceeded = proc(d: ^Data, child_pid: act.PID, child_name: string) {
        // restart limit hit, child will not be restarted
    },
}
```

## Spawn Functions

Children are defined as spawn functions matching the `SPAWN` type:

```odin
SPAWN :: proc(name: string, parent_pid: PID) -> (PID, bool)

spawn_worker :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
    return act.spawn("worker", Worker{}, worker_behaviour, parent_pid = parent)
}
```

The supervisor calls these functions to create (and recreate) children. The config a spawn function passes, its `restart_policy` included, is the child's.

## Cross-Node Supervision

Supervision works across nodes. A supervisor on Node A can have children on Node B. When a remote child terminates, its node sends an `Actor_Stopped` message directly to the supervisor, and the same restart strategies apply. The mesh-wide lifecycle broadcast of the termination is separate and plays no part in supervision. The remote child's own `restart_policy` travels on that `Actor_Stopped`, so the supervisor applies the policy the remote child was spawned with on its own node. The supervisor calls the spawn function to recreate the child on the appropriate node. See [networking](10_network.md) for how actor lifecycle events are broadcast across the mesh.

---
[< Message Registration](03_message-registration.md) | [Timer >](05_timer.md)
