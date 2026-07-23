package integration

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:testing"

@(private = "file")
report :: proc(t: ^testing.T, loc: runtime.Source_Code_Location, msg: string) {
	t.error_count += 1
	fmt.eprintf("[ASSERT] %s(%d:%d) %s\n", loc.file_path, loc.line, loc.column, msg)
	os.flush(os.stderr)
}

expect :: proc(
	t: ^testing.T,
	ok: bool,
	msg := "",
	expr := #caller_expression(ok),
	loc := #caller_location,
) -> bool {
	if !ok {
		if msg == "" {
			report(t, loc, fmt.tprintf("expected %v to be true", expr))
		} else {
			report(t, loc, msg)
		}
	}
	return ok
}

expectf :: proc(
	t: ^testing.T,
	ok: bool,
	format: string,
	args: ..any,
	loc := #caller_location,
) -> bool {
	if !ok {
		report(t, loc, fmt.tprintf(format, ..args))
	}
	return ok
}

expect_value :: proc(
	t: ^testing.T,
	value, expected: $V,
	loc := #caller_location,
	value_expr := #caller_expression(value),
) -> bool where intrinsics.type_is_comparable(V) {
	ok := value == expected || reflect.is_nil(value) && reflect.is_nil(expected)
	if !ok {
		report(t, loc, fmt.tprintf("expected %v to be %v, got %v", value_expr, expected, value))
	}
	return ok
}
