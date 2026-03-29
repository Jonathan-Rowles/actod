# Hot Reload

Hot reload lets you update actor behaviour at runtime without restarting the node. Only the **code** changes — the actor's **state is preserved**. The runtime swaps function pointers on live actors while their data stays untouched in memory.

## What Gets Reloaded

Hot reload only affects code inside `Actor_Behaviour` — the function pointers:

- `handle_message`
- `init`
- `terminate`
- `on_child_started`, `on_child_terminated`, `on_child_restarted`, `on_max_restarts_exceeded`

**What does NOT change:**

- `actor.data` — the actor's typed state struct. It stays exactly as it was. If you add a new field to the struct, existing actors still have the old layout in memory.
- Mailbox contents — any queued messages are unaffected.
- PID, name, parent, children — the actor's identity and supervision tree are unchanged.
- Config — the actor keeps its original `Actor_Config`.

This means hot reload is safe for logic changes (fixing a bug in `handle_message`, adding a new message case) but not for struct layout changes. If you change the size or layout of the actor's data struct, the existing in-memory state won't match and behaviour is undefined.

## Enabling

```odin
act.NODE_INIT("myapp", act.make_node_config(
    hot_reload_dev        = true,
    hot_reload_watch_path = "",   // empty = auto-discover actors directory
))
```

This spawns an internal `Hot_Reload_Actor` that watches for file changes.

## How It Works

1. File watcher detects source changes in the actors directory
2. Runtime recompile's and reloads the shared library
3. `Reload_Behaviour` message broadcast to affected actors
4. Each actor's function pointers are swapped to the new versions
5. The `init` callback runs again on the existing state

## Named Procs Required

Behaviour procs **must be named** for hot reload to work. The runtime resolves exported symbols by name — anonymous proc literals have no name to export.

```odin
// Works — named procs
chat_handle_message :: proc(d: ^Chat_Data, from: act.PID, msg: any) { ... }

chat_behaviour := act.Actor_Behaviour(Chat_Data) {
    handle_message = chat_handle_message,
}

// Does NOT work — anonymous proc
chat_behaviour := act.Actor_Behaviour(Chat_Data) {
    handle_message = proc(d: ^Chat_Data, from: act.PID, msg: any) { ... },
}
```

## Safe Changes

These are safe to hot reload:

```odin
// Before
chat_handle_message :: proc(d: ^Chat_Data, from: act.PID, msg: any) {
    switch m in msg {
    case Chat_Message:
        log.infof("got: %s", m.text)
    }
}

// After — new logic, same struct
chat_handle_message :: proc(d: ^Chat_Data, from: act.PID, msg: any) {
    switch m in msg {
    case Chat_Message:
        d.message_count += 1                          // use existing field
        log.infof("[%d] got: %s", d.message_count, m.text)
    case Ping:                                         // handle new message type
        act.send_message(from, Pong{})
    }
}
```

## Try It

There's a working example in `docs/hot_reload_example/`. Run it with:

```sh
cd docs/hot_reload_example
odin run .
```

While it's running, edit the `// <- change this` lines in the actor files under `hot_reload_actors/` and save. The runtime will detect the change, recompile, and swap the behaviour — you'll see the new log messages appear without restarting.

## Unsafe Changes

These will cause problems:

```odin
// Adding a field to the data struct — existing actors have the old layout
Chat_Data :: struct {
    message_count: int,
    new_field: string,     // existing actors don't have this allocated
}
```

The runtime validates state size and will reject reloads where the struct size changed.

## Attributes

Mark procedures with `@(hot = ...)` to control code generation:

```odin
@(hot = "skip")       // exclude from hot reload (unsafe functions)
@(hot = "noop")       // function becomes no-op during reload
@(hot = "compose")    // generate wrapper with default args
```

## Symbol Resolution

The hot reload system resolves exported symbols by name:

- `handle_message` — required
- `init` — optional
- `terminate` — optional
- `on_child_started`, `on_child_terminated`, etc. — optional

If `handle_message` can't be resolved, the reload fails and the actor keeps its current behaviour.

---
[< Networking](10_network.md) | [Actor Registry >](12_actor-registry.md)
