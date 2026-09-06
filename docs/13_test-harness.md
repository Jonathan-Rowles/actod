# Test Harness

Actod provides three testing tools: a **unit test harness** for isolated single-actor testing, a **simulation framework** for multi-actor scenarios with fault injection, and **deterministic simulation testing (DST)** that runs the real runtime, including the node-to-node mesh, under a seeded single-threaded scheduler.

The first two test *your actor logic* against a model of the runtime. DST tests *the runtime itself* (and your actors on top of it): real mailboxes, real supervision, real wire encode/decode, real handshakes, on a virtual clock and a virtual transport.

## Running Tests

```bash
odin test .
```

Neither harness starts a real node or worker pool, and both are fully deterministic: no threads, no timing. The unit harness delivers `th.send` straight into `handle_message` and captures what the actor sends out. The sim queues messages instead and delivers one per `sim.step`.

## Unit Testing

Test a single actor in isolation. Messages are captured, not delivered.

```odin
import th "test_harness"

@(test)
test_counter :: proc(t: ^testing.T) {
    h := th.create(Counter{}, counter_behaviour)
    defer th.destroy(&h)

    th.init(&h)

    // Send a message
    th.send(&h, "increment")

    // Check state
    state := th.get_state(&h)
    testing.expect_value(t, state.count, 1)

    // Check what the actor sent
    reply := th.expect_sent(&h, t, int)
    testing.expect_value(t, reply, 1)
}
```

### Unit Test API

```odin
// Lifecycle
create :: proc(data: $T, behaviour: Actor_Behaviour(T)) -> Test_Harness(T)
destroy :: proc(h: ^Test_Harness($T))
init :: proc(h: ^Test_Harness($T))
terminate :: proc(h: ^Test_Harness($T))
get_state :: proc(h: ^Test_Harness($T)) -> ^T

// Sending
send :: proc(h: ^Test_Harness($T), msg: $M, from: PID = EXTERNAL_PID)

// Setup
register_pid :: proc(h: ^Test_Harness($T), name: string, pid: PID)
kill_pid :: proc(h: ^Test_Harness($T), pid: PID)      // make a registered PID dead, so sends to it fail
add_child :: proc(h: ^Test_Harness($T), pid: PID)
set_parent :: proc(h: ^Test_Harness($T), pid: PID)
EXTERNAL_PID :: PID(999)                              // the default `from` for th.send

// Intercept, for non-actor code that calls actod APIs (a WS callback, a timer thread)
install :: proc(h: ^Test_Harness($T))
uninstall :: proc(h: ^Test_Harness($T))

// Time
set_virtual_now :: proc(h: ^Test_Harness($T), t: time.Time)
advance_time :: proc(h: ^Test_Harness($T), d: time.Duration)

// Supervision simulation
simulate_child_terminated :: proc(h: ^Test_Harness($T), child_pid: PID, child_name: string, reason: Termination_Reason, will_restart: bool = false)
simulate_child_started :: proc(h: ^Test_Harness($T), child_pid: PID)
simulate_child_restarted :: proc(h: ^Test_Harness($T), old_pid: PID, new_pid: PID, restart_count: int)
simulate_max_restarts :: proc(h: ^Test_Harness($T), child_pid: PID, child_name: string)

// Timers
expect_timer :: proc(h: ^Test_Harness($T), t: ^testing.T) -> Captured_Timer
fire_timer :: proc(h: ^Test_Harness($T), id: u32)

// Assertions
expect_sent :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid) -> M
expect_sent_to :: proc(h: ^Test_Harness($T), t: ^testing.T, to: PID, $M: typeid) -> M
expect_sent_where :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid, pred: proc(_: M) -> bool) -> M
expect_no_sends :: proc(h: ^Test_Harness($T), t: ^testing.T)
sent_count :: proc(h: ^Test_Harness($T)) -> int
clear_sent :: proc(h: ^Test_Harness($T))
find_sent :: proc(h: ^Test_Harness($T), $M: typeid) -> (M, int, bool)
expect_published :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid) -> M
expect_published_to :: proc(h: ^Test_Harness($T), t: ^testing.T, topic: rawptr, $M: typeid) -> M
expect_no_publishes :: proc(h: ^Test_Harness($T), t: ^testing.T)
expect_spawned :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid) -> Captured_Spawn
expect_terminated :: proc(h: ^Test_Harness($T), t: ^testing.T) -> Captured_Terminate
expect_terminated_pid :: proc(h: ^Test_Harness($T), t: ^testing.T, pid: PID) -> Captured_Terminate
expect_broadcast :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid) -> M
expect_renamed :: proc(h: ^Test_Harness($T), t: ^testing.T) -> Captured_Rename
expect_subscribed_type :: proc(h: ^Test_Harness($T), t: ^testing.T) -> Captured_Subscribe
expect_subscribed_topic :: proc(h: ^Test_Harness($T), t: ^testing.T, topic: rawptr) -> Captured_Topic_Subscribe
```

