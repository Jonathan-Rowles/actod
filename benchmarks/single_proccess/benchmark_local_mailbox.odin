package benchmark

import "../../src/actod"
import "../shared"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:time"

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
	latency_ns: f64,
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

	receiver_behaviour := actod.Actor_Behaviour(Flood_Receiver_Data) {
		handle_message = proc(data: ^Flood_Receiver_Data, from: actod.PID, msg: any) {
			data.count += 1
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
	start := time.now()

	sync.sema_wait(&done_sema)
	elapsed := time.since(start)

	time.sleep(50 * time.Millisecond)

	actod.terminate_actor(sender)
	actod.terminate_actor(receiver)
	time.sleep(50 * time.Millisecond)

	actod.SHUTDOWN_NODE()

	duration_sec := time.duration_seconds(elapsed)
	throughput = f64(message_count) / duration_sec
	latency_ns = (duration_sec * 1e9) / f64(message_count)
	return
}

run_local_mailbox_benchmark :: proc() {
	MESSAGE_COUNT :: 1_000_000

	fmt.println("\n=== Local Mailbox Throughput (Actor-to-Actor) ===")
	fmt.println("Sender actor fires messages to receiver actor — no reply\n")

	fmt.println("Size     │ Workers │  Msgs/sec │ Latency")
	fmt.println(
		"─────────┼─────────┼───────────┼─────────",
	)

	for size_info in ([]struct {
			name:  string,
			size:  int,
			run_1: proc(_: int, _: int) -> (f64, f64),
			run_2: proc(_: int, _: int) -> (f64, f64),
		} {
			{
				name = "Empty",
				size = 0,
				run_1 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Empty_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Empty_Message,
					)},
			},
			{
				name = "32B",
				size = 32,
				run_1 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Inline_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Inline_Message,
					)},
			},
			{
				name = "256B",
				size = 256,
				run_1 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Medium_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Medium_Message,
					)},
			},
			{
				name = "1KB",
				size = 1024,
				run_1 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Large_Message,
					)},
				run_2 = proc(wc: int, mc: int) -> (f64, f64) {return run_local_throughput(
						wc,
						mc,
						shared.Large_Message,
					)},
			},
		}) {
		for workers in ([]int{1, 2}) {
			tput, lat := size_info.run_1(workers, MESSAGE_COUNT)

			label: string
			if workers == 1 {
				label = "1"
			} else {
				label = fmt.tprintf("%d", workers)
			}

			fmt.printf(
				"%-8s │ %-7s │ %8sM │ %5sns\n",
				size_info.name,
				label,
				fmt.tprintf("%.2f", tput / 1_000_000),
				fmt.tprintf("%.0f", lat),
			)
		}
	}

	fmt.println()
}
