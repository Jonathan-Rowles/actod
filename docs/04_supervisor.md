# Supervisor

Any actor with children is a supervisor. Supervisors monitor their children and apply restart strategies when children terminate.

## Configuration

```odin
cfg := act.make_actor_config(
    children             = act.make_children(spawn_worker1, spawn_worker2),
    supervision_strategy = .ONE_FOR_ONE,
    restart_policy       = .PERMANENT,
    max_restarts         = 3,
    restart_window       = 5 * time.Second,
)

pid, ok := act.spawn("supervisor", Supervisor_Data{}, supervisor_behaviour, cfg)
```

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

## Restart Limits

The supervisor tracks restarts within a sliding window. If `max_restarts` is exceeded within `restart_window`, the supervisor stops restarting and fires `on_max_restarts_exceeded`.

## Dynamic Children

```odin
// Add a child at runtime
new_pid, ok := act.add_child(supervisor_pid, spawn_new_worker)

// Add an existing actor as a child
act.add_child_existing(supervisor_pid, existing_pid, spawn_func)

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

    on_child_terminated = proc(d: ^Data, child_pid: act.PID, reason: act.Termination_Reason, will_restart: bool) {
        // child stopped — will_restart indicates if supervisor will respawn
    },

    on_child_restarted = proc(d: ^Data, old_pid: act.PID, new_pid: act.PID, restart_count: int) {
        // child was restarted — old PID is invalid, use new_pid
    },

    on_max_restarts_exceeded = proc(d: ^Data, child_pid: act.PID) {
        // restart limit hit — child will not be restarted
    },
}
```

## Spawn Functions

Children are defined as spawn functions matching the `SPAWN` type:

```odin
SPAWN :: proc(name: string, parent_pid: PID) -> (PID, bool)

spawn_worker :: proc(name: string, parent: act.PID) -> (act.PID, bool) {
    return act.spawn("worker", Worker{}, worker_behaviour)
}
```

The supervisor calls these functions to create (and recreate) children.

## Cross-Node Supervision

Supervision works across nodes. A supervisor on Node A can have children on Node B. When a remote child terminates, the termination broadcast reaches the supervisor and the same restart strategies apply — the supervisor calls the spawn function to recreate the child on the appropriate node. See [networking](10_network.md) for how actor lifecycle events are broadcast across the mesh.

---
[< Message Registration](03_message-registration.md) | [Timer >](05_timer.md)
