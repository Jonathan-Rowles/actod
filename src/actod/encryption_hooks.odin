package actod

import "core:net"
import "core:time"

ENVELOPE_TAG_SIZE :: 16
ENVELOPE_OVERHEAD :: 4 + ENVELOPE_TAG_SIZE
MAX_ENVELOPE_PLAINTEXT :: 65535 - ENVELOPE_TAG_SIZE

Noise_Transport :: struct #align (8) {
	opaque: [2040]byte,
}

Encryption_Hooks :: struct {
	handshake: proc(
		auth_password: string,
		sock: net.TCP_Socket,
		initiator: bool,
		my_hello: []byte,
		peer_hello: []byte,
		keys: ^Noise_Transport,
		deadline: time.Time,
	) -> bool,
	seal:      proc(keys: ^Noise_Transport, plaintext: []byte, dst: []byte) -> (int, bool),
	open:      proc(keys: ^Noise_Transport, ciphertext: []byte, dst: []byte) -> ([]byte, bool),
}

encryption_hooks: Encryption_Hooks
