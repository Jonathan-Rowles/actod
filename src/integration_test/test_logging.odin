package integration

import "core:log"
import "core:os"
import "core:strings"

TEST_LOG_DEFAULT :: log.Level.Fatal
TEST_LOG_ENV :: "ACTOD_TEST_LOG"

test_log_level :: proc() -> log.Level {
	value, found := os.lookup_env(TEST_LOG_ENV, context.temp_allocator)
	if !found do return TEST_LOG_DEFAULT

	switch strings.to_lower(value, context.temp_allocator) {
	case "debug":
		return .Debug
	case "info":
		return .Info
	case "warn", "warning":
		return .Warning
	case "error":
		return .Error
	case "fatal":
		return TEST_LOG_DEFAULT
	}
	return TEST_LOG_DEFAULT
}
