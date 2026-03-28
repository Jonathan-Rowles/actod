package benchmark

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"

BENCH_REPEATS := 5

init_bench_repeats :: proc() {
	if v, ok := os.lookup_env("BENCH_REPEATS", context.allocator); ok {
		defer delete(v)
		if n, parse_ok := strconv.parse_int(v); parse_ok && n > 0 {
			BENCH_REPEATS = n
		}
	}
}

summarize_f64 :: proc(xs: []f64) -> (median: f64, lo: f64, hi: f64) {
	slice.sort(xs)
	s := xs
	if len(xs) >= 5 {
		s = xs[1:len(xs) - 1]
	}
	n := len(s)
	return s[n / 2], s[0], s[n - 1]
}

fmt_spread :: proc(median, lo, hi: f64) -> string {
	if median <= 0 {
		return "-"
	}
	down := (median - lo) / median * 100
	up := (hi - median) / median * 100
	return fmt.tprintf("-%.0f/+%.0f%%", down, up)
}

median_lo_hi_stat :: proc(
	runs: []Latency_Stats,
	get: proc(s: Latency_Stats) -> i64,
) -> (
	median: i64,
	lo: i64,
	hi: i64,
) {
	xs := make([]i64, len(runs))
	defer delete(xs)
	for r, i in runs {
		xs[i] = get(r)
	}
	slice.sort(xs)
	s := xs
	if len(xs) >= 5 {
		s = xs[1:len(xs) - 1]
	}
	n := len(s)
	return s[n / 2], s[0], s[n - 1]
}
