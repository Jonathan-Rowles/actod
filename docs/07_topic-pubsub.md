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

## API

```odin
subscribe_topic :: proc(topic: ^Topic) -> (Topic_Subscription, bool)
unsubscribe_topic :: proc(sub: Topic_Subscription) -> bool
publish :: proc(topic: ^Topic, msg: $T)
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
- Topic lifetime is managed by the user — it lives as long as the struct it's embedded in
- **Local only** — topics do not work across nodes. Use type-based pub/sub for cross-node broadcasts. Cross-node topics are on the roadmap.

---
[< Pub/Sub](06_pubsub.md) | [Observer >](08_observer.md)
