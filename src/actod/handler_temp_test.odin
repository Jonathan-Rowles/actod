package actod

import "../../test_harness/ti"
import "../pkgs/coro"
import "base:runtime"
import "core:sync"
import "core:testing"

HANDLER_TEMP_TEST_BYTES :: 1024
HANDLER_TEMP_TEST_MESSAGES :: 8
HANDLER_TEMP_TEST_CHILD :: PID(0x7001)
HANDLER_TEMP_TEST_PARENT :: PID(0x7002)

@(private = "file", thread_local)
g_entry_used: [HANDLER_TEMP_TEST_MESSAGES]uint

@(private = "file", thread_local)
g_entries: int

@(private = "file", thread_local)
g_held: []byte

@(private = "file", thread_local)
g_held_intact_on_resume: bool

@(private = "file", thread_local)
g_suspended_kept_running: bool

@(private = "file")
Note :: struct {
	n: int,
}

@(private = "file")
Loop_Fixture :: struct {
	actor:          ^Actor,
	actor_ctx:      ^Actor_Context,
	mailbox:        []Entry(Message),
	system_mailbox: []Entry(Message),
	msg_ctx:        Message_Processing_Context,
}

@(private = "file")
temp_used :: proc() -> uint {
	return runtime.global_default_temp_allocator_data.arena.total_used
}

@(private = "file")
give_the_temp_arena_a_block :: proc() -> uint {
	_ = make([]byte, 16, context.temp_allocator)
	g_entries = 0
	g_entry_used = {}
	return temp_used()
}

@(private = "file")
note_entry_and_eat_temp :: proc() {
	if g_entries < len(g_entry_used) do g_entry_used[g_entries] = temp_used()
	g_entries += 1
	_ = make([]byte, HANDLER_TEMP_TEST_BYTES, context.temp_allocator)
}

@(private = "file")
eat_temp_on_a_message :: proc(data: rawptr, from: PID, content: any) {
	note_entry_and_eat_temp()
}

@(private = "file")
eat_temp_on_idle :: proc(data: rawptr) {
	note_entry_and_eat_temp()
}

@(private = "file")
eat_temp_on_a_child_ending :: proc(
	data: rawptr,
	child_pid: PID,
	child_name: string,
	reason: Termination_Reason,
	will_restart: bool,
) {
	note_entry_and_eat_temp()
}

@(private = "file")
hold_temp_across_a_yield :: proc(data: rawptr, from: PID, content: any) {
	g_held = make([]byte, HANDLER_TEMP_TEST_BYTES, context.temp_allocator)
	for &b in g_held do b = 0x11
	coro.yield(coro.running())
	g_held_intact_on_resume = all_bytes_are(g_held, 0x11)
}

@(private = "file")
all_bytes_are :: proc(data: []byte, want: byte) -> bool {
	for b in data do if b != want do return false
	return true
}

@(private = "file")
make_loop_fixture :: proc(
	handle_message: proc(data: rawptr, from: PID, content: any),
) -> ^Loop_Fixture {
	f := new(Loop_Fixture)
	f.actor = new(Actor)
	f.actor_ctx = new(Actor_Context)
	f.actor.actor_ctx = f.actor_ctx
	f.actor.pid = HANDLER_TEMP_TEST_PARENT
	f.actor.state = .RUNNING
	f.actor.allocator = context.allocator
	f.actor.handle_message = handle_message
	f.actor.children = make([dynamic]Supervised_Child)
	f.mailbox = make([]Entry(Message), HANDLER_TEMP_TEST_MESSAGES)
	f.system_mailbox = make([]Entry(Message), HANDLER_TEMP_TEST_MESSAGES)
	mpsc_init_external(&f.actor.mailbox, f.mailbox, entries_zeroed = true)
	mpsc_init_external(
		&f.actor.system_mailbox,
		f.system_mailbox,
		entries_zeroed = true,
	)
	pool_init(&f.actor.pool, context.allocator)
	f.msg_ctx = message_processing_context_init(f.actor, context.allocator)
	return f
}

@(private = "file")
destroy_loop_fixture :: proc(f: ^Loop_Fixture) {
	free(raw_data(f.msg_ctx.message_batch))
	free(raw_data(f.msg_ctx.free_buffer.entries))
	if f.actor.local_buf != nil do free(f.actor.local_buf)
	cleanup_pool(&f.actor.pool)
	delete(f.actor.children)
	delete(f.mailbox)
	delete(f.system_mailbox)
	free(f.actor_ctx)
	free(f.actor)
	free(f)
}

@(private = "file")
inline_message :: proc(content: $T) -> Message {
	msg := Message {
		inline_type = typeid_of(T),
	}
	data := content
	runtime.mem_copy_non_overlapping(&msg.inline_data[0], &data, size_of(T))
	return msg
}

