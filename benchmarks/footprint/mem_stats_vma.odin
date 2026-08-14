#+build linux, darwin
package footprint

import "core:fmt"
import "core:slice"

Vma_Bucket :: struct {
	size_kb: int,
	perms:   string,
	count:   int,
}

accumulate_vma_bucket :: proc(buckets: ^[dynamic]Vma_Bucket, size_kb: int, perms: string) {
	for &b in buckets {
		if b.size_kb == size_kb && b.perms == perms {
			b.count += 1
			return
		}
	}
	append(buckets, Vma_Bucket{size_kb = size_kb, perms = perms, count = 1})
}

print_vma_breakdown :: proc(top: int) {
	buckets := make([dynamic]Vma_Bucket)
	defer delete(buckets)

	vma_regions(proc(size_kb: int, perms: string, user: rawptr) {
		accumulate_vma_bucket(cast(^[dynamic]Vma_Bucket)user, size_kb, perms)
	}, &buckets)

	slice.sort_by(buckets[:], proc(a: Vma_Bucket, b: Vma_Bucket) -> bool {
		return a.count > b.count
	})

	fmt.println()
	fmt.println("--- VMA breakdown (top buckets by count) ---")
	shown := min(top, len(buckets))
	for i in 0 ..< shown {
		b := buckets[i]
		fmt.printf("%8d x %8d KB  %s\n", b.count, b.size_kb, b.perms)
	}
}
