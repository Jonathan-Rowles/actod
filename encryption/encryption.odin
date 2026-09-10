package encryption

import actod "../src/actod"
import "core:crypto"
import "core:crypto/argon2id"
import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:crypto/noise"
import "core:encoding/endian"
import "core:log"
import "core:net"
import "core:sync"
import "core:time"

@(init)
install_hooks :: proc "contextless" () {
	actod.encryption_hooks = actod.Encryption_Hooks {
		handshake = run_noise_handshake,
		seal      = envelope_seal,
		open      = envelope_open,
	}
}

NOISE_PROTOCOL_NAME :: "Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s"

CLUSTER_PSK_SIZE :: noise.PSK_SIZE
ENVELOPE_TAG_SIZE :: noise.TAG_SIZE

Noise_Transport :: noise.Cipher_States
Noise_Handshake :: noise.Handshake_State

#assert(size_of(actod.Noise_Transport) == size_of(Noise_Transport))
#assert(align_of(actod.Noise_Transport) == align_of(Noise_Transport))
#assert(actod.ENVELOPE_TAG_SIZE == noise.TAG_SIZE)
#assert(actod.MAX_ENVELOPE_PLAINTEXT == noise.MAX_PACKET_SIZE - noise.TAG_SIZE)
ENVELOPE_OVERHEAD :: actod.ENVELOPE_OVERHEAD
MAX_ENVELOPE_PLAINTEXT :: actod.MAX_ENVELOPE_PLAINTEXT

cluster_psk: Cluster_Psk_State

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

	sync.mutex_lock(&cluster_psk.mutex)
	defer sync.mutex_unlock(&cluster_psk.mutex)

	if !cluster_psk.set || cluster_psk.key != cache_key {
		params := argon2id.Parameters {
			memory_size = CLUSTER_PSK_ARGON2_MEMORY_KIB,
			passes      = CLUSTER_PSK_ARGON2_PASSES,
			parallelism = CLUSTER_PSK_ARGON2_PARALLELISM,
		}
		err := argon2id.derive(
			&params,
			transmute([]byte)password,
			transmute([]byte)string(CLUSTER_PSK_SALT),
			cluster_psk.psk[:],
			allocator = actod.get_system_allocator(),
		)
		if err != nil {
			log.errorf("Failed to derive cluster PSK: %v", err)
			cluster_psk.psk = {}
			cluster_psk.key = {}
			cluster_psk.set = false
			return {}, false
		}
		cluster_psk.key = cache_key
		cluster_psk.set = true
	}

	return cluster_psk.psk, true
}

noise_handshake_begin :: proc(
	hs: ^Noise_Handshake,
	initiator: bool,
	prologue: []byte,
	psk: []byte,
) -> bool {
	eph_bytes: [32]byte
	actod.actod_rand_bytes(eph_bytes[:])
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

noise_handshake_finish :: proc(hs: ^Noise_Handshake, keys: ^actod.Noise_Transport) -> bool {
	ok := noise.handshake_split(hs, cast(^Noise_Transport)keys) == .Ok
	noise.handshake_reset(hs)
	return ok
}

envelope_seal :: proc(keys: ^actod.Noise_Transport, plaintext: []byte, dst: []byte) -> (int, bool) {
	if len(plaintext) == 0 || len(plaintext) > MAX_ENVELOPE_PLAINTEXT do return 0, false
	total := ENVELOPE_OVERHEAD + len(plaintext)
	if total > len(dst) do return 0, false
	endian.put_u32(dst[0:4], .Little, u32(len(plaintext) + ENVELOPE_TAG_SIZE))
	_, status := noise.seal_message(cast(^Noise_Transport)keys, nil, plaintext, dst[4:total])
	return total, status == .Ok
}

envelope_open :: proc(keys: ^actod.Noise_Transport, ciphertext: []byte, dst: []byte) -> ([]byte, bool) {
	if len(ciphertext) <= ENVELOPE_TAG_SIZE do return nil, false
	pt_len := len(ciphertext) - ENVELOPE_TAG_SIZE
	if pt_len > len(dst) do return nil, false
	_, status := noise.open_message(cast(^Noise_Transport)keys, nil, ciphertext, dst[:pt_len])
	return dst[:pt_len], status == .Ok
}

run_noise_handshake :: proc(
	auth_password: string,
	sock: net.TCP_Socket,
	initiator: bool,
	my_hello: []byte,
	peer_hello: []byte,
	keys: ^actod.Noise_Transport,
	deadline: time.Time,
) -> bool {
	psk, psk_ok := derive_cluster_psk(auth_password)
	if !psk_ok {
		log.error("Refusing encrypted handshake: cluster PSK derivation failed")
		return false
	}

	dialer_body := my_hello if initiator else peer_hello
	responder_body := peer_hello if initiator else my_hello
	prologue := make([]byte, len(dialer_body) + len(responder_body))
	defer delete(prologue)
	copy(prologue, dialer_body)
	copy(prologue[len(dialer_body):], responder_body)

	hs: Noise_Handshake
	if !noise_handshake_begin(&hs, initiator, prologue, psk[:]) {
		log.error("Failed to initialize noise handshake")
		return false
	}

	if initiator {
		msg1, _, ok1 := noise_handshake_step(&hs, nil)
		if !ok1 || msg1 == nil do return false
		sent1 := send_noise_ctrl(sock, actod.CTRL_MSG_NOISE_1, msg1)
		delete(msg1)
		if !sent1 do return false

		raw2, payload2 := actod.handshake_recv_ctrl(sock, actod.CTRL_MSG_NOISE_2, deadline)
		if raw2 == nil {
			log.warn("Did not receive noise response from peer")
			return false
		}
		defer delete(raw2, actod.get_system_allocator())

		out, done, ok2 := noise_handshake_step(&hs, payload2[1:])
		if out != nil do delete(out)
		if !ok2 || !done {
			log.error("Noise handshake failed (wrong cluster password?)")
			return false
		}
	} else {
		raw1, payload1 := actod.handshake_recv_ctrl(sock, actod.CTRL_MSG_NOISE_1, deadline)
		if raw1 == nil {
			log.warn("Did not receive noise initiation from peer")
			return false
		}
		defer delete(raw1, actod.get_system_allocator())

		msg2, done, ok2 := noise_handshake_step(&hs, payload1[1:])
		if !ok2 || !done || msg2 == nil {
			log.error("Noise handshake failed (wrong cluster password?)")
			return false
		}
		sent2 := send_noise_ctrl(sock, actod.CTRL_MSG_NOISE_2, msg2)
		delete(msg2)
		if !sent2 do return false
	}

	return noise_handshake_finish(&hs, keys)
}

send_noise_ctrl :: proc(sock: net.TCP_Socket, ctrl_type: u8, msg: []byte) -> bool {
	body := make([]byte, 1 + len(msg))
	defer delete(body)
	body[0] = ctrl_type
	copy(body[1:], msg)
	return actod.handshake_send_ctrl(sock, body)
}
