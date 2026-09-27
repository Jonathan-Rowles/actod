package integration

import "../actod"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Shutdown_Probe :: struct {
	seen: int,
}

shutdown_probe_behaviour := actod.Actor_Behaviour(Shutdown_Probe) {
	handle_message = proc(d: ^Shutdown_Probe, from: actod.PID, msg: any) {
		d.seen += 1
	},
}

Pinned_Sender :: struct {
	pid:       actod.PID,
	actor_ptr: rawptr,
	pinned:    sync.Sema,
	release:   sync.Sema,
}

pinned_sender_proc :: proc(data: rawptr) {
	sender := cast(^Pinned_Sender)data
	actod.reclaim_pin()
	sender.actor_ptr, _ = actod.get(&actod.NODE.actor_registry, sender.pid)
	sync.sema_post(&sender.pinned)
	sync.sema_wait(&sender.release)
	actod.reclaim_unpin()
}

shutdown_node_proc :: proc(data: rawptr) {
	done := cast(^bool)data
	actod.shutdown_node()
	sync.atomic_store(done, true)
}

retired_actor_count :: proc() -> int {
	sync.mutex_lock(&actod.NODE.reclaim.retire_mutex)
	defer sync.mutex_unlock(&actod.NODE.reclaim.retire_mutex)
	return len(actod.NODE.reclaim.retire_list)
}

retire_list_nonempty :: proc(_: rawptr) -> bool {
	return retired_actor_count() > 0
}

test_shutdown_waits_for_pinned_sender :: proc(t: ^testing.T) {
	pid, ok := actod.spawn("pinned_target", Shutdown_Probe{}, shutdown_probe_behaviour)
	if !expect(t, ok, "spawn pinned_target") do return

	sender := Pinned_Sender {
		pid = pid,
	}
	sender_thread := thread.create_and_start_with_data(&sender, pinned_sender_proc)
	sync.sema_wait(&sender.pinned)
	if !expect(t, sender.actor_ptr != nil, "the pinned sender read the actor pointer") do return

	expect(t, actod.terminate_actor(pid, .SHUTDOWN), "terminate pinned_target")
	expect(
		t,
		poll_until(retire_list_nonempty, nil, 2 * time.Second),
		"the terminated actor was retired behind the pin",
	)

	shutdown_done: bool
	shutdown_thread := thread.create_and_start_with_data(&shutdown_done, shutdown_node_proc)

	time.sleep(scaled_timeout(500 * time.Millisecond))
	expect(
		t,
		!sync.atomic_load(&shutdown_done),
		"shutdown returned while a sender still pinned a retired actor",
	)
	expectf(
		t,
		retired_actor_count() > 0,
		"the retire list was drained under a live pin (%d entries left)",
		retired_actor_count(),
	)
	pinned_actor := cast(^actod.Actor)sender.actor_ptr
	expect_value(t, pinned_actor.pid, pid)

	sync.sema_post(&sender.release)
	thread.join(sender_thread)
	thread.destroy(sender_thread)

	expect(
		t,
		poll_until(atomic_flag_raised, &shutdown_done, 5 * time.Second),
		"shutdown completed once the pin was released",
	)
	thread.join(shutdown_thread)
	thread.destroy(shutdown_thread)

	expect(t, !actod.NODE.started, "the node is stopped after shutdown")
	expect_value(t, actod.NODE.shutdown_leaked_actors, 0)
	expect_value(t, retired_actor_count(), 0)
}

Sleepy_Actor :: struct {}

Sleepy_Nap :: struct {}

SLEEPY_HANDLER_WALL_CLOCK_UNSCALED :: 7 * time.Second
REMOVED_SHUTDOWN_CAPS_EXPIRED_WALL_CLOCK_UNSCALED :: 6500 * time.Millisecond
STUCK_REPORTS_EXPECTED_BEFORE_REMOVED_CAPS_EXPIRED :: 6

sleepy_handler_entered: bool

sleepy_behaviour := actod.Actor_Behaviour(Sleepy_Actor) {
	handle_message = proc(d: ^Sleepy_Actor, from: actod.PID, msg: any) {
		if _, ok := msg.(Sleepy_Nap); !ok do return
		sync.atomic_store(&sleepy_handler_entered, true)
		time.sleep(SLEEPY_HANDLER_WALL_CLOCK_UNSCALED)
	},
}

stuck_report_count: int
node_logger_before_wrap: log.Logger

counting_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location: runtime.Source_Code_Location,
) {
	if strings.contains(text, "shutdown is waiting for") do sync.atomic_add(&stuck_report_count, 1)
	inner := cast(^log.Logger)data
	inner.procedure(inner.data, level, text, options, location)
}

count_shutdown_stuck_reports :: proc() {
	sync.atomic_store(&stuck_report_count, 0)
	node_logger_before_wrap = actod.NODE.logger
	actod.NODE.logger = log.Logger {
		procedure    = counting_logger_proc,
		data         = &node_logger_before_wrap,
		lowest_level = .Warning,
		options      = node_logger_before_wrap.options,
	}
}

test_shutdown_waits_for_stuck_actor :: proc(t: ^testing.T) {
	pid, ok := actod.spawn(
		"sleepy",
		Sleepy_Actor{},
		sleepy_behaviour,
		actod.make_actor_config(use_dedicated_os_thread = true),
	)
	if !expect(t, ok, "spawn sleepy") do return

	sync.atomic_store(&sleepy_handler_entered, false)
	expect_value(t, actod.send_message(pid, Sleepy_Nap{}), actod.Send_Error.OK)
	handler_entered := poll_until(atomic_flag_raised, &sleepy_handler_entered, 5 * time.Second)
	if !expect(t, handler_entered, "the sleepy handler was entered before shutdown began") do return

	count_shutdown_stuck_reports()

	shutdown_done: bool
	shutdown_thread := thread.create_and_start_with_data(&shutdown_done, shutdown_node_proc)

	time.sleep(REMOVED_SHUTDOWN_CAPS_EXPIRED_WALL_CLOCK_UNSCALED)
	expect(
		t,
		!sync.atomic_load(&shutdown_done),
		"shutdown returned while an actor was still inside its handler",
	)
	expectf(
		t,
		sync.atomic_load(&stuck_report_count) >= STUCK_REPORTS_EXPECTED_BEFORE_REMOVED_CAPS_EXPIRED,
		"shutdown logged %d stuck-actor reports in 6.5 s, wanted at least %d",
		sync.atomic_load(&stuck_report_count),
		STUCK_REPORTS_EXPECTED_BEFORE_REMOVED_CAPS_EXPIRED,
	)

	expect(
		t,
		poll_until(
			atomic_flag_raised,
			&shutdown_done,
			SLEEPY_HANDLER_WALL_CLOCK_UNSCALED + 5 * time.Second,
		),
		"shutdown completed once the handler returned",
	)
	thread.join(shutdown_thread)
	thread.destroy(shutdown_thread)

	expect(t, !actod.NODE.started, "the node is stopped after shutdown")
	expect_value(t, actod.NODE.shutdown_leaked_actors, 0)
}
