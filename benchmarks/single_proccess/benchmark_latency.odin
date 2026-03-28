package benchmark

import "../../src/actod"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import "core:time"

Latency_Msg_32 :: struct {
	send_time_ns: i64,
	sequence:     u64,
	_padding:     [16]byte,
}

Latency_Msg_256 :: struct {
	send_time_ns: i64,
	sequence:     u64,
	_padding:     [240]byte,
}

Latency_Msg_1K :: struct {
	send_time_ns: i64,
	sequence:     u64,
	_padding:     [1024 - 16]byte,
}

Latency_Msg_4K :: struct {
	send_time_ns: i64,
	sequence:     u64,
	_padding:     [4096 - 16]byte,
}

@(init)
register_latency_messages :: proc "contextless" () {
	actod.register_message_type(Latency_Msg_32)
	actod.register_message_type(Latency_Msg_256)
	actod.register_message_type(Latency_Msg_1K)
	actod.register_message_type(Latency_Msg_4K)
}

MAX_LATENCY_SAMPLES :: 1_000_000

Latency_Collector :: struct {
	samples:        []i64,
	count:          u64,
	received_count: u64,
	warmup_done:    bool,
	start_time:     time.Time,
}

global_latency_collector: Latency_Collector

Latency_Stats :: struct {
	p50:            i64,
	p90:            i64,
	p99:            i64,
	p99_9:          i64,
	max:            i64,
	min:            i64,
	mean:           f64,
	jitter:         i64,
	samples_stored: u64,
	msgs_received:  u64,
}

Latency_Scenario :: enum {
	FLOOD,
}

Latency_Size :: enum {
	SIZE_32B,
	SIZE_256B,
	SIZE_1KB,
	SIZE_4KB,
}

Latency_Config :: struct {
	scenario:      Latency_Scenario,
	size:          Latency_Size,
	message_count: int,
	warmup_count:  int,
}

size_name :: proc(s: Latency_Size) -> string {
	switch s {
	case .SIZE_32B:
		return "32B"
	case .SIZE_256B:
		return "256B"
	case .SIZE_1KB:
		return "1KB"
	case .SIZE_4KB:
		return "4KB"
	}
	return "?"
}

init_latency_collector :: proc() {
	global_latency_collector.samples = make([]i64, MAX_LATENCY_SAMPLES)
	sync.atomic_store(&global_latency_collector.count, 0)
	sync.atomic_store(&global_latency_collector.received_count, 0)
	sync.atomic_store(&global_latency_collector.warmup_done, false)
}

reset_latency_collector :: proc() {
	sync.atomic_store(&global_latency_collector.count, 0)
	sync.atomic_store(&global_latency_collector.received_count, 0)
	sync.atomic_store(&global_latency_collector.warmup_done, false)
}

destroy_latency_collector :: proc() {
	delete(global_latency_collector.samples)
}

record_latency :: #force_inline proc(send_time_ns: i64) {
	sync.atomic_add(&global_latency_collector.received_count, 1)

	if !sync.atomic_load(&global_latency_collector.warmup_done) {
		return
	}

	recv_time_ns := time.tick_now()._nsec
	latency := recv_time_ns - send_time_ns

	if latency < 0 {
		return
	}

	idx := sync.atomic_add(&global_latency_collector.count, 1) - 1
	if idx < MAX_LATENCY_SAMPLES {
		global_latency_collector.samples[idx] = latency
	}
}

compute_latency_stats :: proc() -> Latency_Stats {
	count := min(sync.atomic_load(&global_latency_collector.count), u64(MAX_LATENCY_SAMPLES))
	received := sync.atomic_load(&global_latency_collector.received_count)

	if count == 0 {
		return Latency_Stats{msgs_received = received}
	}

	samples := global_latency_collector.samples[:count]
	slice.sort(samples)

	p50_idx := max(int(f64(count) * 0.50), 0)
	p90_idx := max(int(f64(count) * 0.90), 0)
	p99_idx := max(int(f64(count) * 0.99), 0)
	p99_9_idx := min(int(f64(count) * 0.999), int(count) - 1)

	sum: i64 = 0
	for s in samples {
		sum += s
	}
	mean := f64(sum) / f64(count)

	var_sum: f64 = 0
	for s in samples {
		diff := f64(s) - mean
		var_sum += diff * diff
	}
	jitter := i64(math.sqrt(var_sum / f64(count)))

	return Latency_Stats {
		p50 = samples[p50_idx],
		p90 = samples[p90_idx],
		p99 = samples[p99_idx],
		p99_9 = samples[p99_9_idx],
		max = samples[count - 1],
		min = samples[0],
		mean = mean,
		jitter = jitter,
		samples_stored = count,
		msgs_received = received,
	}
}

