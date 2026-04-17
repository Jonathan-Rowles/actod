package shared

import "../../src/actod"
import "core:sync"
import "core:time"

Benchmark_State :: struct {
	actors:                   []actod.PID,
	warmup_wg:                ^sync.Wait_Group,
	completion_wg:            ^sync.Wait_Group,
	send_count:               u64,
	receive_count:            u64,
	send_failures:            u64,
	retry_count:              u64,
	err_actor_not_found:      u64,
	err_receiver_backlogged:  u64,
	err_message_too_large:    u64,
	err_system_shutting_down: u64,
	err_network:              u64,
	err_ring_full:            u64,
	err_other:                u64,
	warmup_complete:          bool,
	warmup_mutex:             sync.Mutex,
	warmup_counter:           int,
	sender_count:             int,
	bench_start_time:         time.Time,
}

Benchmark_Actor_Data :: struct {
	id:             int,
	message_count:  u64,
	start_time:     time.Time,
	first_msg_time: time.Time,
	last_msg_time:  time.Time,
}

track_send_error :: #force_inline proc(state: ^Benchmark_State, err: actod.Send_Error) {
	sync.atomic_add(&state.retry_count, 1)

	switch err {
	case .OK:
	// Shouldn't happen
	case .ACTOR_NOT_FOUND:
		sync.atomic_add(&state.err_actor_not_found, 1)
	case .RECEIVER_BACKLOGGED:
		sync.atomic_add(&state.err_receiver_backlogged, 1)
	case .MESSAGE_TOO_LARGE:
		sync.atomic_add(&state.err_message_too_large, 1)
	case .SYSTEM_SHUTTING_DOWN:
		sync.atomic_add(&state.err_system_shutting_down, 1)
	case .NETWORK_ERROR:
		sync.atomic_add(&state.err_network, 1)
	case .NETWORK_RING_FULL:
		sync.atomic_add(&state.err_ring_full, 1)
	case .NODE_NOT_FOUND:
		sync.atomic_add(&state.err_actor_not_found, 1)
	case .NODE_DISCONNECTED:
		sync.atomic_add(&state.err_network, 1)
	}
}