@(private = "file")
push_local :: proc(f: ^Loop_Fixture, msg: Message) {
	ensure_local_buf(f.actor)
	f.actor.local_buf[f.actor.local_write & (LOCAL_MAILBOX_SIZE - 1)] = msg
	f.actor.local_write += 1
}

@(private = "file")
expect_every_entry_at :: proc(
	t: ^testing.T,
	want: uint,
	count: int,
	loc := #caller_location,
) {
	testing.expect_value(t, g_entries, count, loc = loc)
	for used, n in g_entry_used[:min(count, len(g_entry_used))] {
		testing.expectf(
			t,
			used == want,
			"handler %d found the temp arena at %d B, want %d B",
			n,
			used,
			want,
			loc = loc,
		)
	}
}

@(test)
test_messages_from_the_local_ring_leave_the_temp_arena_where_they_found_it :: proc(
	t: ^testing.T,
) {
	f := make_loop_fixture(eat_temp_on_a_message)
	defer destroy_loop_fixture(f)
	before := give_the_temp_arena_a_block()

	for n in 0 ..< HANDLER_TEMP_TEST_MESSAGES do push_local(f, inline_message(Note{n = n}))
	testing.expect(
		t,
		process_user_mailboxes(f.actor, &f.msg_ctx),
		"the actor must keep running",
	)

	expect_every_entry_at(t, before, HANDLER_TEMP_TEST_MESSAGES)
	testing.expect_value(t, temp_used(), before)
}

@(test)
test_messages_from_the_mailbox_leave_the_temp_arena_where_they_found_it :: proc(
	t: ^testing.T,
) {
	f := make_loop_fixture(eat_temp_on_a_message)
	defer destroy_loop_fixture(f)
	before := give_the_temp_arena_a_block()

	for n in 0 ..< HANDLER_TEMP_TEST_MESSAGES / 2 {
		testing.expect(
			t,
			mpsc_push(&f.actor.mailbox, inline_message(Note{n = n})),
			"the note must fit the mailbox",
		)
	}
	for n in 0 ..< HANDLER_TEMP_TEST_MESSAGES / 2 {
		testing.expect(
			t,
			mpsc_push(
				&f.actor.mailbox,
				inline_message(Timer_Tick{id = u32(n)}),
			),
			"the tick must fit the mailbox",
		)
	}
	testing.expect(
		t,
		process_user_mailboxes(f.actor, &f.msg_ctx),
		"the actor must keep running",
	)

	expect_every_entry_at(t, before, HANDLER_TEMP_TEST_MESSAGES)
	testing.expect_value(t, temp_used(), before)
}

@(test)
test_system_messages_and_stop_signals_leave_the_temp_arena_where_they_found_it :: proc(
	t: ^testing.T,
) {
	sync.lock(&global_registry_swap_mutex)
	defer sync.unlock(&global_registry_swap_mutex)
	f := make_loop_fixture(eat_temp_on_a_message)
	defer destroy_loop_fixture(f)
	f.actor.behaviour.on_child_terminated = eat_temp_on_a_child_ending
	before := give_the_temp_arena_a_block()

	record_direct_child(f.actor, HANDLER_TEMP_TEST_CHILD)
	intercept := ti.Test_Intercept {
		self_pid = u64(HANDLER_TEMP_TEST_CHILD),
	}
	ti.test_intercept = &intercept
	sent := send(
		f.actor.pid,
		Actor_Stopped {
			reason = .NORMAL,
			restart_policy = .TEMPORARY,
			child_name = "child",
			child_index = -1,
		},
		f.actor,
	)
	ti.test_intercept = nil
	testing.expect_value(t, sent, Send_Error.OK)
	testing.expect(
		t,
		process_system_mailbox(f.actor, &f.msg_ctx),
		"the actor must keep running",
	)

	child := new(Actor)
	defer free(child)
	child.opts.restart_policy = .TEMPORARY
	child.stop_signal.pid = HANDLER_TEMP_TEST_CHILD
	child.stop_signal.reason = .NORMAL
	record_direct_child(f.actor, HANDLER_TEMP_TEST_CHILD)
	push_stop_signal(f.actor, child)
	process_stop_signals(f.actor)

	expect_every_entry_at(t, before, 2)
	testing.expect_value(t, len(f.actor.children), 0)
	testing.expect_value(t, temp_used(), before)
}

