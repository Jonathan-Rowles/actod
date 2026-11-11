package actod

import "core:net"
import "core:testing"

@(test)
parse_bind_address_defaults_to_loopback :: proc(t: ^testing.T) {
	addr, ok := parse_bind_address("")
	testing.expect(t, ok)
	testing.expect_value(t, addr.(net.IP4_Address), net.IP4_Loopback)
}

@(test)
parse_bind_address_accepts_ip4_and_ip6 :: proc(t: ^testing.T) {
	for input in ([]string{"127.0.0.1", "0.0.0.0", "192.168.1.5", "::", "::1"}) {
		_, ok := parse_bind_address(input)
		testing.expectf(t, ok, "expected %q to parse", input)
	}
}

@(test)
parse_bind_address_rejects_garbage :: proc(t: ^testing.T) {
	for input in ([]string{"localhost", "not-an-ip", "127.0.0.1:9000", "999.0.0.1"}) {
		_, ok := parse_bind_address(input)
		testing.expectf(t, !ok, "expected %q to be rejected", input)
	}
}

@(test)
address_is_loopback_classification :: proc(t: ^testing.T) {
	loopbacks := []string{"127.0.0.1", "127.5.5.5", "::1"}
	for input in loopbacks {
		addr, ok := parse_bind_address(input)
		testing.expect(t, ok)
		testing.expectf(
			t,
			address_is_loopback(addr),
			"expected %q to be loopback",
			input,
		)
	}

	open_binds := []string{"0.0.0.0", "192.168.1.5", "10.0.0.1", "::"}
	for input in open_binds {
		addr, ok := parse_bind_address(input)
		testing.expect(t, ok)
		testing.expectf(
			t,
			!address_is_loopback(addr),
			"expected %q to NOT be loopback",
			input,
		)
	}
}

@(test)
default_network_config_binds_loopback :: proc(t: ^testing.T) {
	addr, ok := parse_bind_address(DEFAULT_NETWORK_CONFIG.bind_address)
	testing.expect(t, ok)
	testing.expect(t, address_is_loopback(addr))
}

@(test)
network_exposure_refusal_flags_non_loopback_bind_without_auth_password :: proc(
	t: ^testing.T,
) {
	for input in ([]string{"0.0.0.0", "192.168.1.5", "::"}) {
		addr, _ := parse_bind_address(input)
		network := Network_Config {
			port         = 5000,
			bind_address = input,
		}
		testing.expect_value(
			t,
			network_exposure_refusal(network, addr, ""),
			Network_Exposure_Refusal.Missing_Auth_Password,
		)
		network.enable_encryption = true
		testing.expect_value(
			t,
			network_exposure_refusal(network, addr, ""),
			Network_Exposure_Refusal.Missing_Auth_Password,
		)
		network.trusted_network = true
		testing.expect_value(
			t,
			network_exposure_refusal(network, addr, ""),
			Network_Exposure_Refusal.Missing_Auth_Password,
		)
	}
}

@(test)
network_exposure_refusal_flags_plaintext_non_loopback_bind_without_trusted_network :: proc(
	t: ^testing.T,
) {
	addr, _ := parse_bind_address("0.0.0.0")
	network := Network_Config {
		port         = 5000,
		bind_address = "0.0.0.0",
	}
	testing.expect_value(
		t,
		network_exposure_refusal(network, addr, "secret"),
		Network_Exposure_Refusal.Plaintext_On_Untrusted_Network,
	)
	network.trusted_network = true
	testing.expect_value(
		t,
		network_exposure_refusal(network, addr, "secret"),
		Network_Exposure_Refusal.None,
	)
	network.trusted_network = false
	network.enable_encryption = true
	testing.expect_value(
		t,
		network_exposure_refusal(network, addr, "secret"),
		Network_Exposure_Refusal.None,
	)
}

@(test)
network_exposure_refusal_allows_loopback_and_listener_free_binds :: proc(
	t: ^testing.T,
) {
	for input in ([]string{"127.0.0.1", "::1"}) {
		addr, _ := parse_bind_address(input)
		network := Network_Config {
			port         = 5000,
			bind_address = input,
		}
		testing.expect_value(
			t,
			network_exposure_refusal(network, addr, ""),
			Network_Exposure_Refusal.None,
		)
	}
	addr, _ := parse_bind_address("0.0.0.0")
	without_listener := Network_Config {
		bind_address = "0.0.0.0",
	}
	testing.expect_value(
		t,
		network_exposure_refusal(without_listener, addr, ""),
		Network_Exposure_Refusal.None,
	)
}

@(test)
default_network_config_is_untrusted :: proc(t: ^testing.T) {
	testing.expect(t, !DEFAULT_NETWORK_CONFIG.trusted_network)
}