Latency_Actor_Data :: struct {
	message_count: u64,
}

create_latency_behaviour :: proc() -> actod.Actor_Behaviour(Latency_Actor_Data) {
	return actod.Actor_Behaviour(Latency_Actor_Data) {
		handle_message = proc(data: ^Latency_Actor_Data, from: actod.PID, msg: any) {
			data.message_count += 1

			switch m in msg {
			case Latency_Msg_32:
				record_latency(m.send_time_ns)
			case Latency_Msg_256:
				record_latency(m.send_time_ns)
			case Latency_Msg_1K:
				record_latency(m.send_time_ns)
			case Latency_Msg_4K:
				record_latency(m.send_time_ns)
			}
		},
		init = proc(data: ^Latency_Actor_Data) {
			data.message_count = 0
		},
	}
}

spawn_latency_actor :: proc() -> actod.PID {
	data := Latency_Actor_Data{}
	behaviour := create_latency_behaviour()

	actor_config := actod.make_actor_config(
		logging = actod.make_log_config(enable_file = false, level = .Warning),
	)

	pid, ok := actod.spawn("latency_actor", data, behaviour, actor_config)
	if !ok {
		panic("Failed to spawn latency actor")
	}
	return pid
}

send_latency_message :: proc(target: actod.PID, size: Latency_Size, seq: u64) -> bool {
	ts := time.tick_now()._nsec

	switch size {
	case .SIZE_32B:
		msg := Latency_Msg_32 {
			send_time_ns = ts,
			sequence     = seq,
		}
		return actod.send_message(target, msg) == .OK
	case .SIZE_256B:
		msg := Latency_Msg_256 {
			send_time_ns = ts,
			sequence     = seq,
		}
		return actod.send_message(target, msg) == .OK
	case .SIZE_1KB:
		msg := Latency_Msg_1K {
			send_time_ns = ts,
			sequence     = seq,
		}
		return actod.send_message(target, msg) == .OK
	case .SIZE_4KB:
		msg := Latency_Msg_4K {
			send_time_ns = ts,
			sequence     = seq,
		}
		return actod.send_message(target, msg) == .OK
	}
	return false
}

wait_for_messages :: proc(expected: u64, timeout_ms: int) -> bool {
	deadline := time.tick_now()._nsec + i64(timeout_ms) * 1_000_000

	for time.tick_now()._nsec < deadline {
		received := sync.atomic_load(&global_latency_collector.received_count)
		if received >= expected {
			return true
		}
		intrinsics.cpu_relax()
	}
	return false
}

send_flood :: proc(target: actod.PID, config: Latency_Config) {
	for i in 0 ..< config.warmup_count {
		for !send_latency_message(target, config.size, u64(i)) {
			intrinsics.cpu_relax()
		}
	}

	wait_for_messages(u64(config.warmup_count), 5000)
	time.sleep(1 * time.Millisecond)

	sync.atomic_store(&global_latency_collector.count, 0)
	sync.atomic_store(&global_latency_collector.received_count, 0)
	sync.atomic_store(&global_latency_collector.warmup_done, true)
	global_latency_collector.start_time = time.now()

	for i in 0 ..< config.message_count {
		for !send_latency_message(target, config.size, u64(i)) {
			intrinsics.cpu_relax()
		}
	}
}

run_latency_benchmark :: proc(config: Latency_Config) -> Latency_Stats {
	reset_latency_collector()

	actor := spawn_latency_actor()
	defer {
		actod.terminate_actor(actor)
		time.sleep(10 * time.Millisecond)
	}

	time.sleep(5 * time.Millisecond)

	send_flood(actor, config)

	expected := u64(config.message_count)
	if !wait_for_messages(expected, 10000) {
		received := sync.atomic_load(&global_latency_collector.received_count)
		fmt.printf(
			"WARNING: Timeout waiting for messages. Expected %d, got %d\n",
			expected,
			received,
		)
	}

	return compute_latency_stats()
}

