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

@(thread_local)
running_test_t: ^testing.T

@(thread_local)
running_test_co: ^Coro

@(test)
test_nested_coroutines :: proc(t: ^testing.T) {
	inner_entry :: proc(co2: ^Coro) {
		t := running_test_t

		testing.expect(t, running() == co2, "running() should be co2")
		testing.expect(t, status(co2) == .Running, "co2 should be Running")
		testing.expect(t, get_user_data(co2) != nil, "user_data should not be nil")
		co := (cast(^^Coro)get_user_data(co2))^
		testing.expect(t, co != nil, "coro pointer via user_data should not be nil")
		testing.expect(t, co == running_test_co, "coro pointer should match the outer coroutine")
		testing.expect(t, status(co) == .Normal, "outer co should be Normal")

		yield(running())

	}

	outer_entry :: proc(co: ^Coro) {
		t := running_test_t

		testing.expect(t, running() == co, "running() should be co")
		testing.expect(t, status(co) == .Running, "co should be Running")

		running_test_co = co
		co_ptr := co
		desc := desc_init(inner_entry)
		desc.user_data = &co_ptr
		co2, res := create(&desc)
		testing.expect(t, res == .Success, "create inner failed")
		testing.expect(t, get_user_data(co2) == &co_ptr, "user_data co ptr mismatch before resume")

		testing.expect(t, resume(co2) == .Success, "resume inner 1 failed")
		testing.expect(t, resume(co2) == .Success, "resume inner 2 failed")
		testing.expect(t, get_user_data(co2) == &co_ptr, "user_data co ptr should persist after resume")
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
	Fibonacci_Data :: struct {
		max:   u64,
		value: u64,
	}

	fib_entry :: proc(co: ^Coro) {
		data := cast(^Fibonacci_Data)get_user_data(co)
		m: u64 = 1
		n: u64 = 1

		for {
			data.value = m
			res := yield(co)
			if res != .Success do break

			tmp := m + n
			m = n
			n = tmp
			if m >= data.max do break
		}
		data.value = m
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

	data := Fibonacci_Data{max = 1000000000}
	desc := desc_init(fib_entry)
	desc.user_data = &data
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")

	i := 0
	for status(co) == .Suspended {
		res = resume(co)
		testing.expect(t, res == .Success, "resume failed")
		testing.expect(t, get_user_data(co) == &data, "user_data mismatch during iteration")

		if i < len(expected) {
			testing.expect_value(t, data.value, expected[i])
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
	Combined_Data :: struct {
		dummy: int,
		word:  string,
		ret:   i32,
	}

	inner_entry :: proc(co2: ^Coro) {
		t := running_test_t

		testing.expect(t, running() == co2, "running() should be co2")
		testing.expect(t, status(co2) == .Running, "co2 should be Running")
		testing.expect(t, get_user_data(co2) != nil, "user_data should not be nil")
		co := (cast(^^Coro)get_user_data(co2))^
		testing.expect(t, co != nil, "coro pointer via user_data should not be nil")
		testing.expect(t, co == running_test_co, "coro pointer should match the outer coroutine")
		testing.expect(t, status(co) == .Normal, "outer co should be Normal")

		yield(running())
	}

	outer_entry :: proc(co: ^Coro) {
		t := running_test_t

		data := cast(^Combined_Data)get_user_data(co)
		testing.expect(t, data != nil, "user_data should not be nil")
		testing.expect(t, data.dummy == 0, "user_data should be 0")
		testing.expect(t, running() == co, "running() should be co")
		testing.expect(t, status(co) == .Running, "co should be Running")

		testing.expect(t, data.word == "hello", "expected 'hello'")
		testing.expect(t, len(data.word) == 5, "expected 5 byte word")

		data.ret = 1
		yield(co)

		testing.expect(t, data.word == "world!", "expected 'world!'")
		testing.expect(t, len(data.word) == 6, "expected 6 byte word")

		data.ret = 2

		running_test_co = co
		co_ptr := co
		inner_desc := desc_init(inner_entry)
		inner_desc.user_data = &co_ptr
		co2, res := create(&inner_desc)
		testing.expect(t, res == .Success, "create inner failed")
		testing.expect(t, get_user_data(co2) == &co_ptr, "user_data co ptr mismatch before resume")

		testing.expect(t, resume(co2) == .Success, "resume inner 1 failed")
		testing.expect(t, resume(co2) == .Success, "resume inner 2 failed")
		testing.expect(t, get_user_data(co2) == &co_ptr, "user_data co ptr should persist after resume")
		testing.expect(t, status(co2) == .Dead, "inner should be Dead")
		testing.expect(t, status(co) == .Running, "outer should still be Running")
		testing.expect(t, running() == co, "running() should be outer co")
		testing.expect(t, destroy(co2) == .Success, "destroy inner failed")
	}

	running_test_t = t
	data := Combined_Data{}

	desc := desc_init(outer_entry)
	desc.user_data = &data
	co, res := create(&desc)
	testing.expect(t, res == .Success, "create failed")
	testing.expect(t, status(co) == .Suspended, "should start suspended")

	data.word = "hello"

	res = resume(co)
	testing.expect(t, res == .Success, "resume 1 failed")
	testing.expect(t, status(co) == .Suspended, "should be suspended")
	testing.expect_value(t, data.ret, i32(1))

	data.word = "world!"

	res = resume(co)
	testing.expect(t, res == .Success, "resume 2 failed")
	testing.expect(t, status(co) == .Dead, "should be dead")
	testing.expect_value(t, data.ret, i32(2))

	destroy(co)
}

@(test)
test_result_description :: proc(t: ^testing.T) {
	testing.expect(t, result_description(.Success) == "No error", "Success desc")
	testing.expect(t, result_description(.Out_Of_Memory) == "Out of memory", "Out_Of_Memory desc")
}
