package actod

import "core:testing"

@(private = "file")
release_traffic_recorder :: proc(recorder: ^Traffic_Recorder) {
	if recorder.tally == nil do return
	delete(recorder.tally.counts)
	free(recorder.tally, recorder.allocator)
}

@(test)
test_traffic_tally_counts_survive_batch_folds :: proc(t: ^testing.T) {
	recorder := Traffic_Recorder {
		allocator = context.allocator,
	}
	defer release_traffic_recorder(&recorder)

	empty_histogram := take_traffic_histogram(&recorder)
	defer delete(empty_histogram)
	testing.expect_value(t, len(empty_histogram), 0)
	testing.expect(
		t,
		recorder.tally == nil,
		"a recorder with no traffic should not allocate a tally",
	)

	frequent_peer := PID(7)
	rare_peer := PID(9)
	frequent_messages := 3 * TRAFFIC_BATCH_LENGTH + 5
	for _ in 0 ..< frequent_messages do record_traffic(&recorder, frequent_peer)
	record_traffic(&recorder, rare_peer)

	histogram := take_traffic_histogram(&recorder)
	defer delete(histogram)

	testing.expect_value(t, len(histogram), 2)
	testing.expect_value(t, histogram[frequent_peer], u64(frequent_messages))
	testing.expect_value(t, histogram[rare_peer], u64(1))
	testing.expect_value(t, recorder.free_slots, TRAFFIC_BATCH_LENGTH)
	testing.expect_value(t, len(recorder.tally.counts), 0)

	record_traffic(&recorder, rare_peer)
	next_histogram := take_traffic_histogram(&recorder)
	defer delete(next_histogram)
	testing.expect_value(t, len(next_histogram), 1)
	testing.expect_value(t, next_histogram[rare_peer], u64(1))
}

@(test)
test_traffic_tally_folds_peers_past_the_limit_into_the_unlisted_bucket :: proc(
	t: ^testing.T,
) {
	recorder := Traffic_Recorder {
		allocator = context.allocator,
	}
	defer release_traffic_recorder(&recorder)

	unlisted_peers := 10
	for peer in 1 ..= TRAFFIC_PEER_LIMIT + unlisted_peers do record_traffic(&recorder, PID(peer))
	record_traffic(&recorder, PID(1))
	record_traffic(&recorder, PID(TRAFFIC_PEER_LIMIT + 1))

	histogram := take_traffic_histogram(&recorder)
	defer delete(histogram)

	testing.expect_value(t, len(histogram), TRAFFIC_PEER_LIMIT + 1)
	testing.expect_value(t, histogram[PID(1)], u64(2))
	testing.expect_value(t, histogram[PID(TRAFFIC_PEER_LIMIT)], u64(1))
	testing.expect_value(
		t,
		histogram[UNLISTED_TRAFFIC_PEER],
		u64(unlisted_peers + 1),
	)
	testing.expect(
		t,
		PID(TRAFFIC_PEER_LIMIT + 1) not_in histogram,
		"a peer past the limit should only count in the unlisted bucket",
	)
	testing.expect_value(t, recorder.tally.unlisted_peer_messages, 0)
}
