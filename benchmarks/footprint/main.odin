package footprint

import "../../src/actod"
import "../../src/pkgs/threads_act/"
import "core:fmt"
import "core:os"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strconv"
import "core:time"

DEFAULT_ACTOR_COUNT :: 5000
SETTLE_TIME :: 300 * time.Millisecond
REAP_POLL_INTERVAL :: 2 * time.Millisecond
REAP_TIMEOUT :: 60 * time.Second

Idle :: struct {
	received: int,
}

idle_handle :: proc(data: ^Idle, from: actod.PID, content: any) {
	data.received += 1
}

Snapshot :: struct {
	rss_kb:     int,
	virtual_kb: int,
	vma_count:  int,
}

take_snapshot :: proc() -> Snapshot {
	return Snapshot {
		rss_kb = read_rss_kb(),
		virtual_kb = read_virtual_kb(),
		vma_count = read_vma_count(),
	}
}

per_actor :: proc(after: int, before: int, actors: int) -> f64 {
	if after < 0 || before < 0 || actors <= 0 do return 0
	return f64(after - before) / f64(actors)
}

live_actor_count :: proc() -> int {
	actors := actod.collect_actors()
	defer delete(actors)
	return len(actors)
}

slab_in_use :: proc() -> i64 {
	return actod.slot_slab_in_use(&actod.NODE.actor_slab) +
		actod.slot_slab_in_use(&actod.NODE.coro_slab)
}

wait_for_slab_release :: proc(target: i64) -> bool {
	start := time.now()
	for time.since(start) < REAP_TIMEOUT {
		if slab_in_use() <= target do return true
		time.sleep(REAP_POLL_INTERVAL)
	}
	return false
}

wait_for_reap :: proc(target: int) -> (elapsed: time.Duration, ok: bool) {
	start := time.now()
	for time.since(start) < REAP_TIMEOUT {
		if live_actor_count() <= target do return time.since(start), true
		time.sleep(REAP_POLL_INTERVAL)
	}
	return time.since(start), false
}

spawn_cohort :: proc(count: int, pids: ^[dynamic]actod.PID) -> (elapsed: time.Duration) {
	start := time.now()
	for i in 0 ..< count {
		name := fmt.tprintf("idle_%d", i)
		pid, ok := actod.spawn(
			name,
			Idle{},
			actod.Actor_Behaviour(Idle){handle_message = idle_handle},
		)
		if !ok {
			fmt.printf("spawn failed at actor %d of %d\n", i, count)
			break
		}
		append(pids, pid)
		free_all(context.temp_allocator)
	}
	return time.since(start)
}

terminate_cohort :: proc(pids: []actod.PID) -> (elapsed: time.Duration) {
	start := time.now()
	for pid in pids {
		_ = actod.terminate_actor(pid)
	}
	return time.since(start)
}

us_per :: proc(d: time.Duration, n: int) -> f64 {
	if n <= 0 do return 0
	return f64(time.duration_nanoseconds(d)) / f64(n) / 1000.0
}

env_int :: proc(name: string, fallback: int) -> int {
	if v, ok := os.lookup_env(name, context.allocator); ok {
		defer delete(v)
		if n, parse_ok := strconv.parse_int(v); parse_ok && n > 0 do return n
	}
	return fallback
}

