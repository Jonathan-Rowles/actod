package shared

import "core:time"

Benchmark_Config :: struct {
	message_size:    Message_Size,
	message_count:   int,
	actor_count:     int,
	sender_count:    int,
	warmup_messages: int,
	dedicated:       bool,
	worker_count:    int, // 0 = cpu_count
	same_worker:     bool, // pin sender+receiver pairs to same worker
}

Scaling_Config :: struct {
	actor_count:   int,
	sender_count:  int,
	message_count: int,
	message_size:  Message_Size,
	description:   string,
	category:      Test_Category,
	dedicated:     bool,
	worker_count:  int, // 0 = cpu_count
	same_worker:   bool, // pin sender+receiver pairs to same worker
}

Benchmark_Result :: struct {
	config:                   Benchmark_Config,
	duration:                 time.Duration,
	messages_sent:            u64,
	messages_received:        u64,
	send_failures:            u64,
	retry_count:              u64,
	err_actor_not_found:      u64,
	err_mailbox_full:         u64,
	err_pool_full:            u64,
	err_system_shutting_down: u64,
	err_network:              u64,
	err_other:                u64,
	throughput:               f64,
	bandwidth:                f64,
	latency_ns:               f64,
}

Size_Baseline :: struct {
	throughput: f64,
	latency_ns: f64,
}

Network_Config :: struct {
	receiver_port:    int,
	sender_port:      int,
	receiver_host:    string,
	auth_password:    string,
}

DEFAULT_RECEIVER_PORT :: 41337
DEFAULT_SENDER_PORT :: 41338
DEFAULT_AUTH_PASSWORD :: "benchmark_password"
