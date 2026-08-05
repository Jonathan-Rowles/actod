package coro

import "core:fmt"
import "core:testing"

@(test)
test_simple :: proc(t: ^testing.T) {
	simple_entry :: proc(co: ^Coro) {
		yield(co)
	}

	desc := desc_init(simple_entry)
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")
	testing.expect(t, status(co) == .Suspended, "should start suspended")

	res = resume(co)
	testing.expect(t, res == .Success, "resume 1 failed")
	testing.expect(t, status(co) == .Suspended, "should be suspended after yield")

	res = resume(co)
	testing.expect(t, res == .Success, "resume 2 failed")
	testing.expect(t, status(co) == .Dead, "should be dead after finishing")

	res = destroy(co)
	testing.expect(t, res == .Success, "destroy failed")
}

@(test)
test_storage_across_yields :: proc(t: ^testing.T) {
	entry :: proc(co: ^Coro) {
		testing.expect(running_test_t, get_bytes_stored(co) == 6, "expected 6 bytes stored")
		buf: [128]u8
		testing.expect(
			running_test_t,
			peek(co, &buf[0], get_bytes_stored(co)) == .Success,
			"peek failed",
		)
		testing.expect(running_test_t, string(buf[:5]) == "hello", "expected 'hello'")
		testing.expect(
			running_test_t,
			pop(co, nil, get_bytes_stored(co)) == .Success,
			"pop discard failed",
		)

		ret: i32 = 1
		testing.expect(
			running_test_t,
			push(co, &ret, size_of(i32)) == .Success,
			"push ret=1 failed",
		)
		yield(co)

		testing.expect(running_test_t, get_bytes_stored(co) == 7, "expected 7 bytes stored")
		buf = {}
		testing.expect(
			running_test_t,
			pop(co, &buf[0], get_bytes_stored(co)) == .Success,
			"pop word2 failed",
		)
		testing.expect(running_test_t, string(buf[:6]) == "world!", "expected 'world!'")

		ret = 2
		push(co, &ret, size_of(i32))
	}

	running_test_t = t

	desc := desc_init(entry)
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")

	first_word := [6]u8{'h', 'e', 'l', 'l', 'o', 0}
	testing.expect(
		t,
		push(co, &first_word[0], size_of(first_word)) == .Success,
		"push first_word failed",
	)

	res = resume(co)
	testing.expect(t, res == .Success, "resume 1 failed")
	testing.expect(t, status(co) == .Suspended, "should be suspended")

	ret: i32
	testing.expect(t, pop(co, &ret, size_of(i32)) == .Success, "pop ret1 failed")
	testing.expect_value(t, ret, i32(1))

	second_word := [7]u8{'w', 'o', 'r', 'l', 'd', '!', 0}
	testing.expect(
		t,
		push(co, &second_word[0], size_of(second_word)) == .Success,
		"push second_word failed",
	)

	res = resume(co)
	testing.expect(t, res == .Success, "resume 2 failed")
	testing.expect(t, status(co) == .Dead, "should be dead")

	testing.expect(t, pop(co, &ret, size_of(i32)) == .Success, "pop ret2 failed")
	testing.expect_value(t, ret, i32(2))

	destroy(co)
}

@(thread_local)
running_test_t: ^testing.T

@(test)
test_nested_coroutines :: proc(t: ^testing.T) {
	inner_entry :: proc(co2: ^Coro) {
		t := running_test_t
		co: ^Coro

		testing.expect(t, running() == co2, "running() should be co2")
		testing.expect(t, status(co2) == .Running, "co2 should be Running")
		testing.expect(t, pop(co2, &co, size_of(^Coro)) == .Success, "pop co ptr failed")
		testing.expect(t, pop(co2, nil, get_bytes_stored(co2)) == .Success, "pop discard failed")
		testing.expect(t, status(co) == .Normal, "outer co should be Normal")
		testing.expect(t, get_bytes_stored(co2) == 0, "storage should be empty")

		yield(running())

	}

	outer_entry :: proc(co: ^Coro) {
		t := running_test_t

		testing.expect(t, running() == co, "running() should be co")
		testing.expect(t, status(co) == .Running, "co should be Running")

		desc := desc_init(inner_entry)
		co2, res := create(&desc)
		testing.expect(t, res == .Success, "create inner failed")

		co_ptr := co
		testing.expect(t, push(co2, &co_ptr, size_of(^Coro)) == .Success, "push co ptr failed")
		testing.expect(t, resume(co2) == .Success, "resume inner 1 failed")
		testing.expect(t, resume(co2) == .Success, "resume inner 2 failed")
		testing.expect(t, get_bytes_stored(co2) == 0, "inner storage should be empty")
		testing.expect(t, status(co2) == .Dead, "inner should be Dead")
		testing.expect(t, status(co) == .Running, "outer should still be Running")
		testing.expect(t, running() == co, "running() should be outer co")
		testing.expect(t, destroy(co2) == .Success, "destroy inner failed")
	}

	running_test_t = t

	desc := desc_init(outer_entry)
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create outer failed")

	res = resume(co)
	testing.expect(t, res == .Success, "resume outer failed")
	testing.expect(t, status(co) == .Dead, "outer should be Dead")

	destroy(co)
}

