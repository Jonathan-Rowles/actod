package rtt_scratch

import "../../src/actod"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:slice"
import "core:sync"
import "core:time"

ECHO_PORT :: 17300
BURST_COUNT :: 2000
IDLE_COUNT :: 200
IDLE_GAP :: 10 * time.Millisecond

Ping :: struct {
	seq: u64,
	pad: [24]u8,
}

Bcast_Request :: struct {
	seq: u64,
	pad: [24]u8,
}

Ping_Start :: struct {
	count:         u64,
	gap:           time.Duration,
	use_broadcast: bool,
}

@(init)
register_rtt_messages :: proc "contextless" () {
	context = runtime.default_context()
	actod.register_message_type(Ping)
	actod.register_message_type(Bcast_Request)
	actod.register_message_type(Ping_Start)
}

ring_config := actod.Connection_Ring_Config {
	send_slot_count               = 64,
	send_slot_size                = 64 * 1024,
	recv_buffer_size              = 4 * 1024 * 1024,
	tcp_nodelay                   = true,
	scale_up_contention_threshold = 1,
	scale_down_idle_seconds       = 10,
}

run_echo :: proc() {
	actod.node_init(
		name = "EchoRTT",
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = ECHO_PORT,
				auth_password = "rtt_password",
				connection_ring = ring_config,
			),
			actor_config = actod.make_actor_config(
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(level = .Error),
			),
		),
	)

	echo_type, _ := actod.register_actor_type("rtt_echo")
	behaviour := actod.Actor_Behaviour(int) {
		actor_type = echo_type,
		handle_message = proc(data: ^int, from: actod.PID, msg: any) {
			switch m in msg {
			case Ping:
				_ = actod.send_message(from, m)
			case Bcast_Request:
				actod.broadcast(Ping{seq = m.seq})
			}
		},
	}
	_, ok := actod.spawn("Echo", 0, behaviour)
	if !ok {
		panic("Failed to spawn echo actor")
	}

	fmt.println("[echo] ready")
	actod.await_signal()
}

Pinger_Data :: struct {
	count:         u64,
	gap:           time.Duration,
	use_broadcast: bool,
	echo_type:     actod.Actor_Type,
	seq:           u64,
	sent_at:       time.Tick,
	timer_id:      u32,
}

global_rtts: [BURST_COUNT]i64
global_done: u32

send_ping :: proc(data: ^Pinger_Data) {
	data.sent_at = time.tick_now()
	err: actod.Send_Error
	if data.use_broadcast {
		err = actod.send_remote_by_name("EchoRTT", "Echo", Bcast_Request{seq = data.seq})
	} else {
		err = actod.send_remote_by_name("EchoRTT", "Echo", Ping{seq = data.seq})
	}
	if err != .OK {
		fmt.printf("[ping] send failed: %v\n", err)
	}
}

create_pinger_behaviour :: proc() -> actod.Actor_Behaviour(Pinger_Data) {
	return actod.Actor_Behaviour(Pinger_Data) {
		init = proc(data: ^Pinger_Data) {
			_, _ = actod.subscribe_type(data.echo_type)
		},
		handle_message = proc(data: ^Pinger_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Ping_Start:
				data.count = m.count
				data.gap = m.gap
				data.use_broadcast = m.use_broadcast
				data.seq = 0
				send_ping(data)

			case Ping:
				global_rtts[data.seq] = i64(time.tick_since(data.sent_at))
				data.seq += 1
				if data.seq >= data.count {
					sync.atomic_store(&global_done, 1)
					return
				}
				if data.gap > 0 {
					data.timer_id, _ = actod.set_timer(data.gap, false)
				} else {
					send_ping(data)
				}

			case actod.Timer_Tick:
				if m.id == data.timer_id {
					send_ping(data)
				}
			}
		},
	}
}

report :: proc(label: string, n: u64) {
	rtts := global_rtts[:n]
	slice.sort(rtts)
	fmt.printf(
		"%s: n=%d min=%.1fus p50=%.1fus p99=%.1fus max=%.1fus\n",
		label,
		n,
		f64(rtts[0]) / 1000,
		f64(rtts[n / 2]) / 1000,
		f64(rtts[n * 99 / 100]) / 1000,
		f64(rtts[n - 1]) / 1000,
	)
}

run_phase :: proc(
	pinger: actod.PID,
	label: string,
	count: u64,
	gap: time.Duration,
	use_broadcast := false,
) {
	sync.atomic_store(&global_done, 0)
	_ = actod.send_message(pinger, Ping_Start{count = count, gap = gap, use_broadcast = use_broadcast})
	deadline := time.now()
	for sync.atomic_load(&global_done) == 0 {
		if time.since(deadline) > 60 * time.Second {
			fmt.printf("%s: timed out\n", label)
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	report(label, count)
}

run_ping :: proc() {
	actod.node_init(
		name = "PingRTT",
		opts = actod.make_node_config(
			network = actod.make_network_config(
				port = 0,
				auth_password = "rtt_password",
				connection_ring = ring_config,
			),
			actor_config = actod.make_actor_config(
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(level = .Error),
			),
		),
	)
	defer actod.shutdown_node()

	remote := net.Endpoint {
		address = net.IP4_Loopback,
		port    = ECHO_PORT,
	}
	_, ok := actod.register_node("EchoRTT", remote, .TCP_Custom_Protocol)
	if !ok {
		panic("Failed to register echo node")
	}

	echo_type, _ := actod.register_actor_type("rtt_echo")
	pinger, spawned := actod.spawn(
		"Pinger",
		Pinger_Data{echo_type = echo_type},
		create_pinger_behaviour(),
	)
	if !spawned {
		panic("Failed to spawn pinger actor")
	}

	time.sleep(1 * time.Second)

	run_phase(pinger, "warmup", 500, 0)
	run_phase(pinger, "direct burst (back-to-back)", BURST_COUNT, 0)
	run_phase(pinger, "direct idle  (10ms gaps)   ", IDLE_COUNT, IDLE_GAP)
	run_phase(pinger, "bcast  burst (back-to-back)", BURST_COUNT, 0, use_broadcast = true)
	run_phase(pinger, "bcast  idle  (10ms gaps)   ", IDLE_COUNT, IDLE_GAP, use_broadcast = true)
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "echo" {
		run_echo()
	} else {
		run_ping()
	}
}