format_latency :: proc(ns: i64) -> string {
	if ns < 1_000 {
		return fmt.tprintf("%5s ns", fmt.tprintf("%d", ns))
	} else if ns < 1_000_000 {
		return fmt.tprintf("%5s us", fmt.tprintf("%.1f", f64(ns) / 1_000.0))
	} else {
		return fmt.tprintf("%5s ms", fmt.tprintf("%.2f", f64(ns) / 1_000_000.0))
	}
}

Pingpong_Reply :: struct {
	send_time_ns: i64,
	sequence:     u64,
}

Start_Pingpong :: struct {
	count: int,
}

@(init)
register_pingpong :: proc "contextless" () {
	actod.register_message_type(Pingpong_Reply)
	actod.register_message_type(Start_Pingpong)
}

Pingpong_Receiver_Data :: struct {}

Pingpong_Sender_Data :: struct {
	receiver:       actod.PID,
	size:           Latency_Size,
	samples:        []i64,
	current_idx:    int,
	total_count:    int,
	warmup_done:    bool,
	warmup_replies: int,
	done_sema:      ^sync.Sema,
}

create_pingpong_receiver_behaviour :: proc() -> actod.Actor_Behaviour(Pingpong_Receiver_Data) {
	return actod.Actor_Behaviour(Pingpong_Receiver_Data) {
		handle_message = proc(data: ^Pingpong_Receiver_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Latency_Msg_32:
				actod.send_message(
					from,
					Pingpong_Reply{send_time_ns = m.send_time_ns, sequence = m.sequence},
				)
			case Latency_Msg_256:
				actod.send_message(
					from,
					Pingpong_Reply{send_time_ns = m.send_time_ns, sequence = m.sequence},
				)
			case Latency_Msg_1K:
				actod.send_message(
					from,
					Pingpong_Reply{send_time_ns = m.send_time_ns, sequence = m.sequence},
				)
			case Latency_Msg_4K:
				actod.send_message(
					from,
					Pingpong_Reply{send_time_ns = m.send_time_ns, sequence = m.sequence},
				)
			}
		},
		init = proc(data: ^Pingpong_Receiver_Data) {},
	}
}

create_pingpong_sender_behaviour :: proc() -> actod.Actor_Behaviour(Pingpong_Sender_Data) {
	return actod.Actor_Behaviour(Pingpong_Sender_Data) {
		handle_message = proc(data: ^Pingpong_Sender_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Start_Pingpong:
				data.total_count = m.count
				data.current_idx = 0
				data.warmup_done = false
				data.warmup_replies = 0
				send_latency_message(data.receiver, data.size, 0)

			case Pingpong_Reply:
				if !data.warmup_done {
					data.warmup_replies += 1
					if data.warmup_replies < 1000 {
						send_latency_message(data.receiver, data.size, u64(data.warmup_replies))
					} else {
						data.warmup_done = true
						data.current_idx = 0
						send_latency_message(data.receiver, data.size, 0)
					}
				} else {
					recv_time := time.tick_now()._nsec
					round_trip := recv_time - m.send_time_ns
					one_way := round_trip / 2

					if data.current_idx < len(data.samples) {
						data.samples[data.current_idx] = one_way
					}

					data.current_idx += 1

					if data.current_idx < data.total_count {
						send_latency_message(data.receiver, data.size, u64(data.current_idx))
					} else {
						sync.sema_post(data.done_sema)
					}
				}
			}
		},
		init = proc(data: ^Pingpong_Sender_Data) {},
	}
}