@(test)
test_user_data :: proc(t: ^testing.T) {
	dummy: int = 42

	check_entry :: proc(co: ^Coro) {
		t := running_test_t
		ud := cast(^int)get_user_data(co)
		testing.expect(t, ud != nil, "user_data should not be nil")
		testing.expect_value(t, ud^, 42)
	}

	running_test_t = t

	desc := desc_init(check_entry)
	desc.user_data = &dummy
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")
	testing.expect(t, get_user_data(co) == &dummy, "user_data mismatch before resume")

	resume(co)
	destroy(co)
}

@(test)
test_fibonacci :: proc(t: ^testing.T) {
	fib_entry :: proc(co: ^Coro) {
		m: u64 = 1
		n: u64 = 1

		max: u64
		pop(co, &max, size_of(u64))

		for {
			push(co, &m, size_of(u64))
			res := yield(co)
			if res != .Success do break

			tmp := m + n
			m = n
			n = tmp
			if m >= max do break
		}
		push(co, &m, size_of(u64))
	}

	expected := [?]u64 {
		1,
		1,
		2,
		3,
		5,
		8,
		13,
		21,
		34,
		55,
		89,
		144,
		233,
		377,
		610,
		987,
		1597,
		2584,
		4181,
		6765,
		10946,
		17711,
		28657,
		46368,
		75025,
		121393,
		196418,
		317811,
		514229,
		832040,
		1346269,
		2178309,
		3524578,
		5702887,
		9227465,
		14930352,
		24157817,
		39088169,
		63245986,
		102334155,
		165580141,
		267914296,
		433494437,
		701408733,
		1134903170,
	}

	desc := desc_init(fib_entry)
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")

	max: u64 = 1000000000
	push(co, &max, size_of(u64))

	i := 0
	for status(co) == .Suspended {
		res = resume(co)
		testing.expect(t, res == .Success, "resume failed")

		ret: u64
		res = pop(co, &ret, size_of(u64))
		testing.expect(t, res == .Success, "pop failed")

		if i < len(expected) {
			testing.expect_value(t, ret, expected[i])
		}
		i += 1
	}

	testing.expect_value(t, i, len(expected))
	destroy(co)
}

@(test)
test_mem_stress :: proc(t: ^testing.T) {
	NUM :: 100_000

	stress_entry :: proc(co: ^Coro) {
		yield(co)
	}

	coros := new([NUM]^Coro)
	defer free(coros)
	desc := desc_init(stress_entry)

	for i in 0 ..< NUM {
		co, res := create(&desc)
		testing.expect(t, res == .Success, fmt.tprintf("create %d failed", i))
		res = resume(co)
		testing.expect(t, res == .Success, fmt.tprintf("resume %d failed", i))
		coros[i] = co
	}

	for i in 0 ..< NUM {
		co := coros^[i]
		res := resume(co)
		testing.expect(t, res == .Success, fmt.tprintf("resume2 %d failed", i))
		testing.expect(t, status(co) == .Dead, fmt.tprintf("co %d should be dead", i))
		destroy(co)
	}
}

@(test)
test_error_cases :: proc(t: ^testing.T) {
	testing.expect(t, resume(nil) == .Invalid_Coroutine, "resume nil")
	testing.expect(t, yield(nil) == .Invalid_Coroutine, "yield nil")
	testing.expect(t, destroy(nil) == .Invalid_Coroutine, "destroy nil")
	testing.expect(t, push(nil, nil, 0) == .Invalid_Coroutine, "push nil")
	testing.expect(t, pop(nil, nil, 0) == .Invalid_Coroutine, "pop nil")
	testing.expect(t, peek(nil, nil, 0) == .Invalid_Coroutine, "peek nil")
	testing.expect(t, get_bytes_stored(nil) == 0, "bytes_stored nil")
	testing.expect(t, get_storage_size(nil) == 0, "storage_size nil")
	testing.expect(t, get_user_data(nil) == nil, "user_data nil")
	testing.expect(t, status(nil) == .Dead, "status nil")
	testing.expect(t, running() == nil, "running should be nil outside coro")

	noop_entry :: proc(co: ^Coro) {}
	desc := desc_init(noop_entry)
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")

	res = resume(co)
	testing.expect(t, res == .Success, "resume failed")
	testing.expect(t, status(co) == .Dead, "should be dead")

	res = resume(co)
	testing.expect(t, res == .Not_Suspended, "resume dead should return Not_Suspended")

	destroy(co)
}

