package actod

import "base:intrinsics"
import "core:sync"

STAGING_DESTS :: 4
STAGING_BUF_SIZE :: 8192
STAGE_FRAME_MAX :: 1024

Staging_Entry :: struct {
	ring: ^Connection_Ring,
	len:  u32,
	cap:  u32,
	buf:  [STAGING_BUF_SIZE]byte,
}

Net_Staging :: struct {
	entries: [STAGING_DESTS]Staging_Entry,
}

@(thread_local)
net_staging: Net_Staging

staging_reserve :: proc(
	ring: ^Connection_Ring,
	size: u32,
) -> (
	dst: []byte,
	reserved: ^Staging_Entry,
	ok: bool,
) {
	entry := staging_entry_for(ring)
	if entry == nil || size > entry.cap do return nil, nil, false
	if entry.len + size > entry.cap {
		if !staging_flush_entry(entry) do return nil, nil, false
		staging_entry_reset(entry, ring)
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
staging_entry_reset :: proc(entry: ^Staging_Entry, ring: ^Connection_Ring) {
	entry.ring = ring
	entry.len = 0
	entry.cap = staging_entry_cap(ring)
}

@(private = "file")
staging_entry_cap :: proc(ring: ^Connection_Ring) -> u32 {
	return min(u32(STAGING_BUF_SIZE), ring.usable_slot_size)
}

@(private = "file")
staging_entry_for :: proc(ring: ^Connection_Ring) -> ^Staging_Entry {
	free_entry: ^Staging_Entry
	for &entry in net_staging.entries {
		if entry.ring == ring do return &entry
		if entry.ring == nil && free_entry == nil do free_entry = &entry
	}
	if free_entry == nil {
		free_entry = &net_staging.entries[0]
		for &entry in net_staging.entries {
			if entry.len > free_entry.len do free_entry = &entry
		}
		if !staging_flush_entry(free_entry) do return nil
	}
	staging_entry_reset(free_entry, ring)
	return free_entry
}

@(private = "file")
staging_flush_entry :: proc(entry: ^Staging_Entry) -> bool {
	if entry.ring == nil do return true
	if entry.len == 0 {
		entry.ring = nil
		return true
	}

	ring := entry.ring
	if sync.atomic_load(&ring.park_state) != .Active {
		if fresh := get_connection_ring(ring.node_id); fresh != nil do ring = fresh
	}

	if !batch_append_raw(ring, entry.buf[:entry.len]) do return false
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
