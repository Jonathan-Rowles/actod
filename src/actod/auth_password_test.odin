package actod

import "core:os"
import "core:testing"

@(private = "file")
ENV_AUTH_PASSWORD :: "password from the environment"

@(test)
a_connection_keeps_the_env_password_after_the_handler_that_made_it_rewinds_its_temp :: proc(
	t: ^testing.T,
) {
	if !testing.expect(t, NODE.config.network.auth_password == "") do return
	if !testing.expect(t, os.set_env("ACTOD_AUTH_PASSWORD", ENV_AUTH_PASSWORD) == nil) do return
	node_own_config_strings(NODE, NODE.config)
	defer node_own_config_strings(NODE, NODE.config)
	defer os.unset_env("ACTOD_AUTH_PASSWORD")

	_ = make([]byte, 16, context.temp_allocator)
	handler_temp_begin(nil)
	data := make_connection_actor_data(0, {})
	handler_temp_end(nil)

	testing.expect_value(t, data.auth_password, ENV_AUTH_PASSWORD)
}
