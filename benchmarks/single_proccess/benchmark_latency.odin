package benchmark

import "../../src/actod"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"
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
LATENCY_SAMPLE_EVERY :: 16

Latency_Collector :: struct {
	samples:        []i64,
	count:          u64,
	received_count: u64,
	warmup_done:    bool,
	start_tick:     i64,
	end_tick:       i64,
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

record_latency :: #force_inline proc(seq_count: u64, send_time_ns: i64) {
	if !sync.atomic_load(&global_latency_collector.warmup_done) {
		return
	}

	if seq_count & (LATENCY_SAMPLE_EVERY - 1) != 0 {
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
			if data.message_count & 0xFF == 0 {
				sync.atomic_add(&global_latency_collector.received_count, 256)
			}

			switch m in msg {
			case Latency_Msg_32:
				record_latency(data.message_count, m.send_time_ns)
			case Latency_Msg_256:
				record_latency(data.message_count, m.send_time_ns)
			case Latency_Msg_1K:
				record_latency(data.message_count, m.send_time_ns)
			case Latency_Msg_4K:
				record_latency(data.message_count, m.send_time_ns)
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
		if received + 0xFF >= expected {
			return true
		}
		intrinsics.cpu_relax()
	}
	return false
}

SATURATION_PRODUCERS :: 4

Producer_Task :: struct {
	target:         actod.PID,
	size:           Latency_Size,
	warmup_share:   int,
	measured_share: int,
	warmup_wg:      ^sync.Wait_Group,
	go:             ^sync.Sema,
	done_wg:        ^sync.Wait_Group,
}

producer_proc :: proc(t: ^thread.Thread) {
	task := cast(^Producer_Task)t.data

	for i in 0 ..< task.warmup_share {
		for !send_latency_message(task.target, task.size, u64(i)) {
			intrinsics.cpu_relax()
		}
	}
	sync.wait_group_done(task.warmup_wg)

	sync.sema_wait(task.go)

	for i in 0 ..< task.measured_share {
		for !send_latency_message(task.target, task.size, u64(i)) {
			intrinsics.cpu_relax()
		}
	}
	sync.wait_group_done(task.done_wg)
}

send_flood :: proc(target: actod.PID, config: Latency_Config) -> (measured_total: int) {
	n := SATURATION_PRODUCERS
	warmup_share := config.warmup_count / n
	measured_share := config.message_count / n
	measured_total = measured_share * n

	warmup_wg: sync.Wait_Group
	done_wg: sync.Wait_Group
	go: sync.Sema
	sync.wait_group_add(&warmup_wg, n)
	sync.wait_group_add(&done_wg, n)

	tasks := make([]Producer_Task, n)
	defer delete(tasks)
	threads := make([]^thread.Thread, n)
	defer delete(threads)

	for i in 0 ..< n {
		tasks[i] = Producer_Task {
			target         = target,
			size           = config.size,
			warmup_share   = warmup_share,
			measured_share = measured_share,
			warmup_wg      = &warmup_wg,
			go             = &go,
			done_wg        = &done_wg,
		}
		t := thread.create(producer_proc)
		t.data = &tasks[i]
		threads[i] = t
		thread.start(t)
	}

	sync.wait_group_wait(&warmup_wg)
	wait_for_messages(u64(warmup_share * n), 5000)
	time.sleep(1 * time.Millisecond)

	sync.atomic_store(&global_latency_collector.count, 0)
	sync.atomic_store(&global_latency_collector.received_count, 0)
	sync.atomic_store(&global_latency_collector.warmup_done, true)
	sync.atomic_store(&global_latency_collector.start_tick, time.tick_now()._nsec)

	sync.sema_post(&go, n)

	sync.wait_group_wait(&done_wg)

	thread.join_multiple(..threads[:])
	for t in threads {
		thread.destroy(t)
	}
	return
}

run_latency_benchmark :: proc(config: Latency_Config) -> Latency_Stats {
	reset_latency_collector()

	actor := spawn_latency_actor()
	defer {
		actod.terminate_actor(actor)
		time.sleep(10 * time.Millisecond)
	}

	time.sleep(5 * time.Millisecond)

	measured_total := send_flood(actor, config)

	expected := u64(measured_total)
	if !wait_for_messages(expected, 10000) {
		received := sync.atomic_load(&global_latency_collector.received_count)
		fmt.printf(
			"WARNING: Timeout waiting for messages. Expected %d, got %d\n",
			expected,
			received,
		)
	}
	sync.atomic_store(&global_latency_collector.end_tick, time.tick_now()._nsec)

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

					if data.current_idx < len(data.samples) {
						data.samples[data.current_idx] = round_trip
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
		home_worker = 1,
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
		home_worker = 0,
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
	fmt.println("\n=== Round-Trip Latency (Ping-Pong) ===")

	MESSAGE_COUNT :: 10_000

	fmt.println(
		"Size     │   p50    │   p90    │   p99    │  p99.9   │   Max    │  Jitter  │ Spread",
	)
	fmt.println(
		"─────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┼─────────",
	)

	test_sizes := []Latency_Size{.SIZE_32B, .SIZE_256B, .SIZE_1KB, .SIZE_4KB}

	for size in test_sizes {
		runs := make([]Latency_Stats, BENCH_REPEATS)
		for r in 0 ..< BENCH_REPEATS {
			runs[r] = run_pingpong_test(size, MESSAGE_COUNT)
			wait_for_actors_cleanup()
		}

		p50, p50_lo, p50_hi := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.p50})
		p90, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.p90})
		p99, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.p99})
		p99_9, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.p99_9})
		mx, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.max})
		jit, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.jitter})
		delete(runs)

		fmt.printf(
			"%-8s │ %8s │ %8s │ %8s │ %8s │ %8s │ %8s │ %s\n",
			size_name(size),
			format_latency(p50),
			format_latency(p90),
			format_latency(p99),
			format_latency(p99_9),
			format_latency(mx),
			format_latency(jit),
			fmt_spread(f64(p50), f64(p50_lo), f64(p50_hi)),
		)
	}

	fmt.println()
}