run_pingpong_test :: proc(size: Latency_Size, count: int) -> Latency_Stats {
	samples := make([]i64, count)
	defer delete(samples)

	done_sema: sync.Sema

	receiver_data := Pingpong_Receiver_Data{}
	receiver_behaviour := create_pingpong_receiver_behaviour()
	receiver_config := actod.make_actor_config(
		logging = actod.make_log_config(enable_file = false, level = .Warning),
	)
	receiver, ok_r := actod.spawn(
		"pingpong_receiver",
		receiver_data,
		receiver_behaviour,
		receiver_config,
	)
	if !ok_r {
		panic("Failed to spawn pingpong receiver")
	}
	defer actod.terminate_actor(receiver)

	sender_data := Pingpong_Sender_Data {
		receiver    = receiver,
		size        = size,
		samples     = samples,
		total_count = count,
		done_sema   = &done_sema,
	}
	sender_behaviour := create_pingpong_sender_behaviour()
	sender_config := actod.make_actor_config(
		logging = actod.make_log_config(enable_file = false, level = .Warning),
	)
	sender, ok_s := actod.spawn("pingpong_sender", sender_data, sender_behaviour, sender_config)
	if !ok_s {
		panic("Failed to spawn pingpong sender")
	}
	defer actod.terminate_actor(sender)

	time.sleep(5 * time.Millisecond)

	actod.send_message(sender, Start_Pingpong{count = count})

	sync.sema_wait(&done_sema)

	time.sleep(10 * time.Millisecond)

	slice.sort(samples)

	p50_idx := int(f64(count) * 0.50)
	p90_idx := int(f64(count) * 0.90)
	p99_idx := int(f64(count) * 0.99)
	p99_9_idx := min(int(f64(count) * 0.999), count - 1)

	sum: i64 = 0
	for s in samples {
		sum += s
	}
	mean := f64(sum) / f64(count)

	var_sum: f64 = 0
	for s in samples {
		diff := f64(s) - mean
		var_sum += diff * diff
	}
	jitter := i64(math.sqrt(var_sum / f64(count)))

	return Latency_Stats {
		p50 = samples[p50_idx],
		p90 = samples[p90_idx],
		p99 = samples[p99_idx],
		p99_9 = samples[p99_9_idx],
		max = samples[count - 1],
		min = samples[0],
		mean = mean,
		jitter = jitter,
		samples_stored = u64(count),
		msgs_received = u64(count),
	}
}

run_latency_pingpong :: proc() {
	fmt.println("\n=== Latency (Ping-Pong) ===")

	MESSAGE_COUNT :: 10_000

	fmt.println(
		"Size     │   p50    │   p90    │   p99    │  p99.9   │   Max    │  Jitter",
	)
	fmt.println(
		"─────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────",
	)

	test_sizes := []Latency_Size{.SIZE_32B, .SIZE_256B, .SIZE_1KB, .SIZE_4KB}

	for size in test_sizes {
		stats := run_pingpong_test(size, MESSAGE_COUNT)

		fmt.printf(
			"%-8s │ %8s │ %8s │ %8s │ %8s │ %8s │ %8s\n",
			size_name(size),
			format_latency(stats.p50),
			format_latency(stats.p90),
			format_latency(stats.p99),
			format_latency(stats.p99_9),
			format_latency(stats.max),
			format_latency(stats.jitter),
		)

		wait_for_actors_cleanup()
	}

	fmt.println()
}

run_saturation_test :: proc() {
	fmt.println("=== Saturation (Max Throughput) ===")

	init_latency_collector()
	defer destroy_latency_collector()

	MESSAGE_COUNT :: 20_000
	WARMUP_COUNT :: 2_000

	fmt.println("Size     │ Msgs/sec │   p50    │   p99    │   Max    │ Queue Effect")
	fmt.println(
		"─────────┼──────────┼──────────┼──────────┼──────────┼──────────────",
	)

	test_sizes := []Latency_Size{.SIZE_32B, .SIZE_1KB, .SIZE_4KB}

	for size in test_sizes {
		config := Latency_Config {
			scenario      = .FLOOD,
			size          = size,
			message_count = MESSAGE_COUNT,
			warmup_count  = WARMUP_COUNT,
		}

		stats := run_latency_benchmark(config)
		duration := time.since(global_latency_collector.start_time)

		throughput := f64(MESSAGE_COUNT) / time.duration_seconds(duration)

		queue_indicator: string
		if stats.p50 > 50_000 {
			queue_indicator = "Heavy"
		} else if stats.p50 > 5_000 {
			queue_indicator = "Moderate"
		} else {
			queue_indicator = "Light"
		}

		fmt.printf(
			"%-8s │ %7sM │ %8s │ %8s │ %8s │ %s\n",
			size_name(size),
			fmt.tprintf("%.2f", throughput / 1_000_000),
			format_latency(stats.p50),
			format_latency(stats.p99),
			format_latency(stats.max),
			queue_indicator,
		)

		wait_for_actors_cleanup()
	}

	fmt.println()
}
