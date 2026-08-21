package actod

import "base:intrinsics"
import "core:encoding/endian"
import "core:sync"

STAGING_DESTS :: 4
STAGING_BUF_SIZE :: 8192
STAGE_FRAME_MAX :: 1024

Staging_Entry :: struct {
	ring:  ^Connection_Ring,
	len:   u32,
	cap:   u32,
	epoch: u32,
	buf:   [STAGING_BUF_SIZE]byte,
}

Net_Staging :: struct {
	entries: [STAGING_DESTS]Staging_Entry,
}

@(thread_local)
net_staging: Net_Staging

staging_reserve :: proc(
	ring: ^Connection_Ring,
	size: u32,
	epoch: u32,
) -> (
	dst: []byte,
	reserved: ^Staging_Entry,
	ok: bool,
) {
	entry := staging_entry_for(ring, epoch)
	if entry == nil || size > entry.cap do return nil, nil, false
	if entry.len + size > entry.cap {
		if !staging_flush_entry(entry) do return nil, nil, false
		staging_entry_reset(entry, ring, epoch)
	}
	offset := entry.len
	entry.len += size
	return entry.buf[offset:offset + size], entry, true
}

staging_unreserve :: proc(entry: ^Staging_Entry, size: u32) {
	if entry == nil || entry.len < size do return
	entry.len -= size
	if entry.len == 0 do entry.ring = nil
}

staging_flush_ring :: proc(ring: ^Connection_Ring) -> bool {
	for &entry in net_staging.entries {
		if entry.ring == ring do return staging_flush_entry(&entry)
	}
	return true
}

staging_flush_stale_node :: proc(node_id: Node_ID, epoch: u32) -> bool {
	for &entry in net_staging.entries {
		if entry.ring == nil || entry.ring.node_id != node_id do continue
		if entry.epoch == epoch do continue
		if !staging_flush_entry(&entry) do return false
	}
	return true
}

staging_flush_all :: proc() -> bool {
	all_clear := true
	for &entry in net_staging.entries {
		if entry.ring != nil && !staging_flush_entry(&entry) do all_clear = false
	}
	return all_clear
}

staging_has_pending :: #force_inline proc() -> bool {
	for &entry in net_staging.entries {
		if entry.ring != nil do return true
	}
	return false
}

@(private = "file")
staging_entry_reset :: proc(entry: ^Staging_Entry, ring: ^Connection_Ring, epoch: u32) {
	entry.ring = ring
	entry.len = 0
	entry.cap = staging_entry_cap(ring)
	entry.epoch = epoch
}

@(private = "file")
staging_entry_cap :: proc(ring: ^Connection_Ring) -> u32 {
	return min(u32(STAGING_BUF_SIZE), ring.usable_slot_size)
}

@(private = "file")
staging_entry_for :: proc(ring: ^Connection_Ring, epoch: u32) -> ^Staging_Entry {
	free_entry: ^Staging_Entry
	for &entry in net_staging.entries {
		if entry.ring == ring {
			if entry.epoch == epoch do return &entry
			if !staging_flush_entry(&entry) do return nil
			staging_entry_reset(&entry, ring, epoch)
			return &entry
		}
		if entry.ring == nil && free_entry == nil do free_entry = &entry
	}
	if free_entry == nil {
		free_entry = &net_staging.entries[0]
		for &entry in net_staging.entries {
			if entry.len > free_entry.len do free_entry = &entry
		}
		if !staging_flush_entry(free_entry) do return nil
	}
	staging_entry_reset(free_entry, ring, epoch)
	return free_entry
}

@(private = "file")
staging_frame_key :: proc(frame: []byte) -> u64 {
	if len(frame) < 4 + 18 do return 0
	handle_bits := endian.unchecked_get_u64le(frame[4 + 10:])
	return handle_bits
}

@(private = "file")
staging_reroute_frames :: proc(entry: ^Staging_Entry, pool: ^Connection_Pool) -> bool {
	blob := entry.buf[:entry.len]
	offset: u32 = 0
	for offset + 4 <= entry.len {
		size := endian.unchecked_get_u32le(blob[offset:])
		frame_end := offset + 4 + size
		if size == 0 || frame_end > entry.len do break
		frame := blob[offset:frame_end]
		if !batch_append_routed(pool, staging_frame_key(frame), frame) {
			remaining := entry.len - offset
			if offset > 0 do intrinsics.mem_copy(&entry.buf[0], &entry.buf[offset], int(remaining))
			entry.len = remaining
			return false
		}
		offset = frame_end
	}
	entry.len = 0
	entry.ring = nil
	return true
}

@(private = "file")
staging_flush_entry :: proc(entry: ^Staging_Entry) -> bool {
	if entry.ring == nil do return true
	if entry.len == 0 {
		entry.ring = nil
		return true
	}

	ring := entry.ring
	pool := ring.pool
	if pool != nil {
		if sync.atomic_load_explicit(&pool.epoch, .Acquire) == entry.epoch {
			appended, stale := batch_append_epoch(ring, entry.buf[:entry.len], pool, entry.epoch)
			if appended {
				entry.len = 0
				entry.ring = nil
				return true
			}
			if !stale do return false
		}
		return staging_reroute_frames(entry, pool)
	}

	if !batch_append_direct(ring, entry.buf[:entry.len]) do return false
	entry.len = 0
	entry.ring = nil
	return true
}

staging_drop_node_rings :: proc() {
	for &entry in net_staging.entries {
		ring := entry.ring
		if ring == nil do continue
		if !node_owns_ring(ring) do continue
		entry.ring = nil
		entry.len = 0
	}
}

@(private = "file")
node_owns_ring :: proc(ring: ^Connection_Ring) -> bool {
	nid := ring.node_id
	if nid >= MAX_NODES do return false
	if NODE.connection_rings[nid] == ring do return true
	pool := NODE.connection_pools[nid]
	if pool == nil do return false
	for i in 0 ..< MAX_POOL_RINGS {
		if pool.rings[i] == ring || pool.parked[i] == ring do return true
	}
	return false
}

staging_flush_before_park :: proc() -> bool {
	if !staging_has_pending() do return true
	for attempt := 0; attempt < 64; attempt += 1 {
		if staging_flush_all() do return true
		intrinsics.cpu_relax()
	}
	return false
}