@(test)
test_an_idle_hook_leaves_the_temp_arena_where_it_found_it :: proc(
	t: ^testing.T,
) {
	f := make_loop_fixture(eat_temp_on_a_message)
	defer destroy_loop_fixture(f)
	f.actor.behaviour.on_idle = eat_temp_on_idle
	before := give_the_temp_arena_a_block()

	for _ in 0 ..< HANDLER_TEMP_TEST_MESSAGES do wait_for_messages_if_idle(f.actor, &f.msg_ctx)

	expect_every_entry_at(t, before, HANDLER_TEMP_TEST_MESSAGES)
	testing.expect_value(t, temp_used(), before)
}

@(test)
test_a_handler_suspended_mid_message_keeps_its_temp_memory_while_another_runs :: proc(
	t: ^testing.T,
) {
	suspended := make_loop_fixture(hold_temp_across_a_yield)
	defer destroy_loop_fixture(suspended)
	other := make_loop_fixture(eat_temp_on_a_message)
	defer destroy_loop_fixture(other)
	before := give_the_temp_arena_a_block()
	g_held = nil
	g_held_intact_on_resume = false
	g_suspended_kept_running = false

	desc := coro.desc_init(proc(co: ^coro.Coro) {
		f := cast(^Loop_Fixture)coro.get_user_data(co)
		g_suspended_kept_running = process_user_mailboxes(f.actor, &f.msg_ctx)
	})
	desc.user_data = suspended
	co, created := coro.create(&desc)
	if !testing.expect_value(t, created, coro.Result.Success) do return
	defer coro.destroy(co)

	push_local(suspended, inline_message(Note{n = 0}))
	testing.expect_value(t, coro.resume(co), coro.Result.Success)
	if !testing.expect_value(t, coro.status(co), coro.State.Suspended) do return

	for n in 0 ..< HANDLER_TEMP_TEST_MESSAGES do push_local(other, inline_message(Note{n = n}))
	testing.expect(
		t,
		process_user_mailboxes(other.actor, &other.msg_ctx),
		"the other actor must keep running",
	)
	testing.expect(
		t,
		all_bytes_are(g_held, 0x11),
		"another actor's message freed the temp memory of a handler suspended mid-message",
	)

	testing.expect_value(t, coro.resume(co), coro.Result.Success)
	testing.expect_value(t, coro.status(co), coro.State.Dead)
	testing.expect(
		t,
		g_suspended_kept_running,
		"the suspended actor must keep running",
	)
	testing.expect(
		t,
		g_held_intact_on_resume,
		"the suspended handler found its temp memory changed when it resumed",
	)
	testing.expect_value(t, temp_used(), before)
}

HANDLER_TEMP_TEST_BLOCK :: 4096

@(private = "file")
take_bytes :: proc(arena: ^runtime.Arena, size: uint, fill: u8) -> []byte {
	data, err := runtime.arena_alloc(arena, size, 16)
	assert(err == nil)
	for &b in data do b = fill
	return data
}

@(private = "file")
all_zero :: proc(data: []byte) -> bool {
	for b in data do if b != 0 do return false
	return true
}

@(test)
test_rewind_in_one_block_frees_and_zeroes_what_came_after_the_mark :: proc(
	t: ^testing.T,
) {
	arena: runtime.Arena
	arena.minimum_block_size = HANDLER_TEMP_TEST_BLOCK
	defer runtime.arena_destroy(&arena)

	kept := take_bytes(&arena, 64, 0xAA)
	mark := temp_arena_mark(&arena)
	freed := take_bytes(&arena, 128, 0xBB)

	rewind_temp_arena(mark)

	testing.expect_value(t, arena.total_used, mark.total_used)
	testing.expect_value(t, arena.curr_block.used, mark.used)
	testing.expect(
		t,
		kept[0] == 0xAA && kept[63] == 0xAA,
		"memory before the mark was touched",
	)
	testing.expect(
		t,
		all_zero(freed),
		"freed temp memory was not zeroed for the next allocation",
	)
}

@(test)
test_rewind_across_blocks_frees_the_newer_blocks_and_restores_the_total :: proc(
	t: ^testing.T,
) {
	arena: runtime.Arena
	arena.minimum_block_size = HANDLER_TEMP_TEST_BLOCK
	defer runtime.arena_destroy(&arena)

	_ = take_bytes(&arena, 64, 0xAA)
	mark := temp_arena_mark(&arena)
	capacity_at_mark := arena.total_capacity
	_ = take_bytes(&arena, HANDLER_TEMP_TEST_BLOCK, 0xBB)
	_ = take_bytes(&arena, HANDLER_TEMP_TEST_BLOCK, 0xCC)
	testing.expect(
		t,
		arena.curr_block != mark.block,
		"the test did not open a new block",
	)

	rewind_temp_arena(mark)

	testing.expect(
		t,
		arena.curr_block == mark.block,
		"the newer blocks were kept",
	)
	testing.expect_value(t, arena.total_used, mark.total_used)
	testing.expect_value(t, arena.total_capacity, capacity_at_mark)
}

