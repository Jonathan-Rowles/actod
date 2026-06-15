package actod

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/noise"
import "core:encoding/endian"

NOISE_PROTOCOL_NAME :: "Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s"

CLUSTER_PSK_SIZE :: noise.PSK_SIZE
ENVELOPE_TAG_SIZE :: noise.TAG_SIZE
ENVELOPE_OVERHEAD :: 4 + ENVELOPE_TAG_SIZE
MAX_ENVELOPE_PLAINTEXT :: noise.MAX_PACKET_SIZE - noise.TAG_SIZE

Noise_Transport :: noise.Cipher_States
Noise_Handshake :: noise.Handshake_State

derive_cluster_psk :: proc(password: string) -> [CLUSTER_PSK_SIZE]byte {
	psk: [CLUSTER_PSK_SIZE]byte
	hash.hash_string_to_buffer(.SHA256, password, psk[:])
	return psk
}

noise_handshake_begin :: proc(
	hs: ^Noise_Handshake,
	initiator: bool,
	prologue: []byte,
	psk: []byte,
) -> bool {
	return noise.handshake_init(hs, initiator, prologue, nil, nil, NOISE_PROTOCOL_NAME, psk) == .Ok
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
	if msg != nil {
		delete(msg, allocator)
	}
	return nil, false, false
}

noise_handshake_finish :: proc(hs: ^Noise_Handshake, keys: ^Noise_Transport) -> bool {
	ok := noise.handshake_split(hs, keys) == .Ok
	noise.handshake_reset(hs)
	return ok
}

// Wire: [inner_len:u32][ciphertext = seal(plaintext)], implicit counter nonces.
envelope_seal :: proc(keys: ^Noise_Transport, plaintext: []byte, dst: []byte) -> (int, bool) {
	if len(plaintext) == 0 || len(plaintext) > MAX_ENVELOPE_PLAINTEXT {
		return 0, false
	}
	total := ENVELOPE_OVERHEAD + len(plaintext)
	if total > len(dst) {
		return 0, false
	}
	endian.put_u32(dst[0:4], .Little, u32(len(plaintext) + ENVELOPE_TAG_SIZE))
	_, status := noise.seal_message(keys, nil, plaintext, dst[4:total])
	return total, status == .Ok
}

envelope_open :: proc(keys: ^Noise_Transport, ciphertext: []byte, dst: []byte) -> ([]byte, bool) {
	if len(ciphertext) <= ENVELOPE_TAG_SIZE {
		return nil, false
	}
	pt_len := len(ciphertext) - ENVELOPE_TAG_SIZE
	if pt_len > len(dst) {
		return nil, false
	}
	_, status := noise.open_message(keys, nil, ciphertext, dst[:pt_len])
	return dst[:pt_len], status == .Ok
}

UDP_SEED_SIZE :: 32
UDP_KEY_SIZE :: 32
UDP_TAG_SIZE :: 16
UDP_NONCE_SIZE :: 12

Udp_Keys :: struct {
	send_key: [UDP_KEY_SIZE]byte,
	recv_key: [UDP_KEY_SIZE]byte,
}

derive_udp_keys :: proc(seed: []byte, initiator: bool) -> (keys: Udp_Keys) {
	salt := transmute([]byte)string("actod-udp-v2")
	info_i2r := transmute([]byte)string("initiator-to-responder")
	info_r2i := transmute([]byte)string("responder-to-initiator")
	i2r, r2i: [UDP_KEY_SIZE]byte
	hkdf.extract_and_expand(.SHA256, salt, seed, info_i2r, i2r[:])
	hkdf.extract_and_expand(.SHA256, salt, seed, info_r2i, r2i[:])
	if initiator {
		keys.send_key = i2r
		keys.recv_key = r2i
	} else {
		keys.send_key = r2i
		keys.recv_key = i2r
	}
	return keys
}

udp_nonce :: #force_inline proc(seq: u64) -> [UDP_NONCE_SIZE]byte {
	iv: [UDP_NONCE_SIZE]byte
	endian.put_u64(iv[4:12], .Little, seq)
	return iv
}

udp_seal :: proc(key: []byte, seq: u64, aad: []byte, plaintext: []byte, dst: []byte) -> (int, bool) {
	total := len(plaintext) + UDP_TAG_SIZE
	if len(plaintext) == 0 || total > len(dst) {
		return 0, false
	}
	iv := udp_nonce(seq)
	aead.seal_oneshot(
		.CHACHA20POLY1305,
		dst[:len(plaintext)],
		dst[len(plaintext):total],
		key,
		iv[:],
		aad,
		plaintext,
	)
	return total, true
}

udp_open :: proc(key: []byte, seq: u64, aad: []byte, sealed: []byte, dst: []byte) -> ([]byte, bool) {
	if len(sealed) <= UDP_TAG_SIZE {
		return nil, false
	}
	pt_len := len(sealed) - UDP_TAG_SIZE
	if pt_len > len(dst) {
		return nil, false
	}
	iv := udp_nonce(seq)
	ok := aead.open_oneshot(
		.CHACHA20POLY1305,
		dst[:pt_len],
		key,
		iv[:],
		aad,
		sealed[:pt_len],
		sealed[pt_len:],
	)
	return dst[:pt_len], ok
}

UDP_REPLAY_WINDOW :: 64

// Sequence numbers start at 1; seq 0 is never valid.
Replay_Window :: struct {
	max_seq: u64,
	mask:    u64,
}

// Check before authenticating; commit only after the datagram authenticates,
// so forged sequence numbers cannot advance the window.
replay_check :: proc(w: ^Replay_Window, seq: u64) -> bool {
	if seq == 0 {
		return false
	}
	if seq > w.max_seq {
		return true
	}
	offset := w.max_seq - seq
	if offset >= UDP_REPLAY_WINDOW {
		return false
	}
	return w.mask & (u64(1) << offset) == 0
}

replay_commit :: proc(w: ^Replay_Window, seq: u64) {
	if seq > w.max_seq {
		shift := seq - w.max_seq
		w.mask = shift >= UDP_REPLAY_WINDOW ? 0 : w.mask << shift
		w.mask |= 1
		w.max_seq = seq
		return
	}
	w.mask |= u64(1) << (w.max_seq - seq)
}

replay_accept :: proc(w: ^Replay_Window, seq: u64) -> bool {
	if !replay_check(w, seq) {
		return false
	}
	replay_commit(w, seq)
	return true
}

generate_udp_seed :: proc() -> [UDP_SEED_SIZE]byte {
	seed: [UDP_SEED_SIZE]byte
	crypto.rand_bytes(seed[:])
	return seed
}

generate_udp_token :: proc() -> u32 {
	buf: [4]byte
	token: u32
	for token == 0 {
		crypto.rand_bytes(buf[:])
		token = endian.unchecked_get_u32le(buf[:])
	}
	return token
}
