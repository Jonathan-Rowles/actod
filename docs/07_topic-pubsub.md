# Topic Pub/Sub

Topic-based pub/sub lets you attach a `Topic` directly to a domain struct. Actors subscribe to topics they care about and receive published messages automatically. Unlike type-based pub/sub (which is global per actor type), topics are scoped to the data they represent.

## Embedding Topics in Domain Structs

The most natural pattern is embedding a `Topic` as a field in the struct it relates to. Anyone with a reference to the struct can subscribe to or publish on its topic:

```odin
Symbol :: struct {
    base:      string,
    quote:     string,
    inst_type: Instrument_Type,
    book:      Order_Book,
    // ...
    topic:     act.Topic,    // actors subscribe to updates for this symbol
}
```

An actor interested in a specific symbol subscribes to its topic:

```odin
// Subscribe to symbol updates
sub, ok := act.subscribe_topic(&sym.topic)

// On update
act.publish(&sym.topic, TICK{})
```

## Basic Usage

Topics don't have to be embedded. A standalone topic works too:

```odin
import act "actod"

shutdown_topic: act.Topic

// Subscribe
sub, ok := act.subscribe_topic(&shutdown_topic)

// Publish
act.publish(&shutdown_topic, Shutdown_Warning{countdown = 30})

// Unsubscribe
act.unsubscribe_topic(sub)
```

## Listing Subscribers

`get_topic_subscribers` fills a buffer you supply with the topic's subscriber PIDs and returns how many it wrote. It never allocates. A buffer of `act.MAX_TOPIC_SUBSCRIBERS` holds every subscriber a topic can have; a shorter one gets the first `len(out)`. Use it to send to each subscriber yourself and see each send's result, since `publish` does not report one.

```odin
subscribers: [act.MAX_TOPIC_SUBSCRIBERS]act.PID
n := act.get_topic_subscribers(&sym.topic, subscribers[:])
for pid in subscribers[:n] {
    if err := act.send(pid, TICK{}); err != nil do log.errorf("tick to %v: %v", pid, err)
}
```

It lists the table `publish` sends to, read the way `publish` reads it: no lock, `count` loaded once, then each slot below it, empty slots skipped. Unlike `publish`, it includes the caller when the caller is subscribed. With nothing subscribing, leaving or terminating on the topic during the call, and no earlier overlap having damaged the table, the result is each subscriber once, in the order `publish` sends to them. When removals overlap each other or the call, a listed PID may already have left, including one whose `wait_for_pids` has returned, and a subscriber that stayed may be missed or listed twice; two removals that overlapped can leave the table holding a PID that left and missing one that stayed after both have returned. When a subscribe overlapped a removal earlier, the table itself can be short of the actors holding a subscription, and the call reports the table. On a single-worker sim node none of this arises.

## API

```odin
subscribe_topic :: proc(topic: ^Topic) -> (Topic_Subscription, bool)
unsubscribe_topic :: proc(sub: Topic_Subscription) -> bool
publish :: proc(topic: ^Topic, msg: $T)
get_topic_subscribers :: proc(topic: ^Topic, out: []PID) -> int
MAX_TOPIC_SUBSCRIBERS :: 64
```

## Compared to Type-Based Pub/Sub

| | Type-Based | Topic-Based |
|---|---|---|
| Scope | Global, per actor type | Scoped to a struct or variable |
| Capacity | 16384 subscribers | 64 subscribers |
| Setup | `register_actor_type` + `subscribe_type` | Embed `Topic` field + `subscribe_topic` |
| Use case | System-wide broadcasts by role | Per-entity channels (symbols, sessions, rooms) |

## Details

- Max 64 subscribers per topic
- Publish excludes the sender
- Topic lifetime is managed by the user: it lives as long as the struct it's embedded in
- **Local only**: topics do not work across nodes. Use type-based pub/sub for cross-node broadcasts. Cross-node topics are on the roadmap.

---
[< Pub/Sub](06_pubsub.md) | [Observer >](08_observer.md)