`fire_timer` delivers a `Timer_Tick` for the given id. Get the id from `expect_timer`
rather than assuming it, and prefer both to constructing an `act.Timer_Tick` by hand.

## Simulation Testing

Test multiple actors together with a deterministic message queue. No real threads. Messages are queued and delivered step by step.

```odin
import sim "test_harness/sim"

@(test)
test_ping_pong :: proc(t: ^testing.T) {
    s := sim.create()
    defer sim.destroy(&s)

    ponger_pid := sim.spawn(&s, "ponger", Ponger{}, ponger_behaviour)
    sim.spawn(&s, "pinger", Pinger{target = ponger_pid}, pinger_behaviour)
    sim.init_all(&s)

    sim.send(&s, "pinger", Start{})
    sim.run_until_idle(&s)

    ponger := sim.get_state(&s, "ponger", Ponger)
    testing.expect_value(t, ponger.pings, 1)
}
```

Two things to know before writing a sim test:

- **`sim.spawn` does not run `init`.** Call `sim.init_all(&s)` once after spawning every
  actor, or no actor's `init` ever runs and anything it sets up (timers, subscriptions,
  sibling lookups) is missing.
- **Sim has no send assertions.** Unlike the unit harness there is no `expect_sent`.
  Assert on the receiver's state through `sim.get_state(&s, name, T)`, which is what the
  sim's own tests do.

There is also no external kill, so `sim.expect_dead` is only reachable after an actor
terminates itself or you clear the flag by hand, which is what the sim's own tests do:

```odin
sim.find_actor_by_pid(&s, u64(pid)).alive = false
```

The sim models ask and reply in full, including timeout expiry on `sim.advance_time` and
the dropping of a late reply, so a handler built on `act.ask` / `act.reply` /
`act.replying_to` can be tested here. The unit harness does not.

Every sim capacity is a fixed array and overflowing one is an `assert`, not a soft
failure: 32 actors, a 1024-message queue, 128 timers, 64 topics, 16 subscribers per
topic, 16 fault rules.

### Sim API

```odin
// Lifecycle
create :: proc() -> Sim
create_seeded :: proc(seed: u64) -> Sim
destroy :: proc(s: ^Sim)

// Actors
spawn :: proc(s: ^Sim, name: string, data: $T, behaviour: Actor_Behaviour(T)) -> PID
init_all :: proc(s: ^Sim)

// Message delivery
send :: proc(s: ^Sim, actor_name: string, content: $T)              // external -> actor by name
send_to :: proc(s: ^Sim, pid: PID, content: $T)                     // external -> actor by PID
send_from :: proc(s: ^Sim, to, from: PID, content: $T)              // actor -> actor
publish :: proc(s: ^Sim, topic: rawptr, content: $T)
step :: proc(s: ^Sim) -> bool          // process one queued message, false if none
run_until_idle :: proc(s: ^Sim)        // drain the queue

// Time
advance_time :: proc(s: ^Sim, d: time.Duration)

// State and assertions
get_state :: proc(s: ^Sim, name: string, $T: typeid) -> ^T
expect_alive :: proc(s: ^Sim, t: ^testing.T, name: string)
expect_dead :: proc(s: ^Sim, t: ^testing.T, name: string)
expect_idle :: proc(s: ^Sim, t: ^testing.T)
expect_spawned :: proc(s: ^Sim, t: ^testing.T, $T: typeid) -> Captured_Spawn
find_spawn :: proc(s: ^Sim, $T: typeid) -> (Captured_Spawn, bool)

// Timers
cancel_timer :: proc(s: ^Sim, id: u32)

// Inspection
pending_messages :: proc(s: ^Sim) -> int
delayed_count :: proc(s: ^Sim) -> int
find_actor_by_name :: proc(s: ^Sim, name: string) -> ^Sim_Actor
find_actor_by_pid :: proc(s: ^Sim, pid: u64) -> ^Sim_Actor
EXTERNAL_PID :: u64(999)               // the `from` pid stamped by send, send_to and publish

// Fault injection
add_fault :: proc(s: ^Sim, rule: Fault_Rule)
clear_faults :: proc(s: ^Sim)
```

## Fault Injection

Inject faults into the simulation to test error handling:

```odin
// Drop every message to "receiver" from "sender", for the whole test
sim.add_fault(&s, {
    match  = { to_name = "receiver", from_name = "sender" },
    action = .Drop,
})

// Delay delivery by 3 steps
sim.add_fault(&s, {
    match       = { to_name = "receiver", msg_type = typeid_of(MyMessage) },
    action      = .Delay,
    delay_steps = 3,
})

// Duplicate messages
sim.add_fault(&s, {
    match  = { to_name = "receiver" },
    action = .Duplicate,
})

// Probabilistic fault (30% chance, fire 5 times then stop)
sim.add_fault(&s, {
    match       = { to_name = "receiver", msg_type = typeid_of(MyMessage) },
    action      = .Drop,
    count       = 5,
    probability = 0.3,
})
```