@(test)
test_combined_testsuite :: proc(t: ^testing.T) {
	inner_entry :: proc(co2: ^Coro) {
		t := running_test_t
		co: ^Coro

		testing.expect(t, running() == co2, "running() should be co2")
		testing.expect(t, status(co2) == .Running, "co2 should be Running")
		testing.expect(t, pop(co2, &co, size_of(^Coro)) == .Success, "pop co ptr failed")
		testing.expect(t, pop(co2, nil, get_bytes_stored(co2)) == .Success, "pop discard failed")
		testing.expect(t, status(co) == .Normal, "outer co should be Normal")
		testing.expect(t, get_bytes_stored(co2) == 0, "storage should be empty")

		yield(running())
	}

	outer_entry :: proc(co: ^Coro) {
		t := running_test_t

		ud := cast(^int)get_user_data(co)
		testing.expect(t, ud != nil, "user_data should not be nil")
		testing.expect(t, ud^ == 0, "user_data should be 0")
		testing.expect(t, running() == co, "running() should be co")
		testing.expect(t, status(co) == .Running, "co should be Running")

		testing.expect(t, get_bytes_stored(co) == 6, "expected 6 bytes stored")
		buf: [128]u8
		testing.expect(t, peek(co, &buf[0], get_bytes_stored(co)) == .Success, "peek failed")
		testing.expect(t, string(buf[:5]) == "hello", "expected 'hello'")
		testing.expect(t, pop(co, nil, get_bytes_stored(co)) == .Success, "pop discard failed")

		ret: i32 = 1
		testing.expect(t, push(co, &ret, size_of(i32)) == .Success, "push ret=1 failed")
		yield(co)

		testing.expect(t, get_bytes_stored(co) == 7, "expected 7 bytes stored")
		buf = {}
		testing.expect(t, pop(co, &buf[0], get_bytes_stored(co)) == .Success, "pop word2 failed")
		testing.expect(t, string(buf[:6]) == "world!", "expected 'world!'")

		ret = 2
		push(co, &ret, size_of(i32))

		inner_desc := desc_init(inner_entry)
		co2, res := create(&inner_desc)
		testing.expect(t, res == .Success, "create inner failed")

		co_ptr := co
		testing.expect(t, push(co2, &co_ptr, size_of(^Coro)) == .Success, "push co ptr failed")
		testing.expect(t, resume(co2) == .Success, "resume inner 1 failed")
		testing.expect(t, resume(co2) == .Success, "resume inner 2 failed")
		testing.expect(t, get_bytes_stored(co2) == 0, "inner storage should be empty")
		testing.expect(t, status(co2) == .Dead, "inner should be Dead")
		testing.expect(t, status(co) == .Running, "outer should still be Running")
		testing.expect(t, running() == co, "running() should be outer co")
		testing.expect(t, destroy(co2) == .Success, "destroy inner failed")
	}

	running_test_t = t
	dummy_user_data: int = 0

	desc := desc_init(outer_entry)
	desc.user_data = &dummy_user_data
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")
	testing.expect(t, status(co) == .Suspended, "should start suspended")

	first_word := [6]u8{'h', 'e', 'l', 'l', 'o', 0}
	testing.expect(
		t,
		push(co, &first_word[0], size_of(first_word)) == .Success,
		"push first_word failed",
	)

	res = resume(co)
	testing.expect(t, res == .Success, "resume 1 failed")
	testing.expect(t, status(co) == .Suspended, "should be suspended")

	ret: i32
	testing.expect(t, pop(co, &ret, size_of(i32)) == .Success, "pop ret1 failed")
	testing.expect_value(t, ret, i32(1))

	second_word := [7]u8{'w', 'o', 'r', 'l', 'd', '!', 0}
	testing.expect(
		t,
		push(co, &second_word[0], size_of(second_word)) == .Success,
		"push second_word failed",
	)

	res = resume(co)
	testing.expect(t, res == .Success, "resume 2 failed")
	testing.expect(t, status(co) == .Dead, "should be dead")

	testing.expect(t, pop(co, &ret, size_of(i32)) == .Success, "pop ret2 failed")
	testing.expect_value(t, ret, i32(2))

	destroy(co)
}

@(test)
test_result_description :: proc(t: ^testing.T) {
	testing.expect(t, result_description(.Success) == "No error", "Success desc")
	testing.expect(t, result_description(.Out_Of_Memory) == "Out of memory", "Out_Of_Memory desc")
}