main :: proc() {
	count := env_int("FOOTPRINT_ACTORS", DEFAULT_ACTOR_COUNT)

	print_provenance_header(count)

	registry_size := min(max(count * 4, 1024), actod.REGISTRY_MAX_CAPACITY)
	actod.node_init(
		name = "footprint",
		opts = actod.make_node_config(
			actor_registry_size = registry_size,
			enable_observer = false,
			actor_config = actod.make_actor_config(logging = actod.make_log_config(level = .Error)),
		),
	)

	baseline_live := live_actor_count()
	baseline_slab := slab_in_use()
	baseline := take_snapshot()

	pids := make([dynamic]actod.PID, 0, count)
	cold_spawn := spawn_cohort(count, &pids)
	n := len(pids)

	time.sleep(SETTLE_TIME)
	loaded := take_snapshot()

	fmt.println("--- idle footprint ---")
	fmt.printf("actors alive:       %d\n", n)
	if MEM_STATS_AVAILABLE {
		fmt.printf("RSS/actor:          %.2f KB\n", per_actor(loaded.rss_kb, baseline.rss_kb, n))
		fmt.printf("VMAs/actor:         %.3f\n", per_actor(loaded.vma_count, baseline.vma_count, n))
		fmt.printf(
			"virtual/actor:      %.2f MB\n",
			per_actor(loaded.virtual_kb, baseline.virtual_kb, n) / 1024.0,
		)
		fmt.printf("VMAs total:         %d\n", loaded.vma_count)
		print_slab_rss(n)
	} else {
		fmt.println("RSS/VMA stats:      unavailable on this platform")
	}
	print_arena_usage(n)
	print_coro_usage(n)
	if MEM_STATS_AVAILABLE do print_vma_breakdown(6)

	fmt.println()
	fmt.println("--- lifecycle cost ---")
	fmt.printf("cold spawn:         %.2f us/actor\n", us_per(cold_spawn, n))

	terminate_issue := terminate_cohort(pids[:])
	reap_elapsed, reaped := wait_for_reap(baseline_live)
	fmt.printf("terminate call:     %.2f us/actor\n", us_per(terminate_issue, n))
	if reaped {
		fmt.printf("reap to idle:       %.2f us/actor\n", us_per(reap_elapsed, n))
	} else {
		fmt.printf("reap to idle:       TIMED OUT after %v (%d still live)\n", reap_elapsed, live_actor_count())
	}

	slots_returned := wait_for_slab_release(baseline_slab)
	after_reap := take_snapshot()
	if !slots_returned {
		fmt.printf("slab slots not returned within timeout, residual below is not settled\n")
	}
	if MEM_STATS_AVAILABLE {
		fmt.printf(
			"RSS residual:       %.2f KB/actor\n",
			per_actor(after_reap.rss_kb, baseline.rss_kb, n),
		)
		fmt.printf(
			"VMA residual:       %.3f /actor\n",
			per_actor(after_reap.vma_count, baseline.vma_count, n),
		)
	}

	clear(&pids)
	warm_spawn := spawn_cohort(count, &pids)
	warm_n := len(pids)
	fmt.printf("warm respawn:       %.2f us/actor\n", us_per(warm_spawn, warm_n))

	_ = terminate_cohort(pids[:])
	_, _ = wait_for_reap(baseline_live)

	fmt.println()
	fmt.println("--- spawn scaling ---")
	fmt.printf(
		"serial spawn:       %.2f us/actor   %.0f actors/sec   (1 caller)\n",
		us_per(cold_spawn, n),
		per_second(n, cold_spawn),
	)
	run_concurrent_spawn(count, spawner_count(), baseline_live)

	actod.shutdown_node()
}

spawner_count :: proc() -> int {
	return env_int("FOOTPRINT_SPAWNERS", threads_act.get_cpu_count())
}

print_provenance_header :: proc(count: int) {
	fmt.println("=== actod footprint benchmark ===")
	fmt.printf("cores (logical):    %d\n", threads_act.get_cpu_count())
	fmt.printf("os/arch:            %v / %v\n", ODIN_OS, ODIN_ARCH)
	fmt.printf("odin version:       %v\n", ODIN_VERSION)
	fmt.printf("build:              -o:aggressive -no-bounds-check -disable-assert -microarch:native\n")
	fmt.printf("actors:             %d\n", count)
	fmt.printf("mailbox default:    %d slots\n", actod.DEFAULT_MAIL_BOX_SIZE)
	if mmc := read_max_map_count(); mmc > 0 do fmt.printf("vm.max_map_count:   %d\n", mmc)
	fmt.println()
}

print_slab_rss :: proc(actors: int) {
	if !MEM_STATS_AVAILABLE || actors <= 0 do return
	Slab_Line :: struct {
		prefix: string,
		memory: []byte,
	}
	slabs := [?]Slab_Line {
		{"  arena slab RSS:   ", actod.NODE.actor_slab.memory},
		{"  coro slab RSS:    ", actod.NODE.coro_slab.memory},
	}
	for slab in slabs {
		if len(slab.memory) > 0 {
			rss := read_mapping_rss_kb(uintptr(raw_data(slab.memory)), uint(len(slab.memory)))
			fmt.printf("%s%.2f KB/actor\n", slab.prefix, f64(rss) / f64(actors))
		}
	}
}

print_coro_usage :: proc(actors: int) {
	slab := &actod.NODE.coro_slab
	if !slab.enabled || actors <= 0 do return
	fmt.printf(
		"  coro slot size:   %d B (%d B header + stack), %d slots in use\n",
		slab.slot_size,
		actod.coro_header_bytes(),
		actod.slot_slab_in_use(slab),
	)
}

print_arena_usage :: proc(actors: int) {
	slab := &actod.NODE.actor_slab
	if !slab.enabled || actors <= 0 do return
	fmt.printf(
		"  arena slot size:  %d B reserved per actor (%d slots in use)\n",
		slab.slot_size,
		actod.slot_slab_in_use(slab),
	)

	total: uint
	sampled := 0
	for i in 0 ..< min(actors, int(slab.slot_count)) {
		block := cast(^vmem.Memory_Block)raw_data(actod.slot_slab_slot(slab, u32(i)))
		if block.used == 0 || block.used > slab.slot_size do continue
		total += block.used
		sampled += 1
	}
	if sampled > 0 {
		avg := total / uint(sampled)
		fmt.printf(
			"  arena bytes used: %d B/actor over %d slots = %d pages of %d B\n",
			avg,
			sampled,
			(avg + uint(mem.PAGE_SIZE) - 1) / uint(mem.PAGE_SIZE),
			mem.PAGE_SIZE,
		)
	}
}
