package actod

import "../../test_harness/ti"
import "core:testing"
import "core:time"

@(test)
seeded_rng_replays_exactly :: proc(t: ^testing.T) {
	ic: ti.Det_State
	ic.rng_state = 42
	ti.det = &ic
	defer ti.det = nil

	first := generate_nonce()
	second := generate_nonce()
	testing.expect(t, first != second)

	ic.rng_state = 42
	testing.expect_value(t, generate_nonce(), first)
	testing.expect_value(t, generate_nonce(), second)

	ic.rng_state = 43
	testing.expect(t, generate_nonce() != first)
}

@(test)
unseeded_rng_still_random :: proc(t: ^testing.T) {
	testing.expect(t, generate_nonce() != generate_nonce())
}

@(test)
virtual_tick_drives_mono_now_and_sleep :: proc(t: ^testing.T) {
	ic: ti.Det_State
	ic.virtual_tick_ns = 1_000
	ti.det = &ic
	defer ti.det = nil

	before := mono_now()
	runtime_sleep(5 * time.Millisecond)
	after := mono_now()
	testing.expect_value(t, time.tick_diff(before, after), 5 * time.Millisecond)
}
