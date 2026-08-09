package actod

import "../../test_harness/ti"
import "core:bytes"
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

@(test)
seeded_noise_handshake_is_deterministic :: proc(t: ^testing.T) {
	first_message :: proc(seed: u64) -> []byte {
		ic: ti.Det_State
		ic.rng_state = seed
		ti.det = &ic
		defer ti.det = nil

		psk: [CLUSTER_PSK_SIZE]byte
		for &b, i in psk do b = u8(i)

		hs: Noise_Handshake
		if !noise_handshake_begin(&hs, true, transmute([]byte)string("dst-test"), psk[:]) {
			return nil
		}
		msg, _, ok := noise_handshake_step(&hs, nil, context.temp_allocator)
		if !ok do return nil
		return msg
	}

	a := first_message(7)
	b := first_message(7)
	c := first_message(8)
	testing.expect(t, a != nil && len(a) > 0)
	testing.expect(t, bytes.equal(a, b))
	testing.expect(t, !bytes.equal(a, c))
}
