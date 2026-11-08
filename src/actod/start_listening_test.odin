package actod

import "core:log"
import "core:testing"

@(test)
start_listening_refuses_an_open_bind_without_a_password_and_leaves_the_node_without_a_listener :: proc(
	t: ^testing.T,
) {
	context.logger = log.nil_logger()
	saved := NODE.config.network
	defer NODE.config.network = saved
	NODE.config.network = Network_Config {
		bind_address = "0.0.0.0",
	}
	testing.expect(t, !start_listening(47395))
	testing.expect_value(t, NODE.config.network.port, 0)
	testing.expect(t, NODE.network_listener_thread == nil)
}

@(test)
start_listening_refuses_a_port_of_zero :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	saved := NODE.config.network
	defer NODE.config.network = saved
	NODE.config.network = Network_Config {
		bind_address = "127.0.0.1",
	}
	testing.expect(t, !start_listening(0))
	testing.expect_value(t, NODE.config.network.port, 0)
}
