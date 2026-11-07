package integration

import "../actod"
import "core:testing"

UNASSIGNED_NON_LOOPBACK_BIND :: "192.0.2.1"
REFUSED_LISTENER_PORT :: 47913

test_node_init_refuses_open_bind_with_no_password :: proc(t: ^testing.T) {
	actod.node_init(
		"refuses_open_bind_with_no_password",
		actod.make_node_config(
			network = actod.make_network_config(
				port = REFUSED_LISTENER_PORT,
				bind_address = UNASSIGNED_NON_LOOPBACK_BIND,
				auth_password = "",
			),
		),
	)
	actod.node_shutdown()
}

test_node_init_refuses_open_plaintext_bind_by_default :: proc(t: ^testing.T) {
	actod.node_init(
		"refuses_open_plaintext_bind_by_default",
		actod.make_node_config(
			network = actod.make_network_config(
				port = REFUSED_LISTENER_PORT,
				bind_address = UNASSIGNED_NON_LOOPBACK_BIND,
				auth_password = "test_dist_password",
				enable_encryption = false,
				trusted_network = false,
			),
		),
	)
	actod.node_shutdown()
}
