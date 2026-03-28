package benchmark

import "../../src/actod"
import "../shared"
import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:time"

@(private = "file")
local_received: u64

Start_Flood :: struct {
	target:        actod.PID,
	message_count: int,
	warmup_count:  int,
}

@(init)
register_local_mailbox_messages :: proc "contextless" () {
	actod.register_message_type(Start_Flood)
}

Flood_Receiver_Data :: struct {
	count: u64,
}

Flood_Sender_Data :: struct {
	done_sema:        ^sync.Sema,
	warmup_done_sema: ^sync.Sema,
}

run_local_throughput :: proc(
	worker_count: int,
	message_count: int,
	$T: typeid,
) -> (
	throughput: f64,
) {
	done_sema: sync.Sema
	warmup_done_sema: sync.Sema

	actod.NODE_INIT(
		name = "local_bench",
		opts = actod.make_node_config(
			worker_count = worker_count,
			actor_config = actod.make_actor_config(
				page_size = mem.Kilobyte * 64,
				logging = actod.make_log_config(enable_file = false, level = .Warning),
				spin_strategy = actod.SPIN_STRATEGY.CPU_RELAX,
			),
		),
	)

	sync.atomic_store(&local_received, 0)

	receiver_behaviour := actod.Actor_Behaviour(Flood_Receiver_Data) {
		handle_message = proc(data: ^Flood_Receiver_Data, from: actod.PID, msg: any) {
			data.count += 1
			if data.count & 0xFF == 0 {
				sync.atomic_add(&local_received, 256)
			}
		},
		init = proc(data: ^Flood_Receiver_Data) {},
	}

	receiver_config := actod.make_actor_config(
		logging = actod.make_log_config(enable_file = false, level = .Warning),
	)
	receiver, ok_r := actod.spawn(
		"flood_receiver",
		Flood_Receiver_Data{},
		receiver_behaviour,
		receiver_config,
	)
	if !ok_r do panic("Failed to spawn receiver")

	sender_behaviour := actod.Actor_Behaviour(Flood_Sender_Data) {
		handle_message = proc(data: ^Flood_Sender_Data, from: actod.PID, msg: any) {
			switch m in msg {
			case Start_Flood:
				for _ in 0 ..< m.warmup_count {
					v: T
					actod.send_message(m.target, v)
				}

				sync.sema_post(data.warmup_done_sema)

				for _ in 0 ..< m.message_count {
					v: T
					actod.send_message(m.target, v)
				}

				sync.sema_post(data.done_sema)
			}
		},
		init = proc(data: ^Flood_Sender_Data) {},
	}

	sender_config := actod.make_actor_config(
		logging = actod.make_log_config(enable_file = false, level = .Warning),
	)
	sender_data := Flood_Sender_Data {
		done_sema        = &done_sema,
		warmup_done_sema = &warmup_done_sema,
	}
	sender, ok_s := actod.spawn("flood_sender", sender_data, sender_behaviour, sender_config)
	if !ok_s do panic("Failed to spawn sender")

	time.sleep(5 * time.Millisecond)

	actod.send_message(
		sender,
		Start_Flood{target = receiver, message_count = message_count, warmup_count = 10_000},
	)

	sync.sema_wait(&warmup_done_sema)
	start_ns := time.tick_now()._nsec

	sync.sema_wait(&done_sema)

	sent := u64(message_count)
	wait_start := time.tick_now()._nsec
	for {
		received := sync.atomic_load(&local_received)
		if received + 0xFF >= sent || time.tick_now()._nsec - wait_start > 100_000_000 {
			break
		}
		intrinsics.cpu_relax()
	}
	elapsed_ns := time.tick_now()._nsec - start_ns
	received := sync.atomic_load(&local_received)

	time.sleep(50 * time.Millisecond)

	actod.terminate_actor(sender)
	actod.terminate_actor(receiver)
	time.sleep(50 * time.Millisecond)

	actod.SHUTDOWN_NODE()

	duration_sec := f64(elapsed_ns) / 1e9
	throughput = f64(received) / duration_sec
	return
}

run_local_mailbox_benchmark :: proc() {
	MESSAGE_COUNT :: 1_000_000

	fmt.println("\n=== Local Mailbox Throughput (Actor-to-Actor) ===")
	fmt.println(
		"Sender actor floods receiver (no reply); throughput measured end-to-end, after the receiver drains\n",
	)

	fmt.println("Size     │ Workers │  Msgs/sec │ Spread")
	fmt.println(
		"─────────┼─────────┼───────────┼─────────",
	)

	for size_info in ([]struct {
			name:  string,
			size:  int,
			run_1: proc(_: int, _: int) -> f64,
			run_2: proc(_: int, _: int) -> f64,
		} {
			{
				name = "Empty",
				size = 0,
				run_1 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Empty_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Empty_Message,
					)},
			},
			{
				name = "32B",
				size = 32,
				run_1 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Inline_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Inline_Message,
					)},
			},
			{
				name = "256B",
				size = 256,
				run_1 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Medium_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Medium_Message,
					)},
			},
			{
				name = "1KB",
				size = 1024,
				run_1 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Large_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> f64 {return run_local_throughput(
						wc,
						mc,
						shared.Large_Message,
					)},
			},
		}) {
		for workers in ([]int{1, 2}) {
			tputs := make([]f64, BENCH_REPEATS)
			for r in 0 ..< BENCH_REPEATS {
				tputs[r] = size_info.run_1(workers, MESSAGE_COUNT)
			}
			median, lo, hi := summarize_f64(tputs)
			delete(tputs)

			label: string
			if workers == 1 {
				label = "1"
			} else {
				label = fmt.tprintf("%d", workers)
			}

			fmt.printf(
				"%-8s │ %-7s │ %8sM │ %s\n",
				size_info.name,
				label,
				fmt.tprintf("%.2f", median / 1_000_000),
				fmt_spread(median, lo, hi),
			)
		}
	}

	fmt.println()
}
