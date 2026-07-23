package integration

import "../actod"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

LEAK_TEST_ROUNDS :: 80
LEAK_TEST_BATCH :: 8
MASS_DEATH_CHILDREN :: 40

#assert(size_of(actod.Actor_Stopped) > actod.INLINE_MESSAGE_SIZE)

@(private = "file")
reaped_by_supervisor: int

@(private = "file")
fail_hard :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

Leak_Supervisor_Data :: struct {
	id: int,
}

Leak_Supervisor_Behaviour :: actod.Actor_Behaviour(Leak_Supervisor_Data) {
	handle_message      = leak_supervisor_handle_message,
	on_child_terminated = leak_supervisor_on_child_terminated,
}

leak_supervisor_handle_message :: proc(data: ^Leak_Supervisor_Data, from: actod.PID, msg: any) {
	if text, ok := msg.(string); ok && text == "block" {
		time.sleep(400 * time.Millisecond)
	}
}

leak_supervisor_on_child_terminated :: proc(
	data: ^Leak_Supervisor_Data,
	child_pid: actod.PID,
	reason: actod.Termination_Reason,
	will_restart: bool,
) {
	sync.atomic_add(&reaped_by_supervisor, 1)
}

test_supervisor_survives_many_child_terminations :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&reaped_by_supervisor, 0)

	supervisor_pid, ok := actod.spawn(
		"leak-probe-supervisor",
		Leak_Supervisor_Data{id = 11},
		Leak_Supervisor_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .TEMPORARY,
			page_size = 1024,
		),
	)
	if !ok {
		fail_hard("failed to spawn supervisor")
	}

	for round in 0 ..< LEAK_TEST_ROUNDS {
		for _ in 0 ..< LEAK_TEST_BATCH {
			if _, added := actod.add_child(supervisor_pid, create_crash_child(0)); !added {
				fail_hard("failed to add child in round %d", round)
			}
		}
		if !wait_for_child_count(supervisor_pid, LEAK_TEST_BATCH, 2000) {
			fail_hard("children were not registered in round %d", round)
		}

		children := actod.get_children(supervisor_pid)
		for child in children {
			actod.send_message(child, actod.Terminate{reason = .NORMAL})
		}
		delete(children)

		if !wait_for_child_count(supervisor_pid, 0, 2000) {
			fail_hard(
				"supervisor stopped reaping children after %d terminations, its message pool is exhausted",
				round * LEAK_TEST_BATCH,
			)
		}
	}

	expected := LEAK_TEST_ROUNDS * LEAK_TEST_BATCH
	for _ in 0 ..< 200 {
		if sync.atomic_load(&reaped_by_supervisor) >= expected do break
		time.sleep(10 * time.Millisecond)
	}

	reaped := sync.atomic_load(&reaped_by_supervisor)
	if reaped != expected {
		fail_hard("supervisor processed only %d of %d Actor_Stopped messages", reaped, expected)
	}

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}

test_mass_simultaneous_child_deaths :: proc(t: ^testing.T) {
	reset_test_state()
	sync.atomic_store(&reaped_by_supervisor, 0)

	supervisor_pid, ok := actod.spawn(
		"mass-death-supervisor",
		Leak_Supervisor_Data{id = 12},
		Leak_Supervisor_Behaviour,
		actod.make_actor_config(
			supervision_strategy = .ONE_FOR_ONE,
			restart_policy = .TEMPORARY,
		),
	)
	expect(t, ok, "Failed to spawn supervisor")
	if !ok do return

	for _ in 0 ..< MASS_DEATH_CHILDREN {
		added := false
		for _ in 0 ..< 200 {
			if _, add_ok := actod.add_child(supervisor_pid, create_crash_child(0)); add_ok {
				added = true
				break
			}
			time.sleep(5 * time.Millisecond)
		}
		if !added do fail_hard("failed to add child after retries")
	}
	expect(
		t,
		wait_for_child_count(supervisor_pid, MASS_DEATH_CHILDREN, 3000),
		"All children should be registered",
	)

	children := actod.get_children(supervisor_pid)
	defer delete(children)
	if !expectf(
		t,
		len(children) == MASS_DEATH_CHILDREN,
		"expected %d children, got %d",
		MASS_DEATH_CHILDREN,
		len(children),
	) {
		return
	}

	actod.send_message(supervisor_pid, "block")
	time.sleep(50 * time.Millisecond)

	for child in children {
		actod.send_message(child, actod.Terminate{reason = .NORMAL})
	}

	converged := wait_for_child_count(supervisor_pid, 0, 5000)
	reaped := sync.atomic_load(&reaped_by_supervisor)

	expectf(
		t,
		converged,
		"supervisor must reap every child even when %d die at once, %d Actor_Stopped were lost",
		MASS_DEATH_CHILDREN,
		MASS_DEATH_CHILDREN - reaped,
	)
	expectf(
		t,
		reaped == MASS_DEATH_CHILDREN,
		"on_child_terminated must fire once per child, got %d of %d",
		reaped,
		MASS_DEATH_CHILDREN,
	)

	actod.send_message(supervisor_pid, actod.Terminate{reason = .NORMAL})
}
