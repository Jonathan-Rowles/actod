# Getting Started

A complete example: two actors playing ping-pong with increasingly absurd jokes. See [getting_start.odin](getting_start.odin) for the full runnable source.

## Running

```bash
cd docs
odin run . -ignore-unknown-attributes
```

## What The Example Shows

- **Two actors communicating**: Comedian sends `Tell_Joke`, Audience replies with `Heckle`
- **Message registration**: `Tell_Joke` and `Heckle` contain strings, so they're registered with `@(init)`
- **Per-actor logging**: Comedian uses colored terminal output via `console_opts`, Audience uses default logging — each actor has its own log config
- **Supervision**: Both actors are children of the node — spawned in order via `make_children`
- **Actor lookup**: Comedian finds Audience by name with `get_actor_pid`
- **Self-termination**: Comedian calls `act.self_terminate()` when out of jokes
- **Spawn functions**: Children are defined as `SPAWN` procs so the supervisor can recreate them

## Next Steps

- [Node](01_node.md) — system lifecycle, design philosophy, and memory model
- [Actor](02_actor.md) — full actor API
- [Message Registration](03_message-registration.md) — when and why to register types
- [Supervisor](04_supervisor.md) — restart strategies and child management
- [Test Harness](13_test-harness.md) — unit and simulation testing

---
[Node >](01_node.md)