run_saturation_test :: proc() {
	fmt.println(
		"=== Saturation (producer outruns consumer; values are QUEUE DELAY, not service latency) ===",
	)
	fmt.printf(
		"%d producers flood 1 consumer. 'drain/s' = contended throughput, NOT a ceiling (see 1:1 BASE for the max single-consumer rate); qdelay sampled 1-in-%d\n",
		SATURATION_PRODUCERS,
		LATENCY_SAMPLE_EVERY,
	)

	init_latency_collector()
	defer destroy_latency_collector()

	MESSAGE_COUNT :: 5_000_000
	WARMUP_COUNT :: 100_000

	fmt.println(
		"Size     │ drain/s  │ qdelay p50 │ qdelay p99 │ qdelay max │ Backlog      │ Spread",
	)
	fmt.println(
		"─────────┼──────────┼────────────┼────────────┼────────────┼──────────────┼─────────",
	)

	test_sizes := []Latency_Size{.SIZE_32B, .SIZE_1KB, .SIZE_4KB}

	for size in test_sizes {
		config := Latency_Config {
			scenario      = .FLOOD,
			size          = size,
			message_count = MESSAGE_COUNT,
			warmup_count  = WARMUP_COUNT,
		}

		tputs := make([]f64, BENCH_REPEATS)
		runs := make([]Latency_Stats, BENCH_REPEATS)
		for r in 0 ..< BENCH_REPEATS {
			runs[r] = run_latency_benchmark(config)
			start_ns := sync.atomic_load(&global_latency_collector.start_tick)
			end_ns := sync.atomic_load(&global_latency_collector.end_tick)
			duration_s := f64(end_ns - start_ns) / 1e9
			tputs[r] = f64(MESSAGE_COUNT) / duration_s
			wait_for_actors_cleanup()
		}
		median_tput, lo, hi := summarize_f64(tputs)
		delete(tputs)

		p50, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.p50})
		p99, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.p99})
		mx, _, _ := median_lo_hi_stat(runs, proc(s: Latency_Stats) -> i64 {return s.max})
		delete(runs)

		queue_indicator: string
		if p99 > 50_000 || p50 > 20_000 {
			queue_indicator = "Heavy"
		} else if p99 > 5_000 || p50 > 2_000 {
			queue_indicator = "Moderate"
		} else {
			queue_indicator = "Light"
		}

		fmt.printf(
			"%-8s │ %7sM │ %10s │ %10s │ %10s │ %-12s │ %s\n",
			size_name(size),
			fmt.tprintf("%.2f", median_tput / 1_000_000),
			format_latency(p50),
			format_latency(p99),
			format_latency(mx),
			queue_indicator,
			fmt_spread(median_tput, lo, hi),
		)
	}

	fmt.println()
}