@(test)
test_rewind_to_a_mark_taken_before_any_block_empties_the_arena :: proc(
	t: ^testing.T,
) {
	arena: runtime.Arena
	arena.minimum_block_size = HANDLER_TEMP_TEST_BLOCK
	defer runtime.arena_destroy(&arena)

	mark := temp_arena_mark(&arena)
	freed := take_bytes(&arena, 256, 0xBB)

	rewind_temp_arena(mark)

	testing.expect_value(t, arena.total_used, 0)
	testing.expect(
		t,
		all_zero(freed),
		"freed temp memory was not zeroed for the next allocation",
	)
}

@(test)
test_rewind_leaves_an_arena_freed_below_its_mark_alone :: proc(t: ^testing.T) {
	arena: runtime.Arena
	arena.minimum_block_size = HANDLER_TEMP_TEST_BLOCK
	defer runtime.arena_destroy(&arena)

	_ = take_bytes(&arena, 64, 0xAA)
	mark := temp_arena_mark(&arena)
	runtime.arena_free_all(&arena)
	after := take_bytes(&arena, 16, 0xCC)

	rewind_temp_arena(mark)

	testing.expect_value(t, arena.curr_block.used, 16)
	testing.expect(
		t,
		after[0] == 0xCC,
		"memory taken after a free below the mark was freed",
	)
}

@(test)
test_rewind_leaves_an_arena_whose_marked_block_is_gone_alone :: proc(
	t: ^testing.T,
) {
	arena: runtime.Arena
	arena.minimum_block_size = HANDLER_TEMP_TEST_BLOCK
	defer runtime.arena_destroy(&arena)

	_ = take_bytes(&arena, 64, 0xAA)
	_ = take_bytes(&arena, HANDLER_TEMP_TEST_BLOCK, 0xBB)
	mark := temp_arena_mark(&arena)
	runtime.arena_free_all(&arena)
	_ = take_bytes(&arena, 16, 0xCC)
	total := arena.total_used

	rewind_temp_arena(mark)

	testing.expect_value(t, arena.total_used, total)
}

@(test)
test_handler_temp_abandon_drops_a_panicked_actors_handlers :: proc(
	t: ^testing.T,
) {
	temp := &runtime.global_default_temp_allocator_data.arena
	_ = take_bytes(temp, 16, 0xAA)
	before := temp.total_used

	suspended, panicked: Actor_Context
	handler_temp_begin(&suspended)
	handler_temp_begin(&panicked)
	handler_temp_begin(&panicked)
	_ = take_bytes(temp, 64, 0x33)

	handler_temp_abandon(&panicked)

	testing.expect_value(t, panicked.handlers_running, 0)
	testing.expect_value(t, handlers_running_on_this_thread, 1)
	testing.expect(
		t,
		temp.total_used > before,
		"the arena was rewound while another handler was suspended",
	)

	handler_temp_end(&suspended)

	testing.expect_value(t, temp.total_used, before)
}

@(test)
test_handler_temp_abandon_rewinds_when_the_panicked_actor_held_the_last_handlers :: proc(
	t: ^testing.T,
) {
	temp := &runtime.global_default_temp_allocator_data.arena
	_ = take_bytes(temp, 16, 0xAA)
	before := temp.total_used

	panicked: Actor_Context
	handler_temp_begin(&panicked)
	handler_temp_begin(&panicked)
	_ = take_bytes(temp, 64, 0x33)

	handler_temp_abandon(&panicked)

	testing.expect_value(t, panicked.handlers_running, 0)
	testing.expect_value(t, handlers_running_on_this_thread, 0)
	testing.expect_value(t, temp.total_used, before)
}

@(private = "file")
eat_temp_in_a_callback :: proc(data: rawptr) {
	note_entry_and_eat_temp()
}

@(test)
test_init_and_terminate_leave_the_temp_arena_where_they_found_it :: proc(
	t: ^testing.T,
) {
	f := make_loop_fixture(eat_temp_on_a_message)
	defer destroy_loop_fixture(f)
	f.actor.behaviour.init = eat_temp_in_a_callback
	f.actor.behaviour.terminate = eat_temp_in_a_callback
	before := give_the_temp_arena_a_block()

	run_init_handlers(f.actor, f.actor_ctx)
	testing.expect_value(t, temp_used(), before)
	run_terminate_handlers(f.actor, f.actor_ctx)

	expect_every_entry_at(t, before, 2)
	testing.expect_value(t, temp_used(), before)
	testing.expect_value(t, f.actor_ctx.handlers_running, 0)
}
