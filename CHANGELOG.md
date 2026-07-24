# Changelog

## [Unreleased]

Wire protocol v3 to v4 (breaking): the priority flag bits are gone from the
wire format.

### Removed
- Priority mailboxes. `Message_Priority` and the `priority` argument to
  `send_message` are gone; each actor now has a single 512-slot mailbox plus
  the system mailbox. Nothing ever sent at non-default priority, and the
  system mailbox already covers urgent control traffic.

### Fixed
- Per-sender FIFO ordering. The overflow path could park a message in a
  different priority ring and the drain serviced rings in priority order, so
  one send during one full-ring burst was silently delivered early. With a
  single mailbox the reorder is unrepresentable; a mailbox that stays full
  returns `RECEIVER_BACKLOGGED` after the retry budget instead of succeeding
  out of order.
- A same-worker send that found the target's local buffer full could spill
  into the MPSC mailbox, letting later local sends overtake it. Overflowing
  local sends now yield and retry the local buffer, then return
  `RECEIVER_BACKLOGGED`; they never switch queues.
- Coroutine senders no longer reset their retry budget on a full mailbox, so
  a stuck receiver can no longer block its senders forever.

### Changed
- Default mailbox capacity is 512 slots (was 3 rings of 128).
- `Actor_Stats.mailbox_sizes: [3]int` is now `mailbox_size: int`.

### Performance
- Single-producer paths are faster: 1:1 throughput +9%, same-worker +7-14%,
  16:8 mesh +54% (fewer rings to check per drain and resume).
- Many-producers-to-one-consumer small-message throughput roughly halved
  (4:1 32B 18.8M to 10.0M msgs/s, 32:1 and 64:1 to ~40% of old). The old
  overflow hop striped flooding producers across three `write_index` cache
  lines; a single ring serializes their CAS. If a workload ever needs hot
  fan-in, the intended fix is sender-hash mailbox sharding, which preserves
  per-sender FIFO because a sender always maps to the same shard. Priority
  rings are not coming back.

## [0.3.0] - 2026-07-23

Wire protocol v2 to v3 (breaking). Every node in a mesh must run the same
version; a v3 node refuses an older node's handshake.

### Added
- Node-to-node encryption. Noise NNpsk0 handshake, PSK derived from
  `auth_password` (Argon2id). Enable with `enable_encryption`.
- UDP lane for fire-and-forget sends: `send_unreliable`, `udp_port`.
  AEAD-authenticated (ChaCha20-Poly1305) with a replay window.
- Cross-node supervision. A remote child restarts on its origin node per the
  supervision strategy, `on_child_terminated` fires for it, and
  `terminate_actor` on a remote PID actually terminates the remote actor.
- `register_node(..., connect := false)`. `connect = true` dials the peer now;
  otherwise links form lazily on first send. Node and actor discovery then
  propagate transitively across the graph.
- Compile-time rejection of message types too large for a pool page, naming the
  offending type.

### Changed
- Transport rewrite: NODE-owned connection rings that buffer while
  disconnected. The per-connection message pool is gone.
- Wire v3 carries a SYSTEM message class (so `Actor_Stopped` / `Terminate`
  reach the system mailbox across nodes); remote-spawn PIDs and parents are
  re-packed into the caller's node namespace.
- Off-actor `self_terminate`, `self_rename`, `spawn_child`, `subscribe_type`
  and `subscribe_topic` now fail loudly instead of silently doing nothing.
- A full system mailbox returns `.RECEIVER_BACKLOGGED` instead of panicking; a
  child's termination notice retries under a one second deadline.
- User-facing errors report the caller's source location.

### Fixed
- Use-after-free in the registry lookup path under termination churn, and a
  lost wakeup on the ready-queue handoff.
- Per-child message-pool leak that wedged a supervisor once its pool hit the
  page cap.
- SIGSEGV enqueuing a var-field system message on a full node mailbox.
- Remote spawn: PID returned in the wrong node namespace (sends failed
  `ACTOR_NOT_FOUND`), untranslated parent PID, cross-thread read of the
  response error string, a stale-response race, and a pool slot lost on
  allocation failure.
