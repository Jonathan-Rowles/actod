package actod

import "core:crypto"
import "core:crypto/argon2id"
import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:crypto/noise"
import "core:encoding/endian"
import "core:log"
import "core:sync"

NOISE_PROTOCOL_NAME :: "Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s"

CLUSTER_PSK_SIZE :: noise.PSK_SIZE
ENVELOPE_TAG_SIZE :: noise.TAG_SIZE
ENVELOPE_OVERHEAD :: 4 + ENVELOPE_TAG_SIZE
MAX_ENVELOPE_PLAINTEXT :: noise.MAX_PACKET_SIZE - noise.TAG_SIZE

Noise_Transport :: noise.Cipher_States
Noise_Handshake :: noise.Handshake_State

CLUSTER_PSK_SALT :: "actod-cluster-psk-v2"
CLUSTER_PSK_ARGON2_MEMORY_KIB :: 65536
CLUSTER_PSK_ARGON2_PASSES :: 3
CLUSTER_PSK_ARGON2_PARALLELISM :: 1

Cluster_Psk_State :: struct {
	psk:   [CLUSTER_PSK_SIZE]byte,
	key:   [32]byte,
	set:   bool,
	mutex: sync.Mutex,
}

derive_cluster_psk :: proc(password: string) -> ([CLUSTER_PSK_SIZE]byte, bool) {
	cache_key: [32]byte
	hash.hash_string_to_buffer(.SHA256, password, cache_key[:])

	sync.mutex_lock(&NODE.cluster_psk.mutex)
	defer sync.mutex_unlock(&NODE.cluster_psk.mutex)

	if !NODE.cluster_psk.set || NODE.cluster_psk.key != cache_key {
		params := argon2id.Parameters {
			memory_size = CLUSTER_PSK_ARGON2_MEMORY_KIB,
			passes      = CLUSTER_PSK_ARGON2_PASSES,
			parallelism = CLUSTER_PSK_ARGON2_PARALLELISM,
		}
		err := argon2id.derive(
			&params,
			transmute([]byte)password,
			transmute([]byte)string(CLUSTER_PSK_SALT),
			NODE.cluster_psk.psk[:],
			allocator = get_system_allocator(),
		)
		if err != nil {
			log.errorf("Failed to derive cluster PSK: %v", err)
			NODE.cluster_psk.psk = {}
			NODE.cluster_psk.key = {}
			NODE.cluster_psk.set = false
			return {}, false
		}
		NODE.cluster_psk.key = cache_key
		NODE.cluster_psk.set = true
	}

	return NODE.cluster_psk.psk, true
}

noise_handshake_begin :: proc(
	hs: ^Noise_Handshake,
	initiator: bool,
	prologue: []byte,
	psk: []byte,
) -> bool {
	eph_bytes: [32]byte
	actod_rand_bytes(eph_bytes[:])
	eph: ecdh.Private_Key
	if !ecdh.private_key_set_bytes(&eph, .X25519, eph_bytes[:]) do return false
	crypto.zero_explicit(raw_data(eph_bytes[:]), len(eph_bytes))
	return(
		noise.handshake_init(hs, initiator, prologue, nil, nil, NOISE_PROTOCOL_NAME, psk, &eph) ==
		.Ok \
	)
}

noise_handshake_step :: proc(
	hs: ^Noise_Handshake,
	input: []byte,
	allocator := context.allocator,
) -> (
	out_msg: []byte,
	done: bool,
	ok: bool,
) {
	msg: []byte
	status: noise.Status
	if hs.initiator {
		msg, _, status = noise.handshake_initiator_step(hs, input, nil, nil, allocator)
	} else {
		msg, _, status = noise.handshake_responder_step(hs, input, nil, nil, allocator)
	}
	#partial switch status {
	case .Handshake_Pending:
		return msg, false, true
	case .Handshake_Complete:
		return msg, true, true
	}
	if msg != nil do delete(msg, allocator)
	return nil, false, false
}

noise_handshake_finish :: proc(hs: ^Noise_Handshake, keys: ^Noise_Transport) -> bool {
	ok := noise.handshake_split(hs, keys) == .Ok
	noise.handshake_reset(hs)
	return ok
}

// Wire: [inner_len:u32][ciphertext = seal(plaintext)], implicit counter nonces.
envelope_seal :: proc(keys: ^Noise_Transport, plaintext: []byte, dst: []byte) -> (int, bool) {
	if len(plaintext) == 0 || len(plaintext) > MAX_ENVELOPE_PLAINTEXT do return 0, false
	total := ENVELOPE_OVERHEAD + len(plaintext)
	if total > len(dst) do return 0, false
	endian.put_u32(dst[0:4], .Little, u32(len(plaintext) + ENVELOPE_TAG_SIZE))
	_, status := noise.seal_message(keys, nil, plaintext, dst[4:total])
	return total, status == .Ok
}

envelope_open :: proc(keys: ^Noise_Transport, ciphertext: []byte, dst: []byte) -> ([]byte, bool) {
	if len(ciphertext) <= ENVELOPE_TAG_SIZE do return nil, false
	pt_len := len(ciphertext) - ENVELOPE_TAG_SIZE
	if pt_len > len(dst) do return nil, false
	_, status := noise.open_message(keys, nil, ciphertext, dst[:pt_len])
	return dst[:pt_len], status == .Ok
}
