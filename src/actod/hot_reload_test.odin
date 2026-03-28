package actod

import "core:testing"

@(test)
test_is_actod_import_path :: proc(t: ^testing.T) {
	testing.expect(t, is_actod_import_path("actod"))
	testing.expect(t, is_actod_import_path("some/path/actod"))
	testing.expect(t, is_actod_import_path("some\\path\\actod"))
	testing.expect(t, is_actod_import_path("act:something"))

	testing.expect(t, is_actod_import_path(".."))
	testing.expect(t, is_actod_import_path("../.."))
	testing.expect(t, is_actod_import_path("../../.."))

	testing.expect(t, !is_actod_import_path("../../messages"))
	testing.expect(t, !is_actod_import_path("../shared/types"))
	testing.expect(t, !is_actod_import_path("../utils"))

	testing.expect(t, !is_actod_import_path("core:fmt"))
	testing.expect(t, !is_actod_import_path("base:runtime"))

	testing.expect(t, !is_actod_import_path("messages"))
	testing.expect(t, !is_actod_import_path("some/package"))
}

@(test)
test_strip_init_procs_preserves_types :: proc(t: ^testing.T) {
	source := `package test

Foo :: struct {
	x: int,
}

@(init)
register :: proc "contextless" () {
	do_something()
}

Bar :: struct {
	y: string,
}
`
	result := strip_init_procs(source)

	testing.expect(t, contains(result, "Foo :: struct"), "should preserve Foo")
	testing.expect(t, contains(result, "Bar :: struct"), "should preserve Bar")
	testing.expect(t, contains(result, "package test"), "should preserve package")
	testing.expect(t, !contains(result, "@(init)"), "should strip @(init)")
	testing.expect(t, !contains(result, "register"), "should strip register proc")
	testing.expect(t, !contains(result, "do_something"), "should strip proc body")
}

@(test)
test_strip_init_procs_handles_multiline :: proc(t: ^testing.T) {
	source := `package test

@(init)
setup :: proc() {
	if true {
		nested()
	}
}

keep_me :: proc() {
	log("hello")
}
`
	result := strip_init_procs(source)

	testing.expect(t, !contains(result, "setup"), "should strip setup")
	testing.expect(t, !contains(result, "nested"), "should strip nested braces")
	testing.expect(t, contains(result, "keep_me"), "should preserve keep_me")
	testing.expect(t, contains(result, "hello"), "should preserve keep_me body")
}

@(test)
test_strip_init_procs_no_init :: proc(t: ^testing.T) {
	source := `package test

Foo :: struct { x: int }

handler :: proc() { do_work() }
`
	result := strip_init_procs(source)
	testing.expect(t, contains(result, "Foo"), "should preserve Foo")
	testing.expect(t, contains(result, "handler"), "should preserve handler")
}

@(private)
contains :: proc(haystack, needle: string) -> bool {
	if len(needle) > len(haystack) do return false
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle do return true
	}
	return false
}
