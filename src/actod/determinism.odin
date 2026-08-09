package actod

import "../../test_harness/ti"
_ :: ti
import "core:time"

actod_rand_bytes :: proc(buf: []byte) {
	when ODIN_TEST {if ti.intercept_rand_bytes(buf) do return}
	platform_gen_random(raw_data(buf), uint(len(buf)))
}

mono_now :: proc() -> time.Tick {
	when ODIN_TEST {if t, ok := ti.intercept_tick_now(); ok do return t}
	return time.tick_now()
}

runtime_sleep :: proc(d: time.Duration) {
	when ODIN_TEST {if ti.intercept_sleep(d) do return}
	time.sleep(d)
}

mono_since :: #force_inline proc(start: time.Tick) -> time.Duration {
	return time.tick_diff(start, mono_now())
}

wall_since :: #force_inline proc(start: time.Time) -> time.Duration {
	return time.diff(start, now())
}
