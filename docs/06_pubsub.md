# Pub/Sub (Type-Based)

Type-based pub/sub lets actors subscribe to messages broadcast to a specific actor type. Any actor can broadcast, and all subscribers of that type receive the message.

## Actor Types

Assign a type when defining a behaviour:

```odin
LOGGER_TYPE, _ := act.register_actor_type("logger")

logger_behaviour := act.Actor_Behaviour(Logger_Data){
    actor_type = LOGGER_TYPE,
    handle_message = ...,
}
```

Actor types are 8-bit IDs (1-255). Type 0 means untyped.

## Subscribing

```odin
sub, ok := act.subscribe_type(LOGGER_TYPE)
// ...
act.unsubscribe(sub)
```

## Broadcasting

```odin
act.broadcast(Log_Entry{level = .Info, text = "hello"})
```

Broadcast sends to all subscribers of the calling actor's type. The sender is excluded.

## API

```odin
register_actor_type :: proc(name: string) -> (Actor_Type, bool)
get_actor_type_name :: proc(actor_type: Actor_Type) -> (string, bool)

subscribe_type :: proc(actor_type: Actor_Type) -> (Subscription, bool)
unsubscribe :: proc(sub: Subscription) -> bool
broadcast :: proc(msg: $T)
get_subscriber_count :: proc(actor_type: Actor_Type) -> u32
```

## Details

- Max 16384 subscribers per type
- Subscriptions are cleaned up on actor termination
- Cross-node: remote nodes track subscriptions and receive broadcasts over the network

---
[< Timer](05_timer.md) | [Topic Pub/Sub >](07_topic-pubsub.md)
