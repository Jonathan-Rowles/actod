package actod

import "core:testing"

@(test)
test_noise_handshake_and_envelope :: proc(t: ^testing.T) {
	psk := derive_cluster_psk("cluster-secret")
	prologue := []byte{'a', 'c', 't', 'o', 'd', '/', '2'}

	dialer, listener: Noise_Handshake
	testing.expect(t, noise_handshake_begin(&dialer, true, prologue, psk[:]), "dialer init")
	testing.expect(t, noise_handshake_begin(&listener, false, prologue, psk[:]), "listener init")

	msg1, done1, ok1 := noise_handshake_step(&dialer, nil)
	defer delete(msg1)
	testing.expect(t, ok1 && !done1 && msg1 != nil, "dialer step 1 should produce msg1")

	msg2, done2, ok2 := noise_handshake_step(&listener, msg1)
	defer delete(msg2)
	testing.expect(t, ok2 && done2 && msg2 != nil, "listener step should complete with msg2")

	out3, done3, ok3 := noise_handshake_step(&dialer, msg2)
	testing.expect(t, ok3 && done3 && out3 == nil, "dialer step 2 should complete with no output")

	dialer_keys, listener_keys: Noise_Transport
	testing.expect(t, noise_handshake_finish(&dialer, &dialer_keys), "dialer split")
	testing.expect(t, noise_handshake_finish(&listener, &listener_keys), "listener split")

	payload := transmute([]byte)string("ping over sealed channel")
	sealed: [256]byte
	n, seal_ok := envelope_seal(&dialer_keys, payload, sealed[:])
	testing.expect(t, seal_ok, "seal should succeed")
	testing.expect(t, n == ENVELOPE_OVERHEAD + len(payload), "sealed size mismatch")

	opened: [256]byte
	pt, open_ok := envelope_open(&listener_keys, sealed[4:n], opened[:])
	testing.expect(t, open_ok, "open should succeed")
	testing.expect(t, string(pt) == string(payload), "roundtrip payload mismatch")

	reply := transmute([]byte)string("pong")
	n2, seal2_ok := envelope_seal(&listener_keys, reply, sealed[:])
	testing.expect(t, seal2_ok, "reverse seal should succeed")
	pt2, open2_ok := envelope_open(&dialer_keys, sealed[4:n2], opened[:])
	testing.expect(t, open2_ok && string(pt2) == string(reply), "reverse roundtrip mismatch")
}

@(test)
test_noise_handshake_wrong_psk_fails :: proc(t: ^testing.T) {
	good := derive_cluster_psk("right-password")
	bad := derive_cluster_psk("wrong-password")
	prologue := []byte{'a', 'c', 't', 'o', 'd', '/', '2'}

	dialer, listener: Noise_Handshake
	testing.expect(t, noise_handshake_begin(&dialer, true, prologue, good[:]), "dialer init")
	testing.expect(t, noise_handshake_begin(&listener, false, prologue, bad[:]), "listener init")

	msg1, _, ok1 := noise_handshake_step(&dialer, nil)
	defer delete(msg1)
	testing.expect(t, ok1, "dialer step 1")

	_, _, ok2 := noise_handshake_step(&listener, msg1)
	testing.expect(t, !ok2, "listener must reject msg1 sealed under a different psk")
}

@(test)
test_noise_handshake_prologue_mismatch_fails :: proc(t: ^testing.T) {
	psk := derive_cluster_psk("cluster-secret")

	dialer, listener: Noise_Handshake
	testing.expect(t, noise_handshake_begin(&dialer, true, []byte{1}, psk[:]), "dialer init")
	testing.expect(t, noise_handshake_begin(&listener, false, []byte{2}, psk[:]), "listener init")

	msg1, _, ok1 := noise_handshake_step(&dialer, nil)
	defer delete(msg1)
	testing.expect(t, ok1, "dialer step 1")

	_, _, ok2 := noise_handshake_step(&listener, msg1)
	testing.expect(t, !ok2, "listener must reject when prologue differs")
}

