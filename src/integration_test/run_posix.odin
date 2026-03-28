#+build linux, darwin, freebsd, openbsd, netbsd
package integration

make_test_env :: proc(test_vars: []string, allocator := context.temp_allocator) -> []string {
	return test_vars
}
