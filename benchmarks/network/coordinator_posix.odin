#+build linux, darwin, freebsd, openbsd, netbsd
package network_benchmark

make_bench_env :: proc(test_vars: []string, allocator := context.temp_allocator) -> []string {
	return test_vars
}
