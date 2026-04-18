# Changelog

## [0.1.1] - 2026-04-18

### Changed
- Internal send-path refactor: generic `send_*` procs are now thin shells
  over non-generic impls, cutting per-message-type monomorphization.
  Release binary .text sections shrink ~52% on representative benchmarks.
  No public API changes; behavior and performance (32B ping-pong p50) unchanged.

### Fixed
- `Connection_Actor`'s first_message allocator is now pinned to the
  connection's arena instead of the caller's context (39dcd93).
- `NODE`'s terminate handler now runs on shutdown (ce5178e).
- Child registration consolidated into `spawn` — eliminates a race
  between spawn return and the child appearing in the parent's
  children list (3b6db9e).

[0.1.1]: https://github.com/jonathan-rowles/actod/releases/tag/v0.1.1

## [0.1.0] - 2026-04-17

Initial public release.

### Added

- **Actor runtime.** Coroutine-based actors scheduled on a fixed worker pool. Per-actor arena state, receiver-owned message copy via lock-free MPSC mailboxes.
- **Supervision.** One-for-one, one-for-all, and rest-for-one strategies; configurable restart limits and windows; lifecycle callbacks.
- **Distributed actors.** Same `send_message` API for local and remote sends. PIDs encode node ID; cluster gossip maintains proxy registries.
- **Priority mailboxes.** Three per-actor priorities (high / normal / low) plus a system mailbox processed first.
- **Pub/sub.** Type-based (global) and topic-based (per-struct) subscriptions. Type-based subscriptions are cross-node.
- **Timers.** One-shot and repeating, managed by a system actor. Virtual time in tests.
- **Hot reload.** Swap behaviour callbacks on live actors with state preserved. Collection-aware.
- **Observer.** Per-actor stats (message counts, mailbox depths, uptime, sender/recipient breakdowns) on a configurable interval.
- **Test harness.** Synchronous unit harness for single actors and a simulation framework for multi-actor scenarios with deterministic delivery, fault injection, and virtual time.
- **Public `act` interface.** Stable surface in `act.odin` at the repo root, generated from `src/api/act.odin`.

### Known limitations

- No TLS for node-to-node communication.
- Topics are local only (no cross-node topics).
- TCP only; no UDP transport.
- Cross-node config changes not supported.
- Maps and dynamic arrays are intentionally excluded from message payloads (predictable per-send cost).

### Tested platforms

- Linux x86_64
- macOS Apple Silicon
- Windows x86_64

[0.1.0]: https://github.com/jonathan-rowles/actod/releases/tag/v0.1.0
