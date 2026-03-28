# Timer

Actors can schedule one-shot or repeating timers. When a timer fires, the actor receives a `Timer_Tick` message.

## Usage

```odin
import act "actod"

My_Data :: struct {
    heartbeat_timer: u32,
}

my_behaviour := act.Actor_Behaviour(My_Data){
    init = proc(d: ^My_Data) {
        id, err := act.set_timer(1 * time.Second, repeat = true)
        d.heartbeat_timer = id
    },

    handle_message = proc(d: ^My_Data, from: act.PID, msg: any) {
        switch v in msg {
        case act.Timer_Tick:
            if v.id == d.heartbeat_timer {
                // heartbeat fired
            }
        }
    },

    terminate = proc(d: ^My_Data) {
        act.cancel_timer(d.heartbeat_timer)
    },
}
```

## API

```odin
// Schedule a timer. Returns timer ID and any send error.
set_timer :: proc(interval: time.Duration, repeat: bool) -> (u32, Send_Error)

// Cancel a running timer.
cancel_timer :: proc(id: u32) -> Send_Error

// Current time (respects virtual time in test harness).
now :: proc() -> time.Time
```

## Timer_Tick

```odin
Timer_Tick :: struct {
    id: u32,
}
```

Match on `id` to distinguish between multiple timers on the same actor.

## Details

- Timers are managed by a dedicated system timer actor
- One-shot timers fire once and are automatically removed
- Repeating timers re-schedule after each fire
- Timers are cleaned up when the owning actor terminates
- Precision is millisecond-level (1ms sleep granularity)

---
[< Supervisor](04_supervisor.md) | [Pub/Sub >](06_pubsub.md)
