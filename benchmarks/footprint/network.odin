package footprint

import "../../src/actod"
import "core:encoding/endian"
import "core:fmt"
import "core:sync"
import "core:time"

DEFAULT_RING_COUNT :: 8

run_ring_footprint :: proc() {
	count := env_int("FOOTPRINT_RINGS", DEFAULT_RING_COUNT)
	if count <= 0 do return

	config := actod.DEFAULT_CONNECTION_RING_CONFIG

	fmt.println("--- connection ring footprint ---")
	fmt.printf(
		"geometry:           %d x %d KB send slots + %d KB recv buffer\n",
		config.send_slot_count,
		config.send_slot_size / 1024,
		config.recv_buffer_size / 1024,
	)

	before := take_snapshot()
	rings := make([dynamic]^actod.Connection_Ring, 0, count)
	defer delete(rings)

	first: time.Duration
	total: time.Duration
	for i in 0 ..< count {
		start := time.now()
		ring := actod.make_connection_ring(config)
		elapsed := time.since(start)
		if ring == nil {
			fmt.printf("ring creation failed at %d of %d\n", i, count)
			break
		}
		append(&rings, ring)
		if i == 0 do first = elapsed
		total += elapsed
	}
	n := len(rings)
	if n == 0 do return

	time.sleep(SETTLE_TIME)
	after := take_snapshot()

	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS/ring:           %.2f MB\n",
			per_actor(after.rss_kb, before.rss_kb, n) / 1024.0,
		)
		fmt.printf(
			"virtual/ring:       %.2f MB\n",
			per_actor(after.virtual_kb, before.virtual_kb, n) / 1024.0,
		)
		fmt.printf("VMAs/ring:          %.2f\n", per_actor(after.vma_count, before.vma_count, n))
	}
	fmt.printf(
		"arm latency:        first %.2f ms, mean %.2f ms over %d rings\n",
		f64(time.duration_nanoseconds(first)) / 1e6,
		f64(time.duration_nanoseconds(total)) / f64(n) / 1e6,
		n,
	)

	for ring in rings {
		for &b in ring.send_data_buffer do b = 1
		for &b in ring.recv_buffer do b = 1
	}
	time.sleep(SETTLE_TIME)
	hot := take_snapshot()
	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS/ring hot:       %.2f MB (all slots and recv touched once)\n",
			per_actor(hot.rss_kb, before.rss_kb, n) / 1024.0,
		)
	}

	drain_ready :: proc(ring: ^actod.Connection_Ring) {
		write_idx := sync.atomic_load(&ring.send_write_idx)
		for ring.send_submit_idx < write_idx {
			slot := &ring.send_slots[ring.send_submit_idx & ring.send_mask]
			if sync.atomic_load(&slot.state) != .READY do break
			slot.length = 0
			sync.atomic_store(&slot.state, actod.Send_Slot_State.FREE)
			ring.send_submit_idx += 1
			sync.atomic_add(&ring.send_complete_idx, 1)
		}
	}

	for ring in rings do _ = actod.ring_decommit_buffers(ring)
	for ring in rings do _ = actod.ring_commit_buffers(ring)
	heartbeat: [24]byte
	endian.put_u32(heartbeat[0:4], .Little, 20)
	for ring in rings {
		for _ in 0 ..< 2 * int(config.send_slot_count) {
			_ = actod.batch_append_message(ring, heartbeat[:])
			actod.batch_flush(ring)
			drain_ready(ring)
		}
	}
	time.sleep(SETTLE_TIME)
	idle := take_snapshot()
	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS/ring idle:      %.2f MB (two full laps of heartbeat-sized frames)\n",
			per_actor(idle.rss_kb, before.rss_kb, n) / 1024.0,
		)
	}

	for ring in rings do _ = actod.ring_trim_send_buffer(ring)
	time.sleep(SETTLE_TIME)
	trimmed := take_snapshot()
	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS/ring trimmed:   %.2f MB (idle send buffer returned, recv backlog kept)\n",
			per_actor(trimmed.rss_kb, before.rss_kb, n) / 1024.0,
		)
	}

	park_start := time.now()
	for ring in rings do _ = actod.ring_decommit_buffers(ring)
	park_elapsed := time.since(park_start)
	time.sleep(SETTLE_TIME)
	parked := take_snapshot()
	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS/ring parked:    %.2f MB (decommitted on park, %.2f ms over %d rings)\n",
			per_actor(parked.rss_kb, before.rss_kb, n) / 1024.0,
			f64(time.duration_nanoseconds(park_elapsed)) / 1e6,
			n,
		)
	}

	unpark_start := time.now()
	for ring in rings do _ = actod.ring_commit_buffers(ring)
	unpark_elapsed := time.since(unpark_start)
	for ring in rings {
		for &b in ring.send_data_buffer do b = 1
		for &b in ring.recv_buffer do b = 1
	}
	time.sleep(SETTLE_TIME)
	rewarmed := take_snapshot()
	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS/ring rewarmed:  %.2f MB (recommit %.2f ms over %d rings, then all pages touched)\n",
			per_actor(rewarmed.rss_kb, before.rss_kb, n) / 1024.0,
			f64(time.duration_nanoseconds(unpark_elapsed)) / 1e6,
			n,
		)
	}

	destroy_start := time.now()
	for ring in rings do actod.destroy_connection_ring(ring)
	fmt.printf(
		"destroy:            %.2f ms over %d rings\n",
		f64(time.duration_nanoseconds(time.since(destroy_start))) / 1e6,
		n,
	)
	fmt.println()
}
