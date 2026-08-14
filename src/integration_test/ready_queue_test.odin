package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

READY_QUEUE_TEST_WORKERS :: 4
READY_QUEUE_TEST_ACTORS :: 512 * READY_QUEUE_TEST_WORKERS + 600
READY_QUEUE_BLOCK :: 800 * time.Millisecond
READY_QUEUE_WAIT :: 30 * time.Second
READY_QUEUE_POLL :: 5 * time.Millisecond

ready_queue_received: int
ready_queue_blockers_done: int

Ready_Queue_Probe :: struct {
	id: int,
}

ready_queue_behaviour := actod.Actor_Behaviour(Ready_Queue_Probe) {
	handle_message = proc(data: ^Ready_Queue_Probe, from: actod.PID, msg: any) {
		if _, ok := msg.(u64); ok {
			sync.atomic_add(&ready_queue_received, 1)
		}
	},
}

Ready_Queue_Blocker :: struct {
	worker: int,
}

ready_queue_blocker_behaviour := actod.Actor_Behaviour(Ready_Queue_Blocker) {
	handle_message = proc(data: ^Ready_Queue_Blocker, from: actod.PID, msg: any) {
		if _, ok := msg.(u64); ok {
			time.sleep(READY_QUEUE_BLOCK)
			sync.atomic_add(&ready_queue_blockers_done, 1)
		}
	},
}

test_all_actors_run_when_woken_at_once :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&ready_queue_received, 0)
	sync.atomic_store(&ready_queue_blockers_done, 0)

	pids := make([dynamic]actod.PID, 0, READY_QUEUE_TEST_ACTORS)
	defer delete(pids)

	for i in 0 ..< READY_QUEUE_TEST_ACTORS {
		pid, spawned := actod.spawn(
			"ready-queue-probe",
			Ready_Queue_Probe{id = i},
			ready_queue_behaviour,
		)
		expectf(t, spawned, "failed to spawn probe %d", i)
		if !spawned {
			return
		}
		append(&pids, pid)
	}

	blockers := make([dynamic]actod.PID, 0, READY_QUEUE_TEST_WORKERS)
	defer delete(blockers)

	for w in 0 ..< READY_QUEUE_TEST_WORKERS {
		pid, spawned := actod.spawn(
			"ready-queue-blocker",
			Ready_Queue_Blocker{worker = w},
			ready_queue_blocker_behaviour,
			actod.make_actor_config(home_worker = w),
		)
		expectf(t, spawned, "failed to spawn blocker for worker %d", w)
		if !spawned {
			return
		}
		append(&blockers, pid)
	}

	for pid in blockers {
		expect(t, actod.send_message(pid, u64(1)) == .OK, "failed to occupy a worker")
	}
	time.sleep(50 * time.Millisecond)

	delivered := 0
	for pid in pids {
		if actod.send_message(pid, u64(1)) == .OK {
			delivered += 1
		}
	}

	expectf(
		t,
		delivered == len(pids),
		"every send should be accepted, %d of %d were",
		delivered,
		len(pids),
	)

	start := time.tick_now()
	for time.tick_since(start) < READY_QUEUE_WAIT {
		if sync.atomic_load(&ready_queue_received) >= delivered {
			break
		}
		time.sleep(READY_QUEUE_POLL)
	}

	expectf(
		t,
		sync.atomic_load(&ready_queue_received) == delivered,
		"waking %d actors while every worker is busy must still schedule all of them, %d never ran",
		delivered,
		delivered - sync.atomic_load(&ready_queue_received),
	)

	for pid in blockers {
		_ = actod.terminate_actor(pid)
	}
	for pid in pids {
		_ = actod.terminate_actor(pid)
	}
}
