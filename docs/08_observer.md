# Observer

The observer collects per-actor stats (message counts, mailbox sizes, uptime) and broadcasts snapshots to subscribers.

## Enabling

```odin
act.NODE_INIT("myapp", act.make_node_config(
    enable_observer   = true,
    observer_interval = 5 * time.Second,  // auto-collect every 5s, 0 = manual
))
```

Or start/stop manually:

```odin
act.start_observer(collection_interval = 5 * time.Second)
act.stop_observer()
```

## Collecting Stats

```odin
// Manual trigger
act.trigger_stats_collection()

// Request stats for one actor
act.request_actor_stats(target_pid, requester_pid)

// Request stats for all actors
act.request_all_stats(requester_pid)

// Change collection interval at runtime
act.set_stats_collection_interval(10 * time.Second)
```

## Subscribing to Snapshots

```odin
sub, ok := act.subscribe_to_stats()
defer act.unsubscribe_from_stats(sub)

// Actor receives Stats_Snapshot messages
handle_message = proc(d: ^Data, from: act.PID, msg: any) {
    switch m in msg {
    case act.Stats_Snapshot:
        for i in 0 ..< m.actor_count {
            entry := m.actors[i]
            // entry.pid, entry.name, entry.messages_received, ...
        }
    }
}
```

## Stats Available

Per actor:

- `messages_received`, `messages_sent`
- `received_from: map[PID]u64` — per-sender breakdown
- `sent_to: map[PID]u64` — per-recipient breakdown
- `mailbox_sizes: [3]int` — per priority level
- `system_mailbox_size`
- `state`, `start_time`, `uptime`
- `max_mailbox_size`
- Termination info (if terminated)

## API

```odin
start_observer :: proc(collection_interval: time.Duration = 0) -> (PID, bool)
stop_observer :: proc()
trigger_stats_collection :: proc() -> bool
request_actor_stats :: proc(actor_pid: PID, requester: PID) -> bool
request_all_stats :: proc(requester: PID) -> bool
set_stats_collection_interval :: proc(interval: time.Duration) -> bool
clear_terminated_stats :: proc() -> bool
subscribe_to_stats :: proc() -> (Subscription, bool)
unsubscribe_from_stats :: proc(sub: Subscription) -> bool
```

---
[< Topic Pub/Sub](07_topic-pubsub.md) | [Logging >](09_logging.md)