`count` caps how many times a rule fires. Its zero value means no cap, so a rule written
without it injects on every matching message, which is what a fault written to prove a
handler survives a drop should do. A negative count is also uncapped.

`probability` works the same way: zero means the rule always fires.

A rule acts on any given message at most once. That is what makes an uncapped rule safe
for every action: an uncapped `.Duplicate` copies each original once rather than
duplicating its own clones forever, and an uncapped `.Delay` holds each message for
`delay_steps` and then delivers it rather than re-delaying it forever. A different rule
can still act on the same message.

### Fault Actions

```odin
Fault_Action :: enum {
    Drop,       // silently discard
    Delay,      // hold for N steps
    Duplicate,  // deliver twice
}
```

## Virtual Time

Both the unit harness and sim support virtual time for deterministic testing:

```odin
// Unit test
th.set_virtual_now(&h, some_time)
th.advance_time(&h, 5 * time.Second)

// Sim (no absolute setter, advance from the epoch the sim starts at)
sim.advance_time(&s, 5 * time.Second)
```

**Important:** Actor code that needs the current time must use `act.now()` instead of `time.now()`. In production, `act.now()` returns real time. In test contexts, it returns the virtual clock, making your tests deterministic and independent of wall-clock timing.

```odin
handle_message = proc(d: ^My_Data, from: act.PID, msg: any) {
    current := act.now()  // virtual in tests, real in production
    elapsed := time.diff(d.last_seen, current)
    if elapsed > 30 * time.Second {
        // timed out
    }
},
```

If you use `time.now()` directly, virtual time won't work and your tests will depend on real elapsed time.

## Deterministic Simulation Testing

A node started with `sim_mode = true` creates **zero OS threads**. Workers, timers, and network IO all run inline when you pump the node from the calling thread:

```odin
act.node_init("test", act.make_node_config(sim_mode = true, worker_count = 2))

pid, _ := act.spawn("counter", Counter{}, counter_behaviour)
act.send_message(pid, Increment{})

act.sim_run_until_idle()   // run every ready actor until nothing is runnable
```

Because everything happens on one thread, execution is deterministic. `act.sim_seed(n)` makes the scheduler pick the next runnable actor from a seeded RNG instead of round-robin, so one scenario can be replayed under many different interleavings, and any interleaving can be replayed exactly by reusing its seed.

Under `sim_mode`, real networking runs over an in-process byte pipe instead of the kernel: the wire format, handshake, authentication, partial-frame reassembly, and connection lifecycle are the production code paths, but delivery order and timing are under test control, and the virtual clock (`act.now()`) compresses timer races (heartbeat timeouts vs reconnect backoff vs restart windows) into microseconds.

### What DST does not cover

- **Lock-free memory ordering.** Serialized execution cannot produce fence bugs or MPSC races. That layer is owned by ThreadSanitizer and release-build stress tests on real threads.
- **The kernel boundary.** The virtual transport is a byte stream with scriptable delivery; io_uring quirks and real TCP timing are out of scope. The multi-process integration tests remain the reality check.

### The VOPR (internal)

The repository's own DST harness lives in the integration suite: a multi-node **sim mesh** (N real nodes on one thread, with scripted partitions, crashes, restarts, clock jumps, and per-link frame faults) and the **VOPR**, a seed-driven scenario fuzzer in the style of FoundationDB and TigerBeetle. Each seed generates an entire scenario; invariants (no duplicated delivery, no phantom messages, no livelock, reconnect and gossip convergence) are checked as it runs.

```bash
make vopr                  # sweep 200 fresh seeds (~16s)
make vopr VOPR_COUNT=10000 # deep local sweep before merging risky changes
```

A failure prints the seed and a replay one-liner; a replay under the same binary and profile is deterministic (cross-binary replays are not: any change to the op generator re-maps what every seed decodes to). Determinism is proven within a process by trace-equality tests; cross-process identity additionally requires the scenario to be the first mesh in its process, which the seed-replay path guarantees. `ACTOD_VOPR_VERBOSE=1` prints the generated op script with full logging. Failing seeds get committed to `VOPR_REGRESSION_SEEDS` so they keep running in `make test`, but because generator changes re-map seeds, every VOPR-found fix is durably pinned by a dedicated deterministic test in `sim_regression_test.odin` as well. CI runs a 500-seed sweep on every push to `main` and on every pull request.

These APIs (`sim_mesh_create`, `frame_tap_add`, the trace hook) are package-internal for now; the facade exposes `sim_mode`, `sim_pump`, `sim_seed`, and `sim_run_until_idle`. A user-facing mesh API (embedded multi-node tests in your own suite) is planned.

---
[< Actor Registry](12_actor-registry.md) | [Delivery Semantics >](14_delivery-semantics.md)