- Registry snapshots stamped a zero TTL, blocking transitive discovery.
- Off-actor `get_self_pid()` returned an unroutable non-zero sentinel.
- Hot reload: generated-shim config defaults diverged from runtime defaults; a
  backlogged actor was evicted from future reloads.

### Known limitations
- Every node in a mesh must run the same wire version; there is no negotiation.
- Any authenticated peer is fully trusted: with the shared password it can
  message or terminate any actor by handle. No per-actor or per-node
  authorization.
- The default network config is permissive (empty `auth_password` disables
  authentication and binds all interfaces). Set a password for anything beyond
  a trusted LAN.
- Topics are local only (type-based subscriptions are cross-node, topic-based
  are not).
- Cross-node config changes are not supported.
- Maps and dynamic arrays are excluded from message payloads by design.

[0.3.0]: https://github.com/Jonathan-Rowles/actod/releases/tag/v0.3.0

## [0.2.1] - 2026-06-22

### Fixed
- Top-level `[]u8` message fields were silently dropped by every network
  serializer (`build_wire_format_into_buffer`, `wire_format_exact_size`, and
  `build_and_send_network_command`); the receiver then read past the payload,
  delivering corrupt slice data across nodes. Byte slices now serialize
  everywhere strings do.
- The network receive path bounds-checks variable-width data. A truncated or
  malformed payload, including one smaller than the fixed struct, is rejected
  with `NETWORK_ERROR` instead of reading out of bounds.
- `build_and_send_network_command` now also serializes union-variant variable
  data (previously top-level strings only).

### Changed
- Strings and byte slices are tracked internally as a single
  declaration-ordered variable-width field list (`Var_Field_Info`, replacing
  the separate `String_Field_Info` / `Byte_Slice_Field_Info` and the
  `Has_Strings` / `Has_Byte_Slices` flags). They share a memory layout and are
  now handled by one code path, so a message can freely mix `string` and
  `[]u8` fields. The wire payload for such mixed messages is ordered by field
  declaration; messages mixing the two never serialized correctly before, so
  nothing depends on the old order. As always, all nodes in a mesh must run the
  same actod version.

[0.2.1]: https://github.com/Jonathan-Rowles/actod/releases/tag/v0.2.1

## [0.2.0] - 2026-06-02

### Added
- `@(require_results)` on value-returning lookups and spawns (`spawn`,
  `spawn_child`, `spawn_by_name`, `spawn_remote`, `add_child`,
  `add_child_existing`, `get_actor_pid`, `get_node_by_name`, `get_node_info`,
  `get_actor_type_name`, `register_actor_type`, `register_node`, `set_timer`,
  `subscribe_type`, `subscribe_topic`, `subscribe_to_stats`). Ignoring their
  result is now a compile error.

### Changed
- `send_message` takes an optional `priority: Message_Priority = .NORMAL`
  argument that selects the destination mailbox. Existing two-argument calls
  are unaffected. Remote sends honor it via the existing wire priority flags.
- `send_message_to_parent` and `send_message_to_children` return `Send_Error`
  instead of `bool`, consistent with the rest of the send API.
- `NODE_INIT` and `SHUTDOWN_NODE` renamed to `node_init` and `shutdown_node`.
- Public type alias `SPIN_STRATEGY` renamed to `Spin_Strategy`.

### Removed
- `send_message_high`, `send_message_low`, `set_send_priority`, and
  `reset_send_priority`. Pass `priority` to `send_message` instead, e.g.
  `send_message(pid, msg, .HIGH)`. This drops the stateful per-actor send
  priority that could leak into `broadcast`, `publish`, and `send_self`.

[0.2.0]: https://github.com/Jonathan-Rowles/actod/releases/tag/v0.2.0

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
- Child registration consolidated into `spawn`: eliminates a race
  between spawn return and the child appearing in the parent's
  children list (3b6db9e).

[0.1.1]: https://github.com/Jonathan-Rowles/actod/releases/tag/v0.1.1

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

[0.1.0]: https://github.com/Jonathan-Rowles/actod/releases/tag/v0.1.0
