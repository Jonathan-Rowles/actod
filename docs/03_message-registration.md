# Message Registration

Messages are sent between actors. Simple structs (plain data, no pointers) work without registration. Structs containing strings or byte slices are deep-copied.

Any message type can be registered at runtime, but it is strongly recommended to register upfront via `@(init)` procs before `NODE_INIT`.

```odin
Chat_Message :: struct {
    user: string,
    text: string,
}

Book :: struct {
    ask: f32,
    buy: f32,
}

@(init)
register_messages :: proc "contextless" () {
    act.register_message_type(Chat_Message)
    act.register_message_type(Book)
}
```


The `@(init)` attribute runs the proc at program startup, before `NODE_INIT`.


## Inline vs Allocated

Messages 32 bytes or smaller are stored **inline** in the mailbox entry — no allocation, no pool access. This is the fast path.

Messages larger than 32 bytes are allocated from the actor's **message pool**.

```
<= 32 bytes:  inline (zero-alloc, fastest)
 > 32 bytes:  pool-allocated, cache-line aligned
```

## Variable-Length Data

For registered types, the runtime introspects struct fields to find strings and byte slices. On send, the variable data is deep-copied alongside the fixed struct. The receiver gets a fully owned copy — no shared pointers.

## Cross-Node Messages

The wire protocol identifies message types by a hash of their package-qualified name (e.g. `shared.Chat_Message`). Both the sending and receiving node must have the same type registered — same name, same package, same struct layout. This is a deliberate constraint: message compatibility is a compile-time concern, not a runtime negotiation. There is no schema evolution or version handshake — if the types don't match, delivery fails with a warning log.

In practice, shared message types should live in a common package that all nodes import:

```odin
// shared/messages.odin
package shared

Chat_Message :: struct {
    user: string,
    text: string,
}

Book :: struct {
    ask: f32,
    buy: f32,
}

@(init)
register_messages :: proc "contextless" () {
    act.register_message_type(Chat_Message)
    act.register_message_type(Book)
}
```

## API

```odin
register_message_type :: proc "contextless" ($T: typeid)
```

Maps and dynamic arrays are intentionally excluded from messages. This keeps send times consistent and predictable — no hidden allocation costs proportional to collection size.

---
[< Actor](02_actor.md) | [Supervisor >](04_supervisor.md)
