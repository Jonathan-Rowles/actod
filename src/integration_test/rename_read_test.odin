package integration

import "../actod"
import "core:sync"
import "core:testing"
import "core:time"

RENAME_READ_SHORT_NAME :: "torn-name-short"
RENAME_READ_LONG_NAME :: "torn-name-much-longer-than-the-short-one-so-a-mixed-header-reads-past-it"
RENAME_READ_RENAMES :: 100_000
RENAME_READ_BUDGET :: 10 * time.Second

Rename_Read_Step :: struct {}

Rename_Read_Probe :: struct {
	renames:  int,
	finished: bool,
}

rename_read_probe: Rename_Read_Probe

Rename_Read_Renamer :: struct {
	renames: int,
}

rename_read_renamer_behaviour := actod.Actor_Behaviour(Rename_Read_Renamer) {
	handle_message = proc(d: ^Rename_Read_Renamer, from: actod.PID, msg: any) {
		if _, ok := msg.(Rename_Read_Step); !ok do return
		if d.renames >= RENAME_READ_RENAMES {
			sync.atomic_store(&rename_read_probe.finished, true)
			return
		}
		next_name :=
			RENAME_READ_LONG_NAME if d.renames % 2 == 0 else RENAME_READ_SHORT_NAME
		if actod.self_rename(next_name) do d.renames += 1
		sync.atomic_store(&rename_read_probe.renames, d.renames)
		_ = actod.send_self(Rename_Read_Step{})
	},
}

is_assigned_rename_read_name :: proc(name: string) -> bool {
	return name == RENAME_READ_SHORT_NAME || name == RENAME_READ_LONG_NAME
}

test_get_actor_name_never_reads_a_torn_rename :: proc(t: ^testing.T) {
	rename_read_probe = {}

	pid, ok := actod.spawn(
		RENAME_READ_SHORT_NAME,
		Rename_Read_Renamer{},
		rename_read_renamer_behaviour,
	)
	if !expect(t, ok, "spawn the renamer") do return
	defer _ = actod.terminate_actor(pid)

	if !expect(t, actod.send_message(pid, Rename_Read_Step{}) == .OK, "start the renamer") do return

	reads, torn_reads: int
	first_torn_len := -1
	start := time.tick_now()
	budget := scaled_timeout(RENAME_READ_BUDGET)
	for !sync.atomic_load(&rename_read_probe.finished) &&
	    time.tick_since(start) < budget {
		name := actod.get_actor_name(pid)
		reads += 1
		if is_assigned_rename_read_name(name) do continue
		torn_reads += 1
		if first_torn_len < 0 do first_torn_len = len(name)
	}

	expectf(
		t,
		sync.atomic_load(&rename_read_probe.finished),
		"the renamer finished %d of %d renames within the budget",
		sync.atomic_load(&rename_read_probe.renames),
		RENAME_READ_RENAMES,
	)
	expectf(
		t,
		torn_reads == 0,
		"get_actor_name returned a name never assigned %d times in %d reads across %d renames (first had length %d)",
		torn_reads,
		reads,
		sync.atomic_load(&rename_read_probe.renames),
		first_torn_len,
	)
}