@(test)
test_envelope_tamper_fails :: proc(t: ^testing.T) {
	psk := derive_cluster_psk("s")
	dialer, listener: Noise_Handshake
	_ = noise_handshake_begin(&dialer, true, nil, psk[:])
	_ = noise_handshake_begin(&listener, false, nil, psk[:])
	msg1, _, _ := noise_handshake_step(&dialer, nil)
	defer delete(msg1)
	msg2, _, _ := noise_handshake_step(&listener, msg1)
	defer delete(msg2)
	_, _, _ = noise_handshake_step(&dialer, msg2)
	dialer_keys, listener_keys: Noise_Transport
	_ = noise_handshake_finish(&dialer, &dialer_keys)
	_ = noise_handshake_finish(&listener, &listener_keys)

	payload := transmute([]byte)string("do not touch")
	sealed: [128]byte
	n, _ := envelope_seal(&dialer_keys, payload, sealed[:])
	sealed[8] ~= 0xFF

	opened: [128]byte
	_, open_ok := envelope_open(&listener_keys, sealed[4:n], opened[:])
	testing.expect(t, !open_ok, "tampered envelope must not open")
}

@(test)
test_udp_keys_are_complementary :: proc(t: ^testing.T) {
	seed := generate_udp_seed()
	initiator_keys := derive_udp_keys(seed[:], true)
	responder_keys := derive_udp_keys(seed[:], false)

	testing.expect(t, initiator_keys.send_key == responder_keys.recv_key, "i.send == r.recv")
	testing.expect(t, initiator_keys.recv_key == responder_keys.send_key, "i.recv == r.send")
	testing.expect(t, initiator_keys.send_key != initiator_keys.recv_key, "directions must differ")
}

@(test)
test_udp_seal_open_roundtrip :: proc(t: ^testing.T) {
	seed := generate_udp_seed()
	sender := derive_udp_keys(seed[:], true)
	receiver := derive_udp_keys(seed[:], false)

	aad := []byte{0xAA, 0xBB, 0xCC, 0xDD}
	payload := transmute([]byte)string("unreliable but authentic")

	sealed: [128]byte
	n, seal_ok := udp_seal(sender.send_key[:], 7, aad, payload, sealed[:])
	testing.expect(t, seal_ok && n == len(payload) + UDP_TAG_SIZE, "udp seal")

	opened: [128]byte
	pt, open_ok := udp_open(receiver.recv_key[:], 7, aad, sealed[:n], opened[:])
	testing.expect(t, open_ok && string(pt) == string(payload), "udp open roundtrip")

	_, wrong_seq := udp_open(receiver.recv_key[:], 8, aad, sealed[:n], opened[:])
	testing.expect(t, !wrong_seq, "wrong seq must fail")

	bad_aad := []byte{0xAA, 0xBB, 0xCC, 0xDE}
	_, wrong_aad := udp_open(receiver.recv_key[:], 7, bad_aad, sealed[:n], opened[:])
	testing.expect(t, !wrong_aad, "wrong aad must fail")

	sealed[0] ~= 0x01
	_, tampered := udp_open(receiver.recv_key[:], 7, aad, sealed[:n], opened[:])
	testing.expect(t, !tampered, "tampered ciphertext must fail")
}

@(test)
test_replay_window :: proc(t: ^testing.T) {
	w: Replay_Window

	testing.expect(t, !replay_accept(&w, 0), "seq 0 always rejected")
	testing.expect(t, replay_accept(&w, 1), "first seq accepted")
	testing.expect(t, !replay_accept(&w, 1), "duplicate rejected")
	testing.expect(t, replay_accept(&w, 5), "forward jump accepted")
	testing.expect(t, replay_accept(&w, 3), "in-window reorder accepted")
	testing.expect(t, !replay_accept(&w, 3), "reordered duplicate rejected")
	testing.expect(t, replay_accept(&w, 200), "large jump accepted")
	testing.expect(t, !replay_accept(&w, 5), "beyond window rejected")
	testing.expect(t, !replay_accept(&w, 200 - UDP_REPLAY_WINDOW), "edge beyond window rejected")
	testing.expect(t, replay_accept(&w, 200 - UDP_REPLAY_WINDOW + 1), "oldest in-window accepted")
}
