# Test Harness

Actod provides two testing tools: a **unit test harness** for isolated single-actor testing, and a **simulation framework** for multi-actor scenarios with fault injection.

## Running Tests

```bash
odin test .
```

The test harness doesn't start a real node or worker pool. Actors run synchronously — `send` captures messages, `step` processes one at a time. No threads, no timing, fully deterministic.

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
add_child :: proc(h: ^Test_Harness($T), pid: PID)
set_parent :: proc(h: ^Test_Harness($T), pid: PID)

// Time
set_virtual_now :: proc(h: ^Test_Harness($T), t: time.Time)
advance_time :: proc(h: ^Test_Harness($T), d: time.Duration)

// Supervision simulation
simulate_child_terminated :: proc(h: ^Test_Harness($T), child_pid: PID, reason: Termination_Reason, will_restart: bool)
simulate_child_started :: proc(h: ^Test_Harness($T), child_pid: PID)
simulate_child_restarted :: proc(h: ^Test_Harness($T), old_pid: PID, new_pid: PID, restart_count: int)
simulate_max_restarts :: proc(h: ^Test_Harness($T), child_pid: PID)

// Assertions
expect_sent :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid) -> M
expect_sent_to :: proc(h: ^Test_Harness($T), t: ^testing.T, to: PID, $M: typeid) -> M
expect_sent_where :: proc(h: ^Test_Harness($T), t: ^testing.T, $M: typeid, pred: proc(_: M) -> bool) -> M
```

## Simulation Testing

Test multiple actors together with a deterministic message queue. No real threads — messages are queued and delivered step by step.

```odin
import sim "test_harness/sim"

@(test)
test_ping_pong :: proc(t: ^testing.T) {
    s := sim.create()
    defer sim.destroy(&s)

    ponger_pid := sim.spawn(&s, "ponger", Ponger{}, ponger_behaviour)
    pinger_pid := sim.spawn(&s, "pinger", Pinger{target = ponger_pid}, pinger_behaviour)

    sim.deliver(&s, "pinger", "external", Start{})

    // Step through message processing
    for i in 0 ..< 10 {
        sim.step(&s)
    }

    // Check results
    reply, ok := sim.expect_sent(&s, "ponger", "pinger", Pong)
    testing.expect(t, ok)
}
```

### Sim API

```odin
// Lifecycle
create :: proc() -> Sim
create_seeded :: proc(seed: u64) -> Sim
destroy :: proc(s: ^Sim)

// Actors
spawn :: proc(s: ^Sim, name: string, data: $T, behaviour: Actor_Behaviour(T)) -> u64

// Message delivery
send :: proc(s: ^Sim, actor_name: string, content: $T)          // external -> actor
send_to :: proc(s: ^Sim, pid: PID, content: $T)                 // external -> actor by PID
deliver :: proc(s: ^Sim, to_name: string, from_name: string, msg: $T) -> bool
deliver_to :: proc(s: ^Sim, to_pid: u64, from_pid: u64, msg: $T) -> bool
step :: proc(s: ^Sim) -> bool  // process one queued message

// Time
advance_time :: proc(s: ^Sim, d: time.Duration)
set_clock :: proc(s: ^Sim, t: time.Time)

// Assertions
expect_sent :: proc(s: ^Sim, to_name, from_name: string, $M: typeid) -> (M, bool)
expect_not_sent :: proc(s: ^Sim, to_name, from_name: string, $M: typeid) -> bool
expect_dead :: proc(s: ^Sim, t: ^testing.T, name: string)

// Inspection
pending_messages :: proc(s: ^Sim) -> int

// Fault injection
add_fault :: proc(s: ^Sim, rule: Fault_Rule)
clear_faults :: proc(s: ^Sim)
```

## Fault Injection

Inject faults into the simulation to test error handling:

```odin
// Drop all messages to "receiver" from "sender"
sim.add_fault(&s, {
    match     = { to_name = "receiver", from_name = "sender" },
    action    = .Drop,
    remaining = -1,  // -1 = forever
})

// Delay delivery by 3 steps
sim.add_fault(&s, {
    match       = { to_name = "receiver", msg_type = MyMessage },
    action      = .Delay,
    delay_steps = 3,
    remaining   = -1,
})

// Duplicate messages
sim.add_fault(&s, {
    match     = { to_name = "receiver" },
    action    = .Duplicate,
    remaining = -1,
})

// Probabilistic fault (30% chance, fire 5 times then stop)
sim.add_fault(&s, {
    match       = { to_name = "receiver", msg_type = MyMessage },
    action      = .Drop,
    remaining   = 5,
    probability = 0.3,
})
```

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

// Sim
sim.set_clock(&s, some_time)
sim.advance_time(&s, 5 * time.Second)
```

**Important:** Actor code that needs the current time must use `act.now()` instead of `time.now()`. In production, `act.now()` returns real time. In test contexts, it returns the virtual clock — making your tests deterministic and independent of wall-clock timing.

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

---
[< Actor Registry](12_actor-registry.md)
