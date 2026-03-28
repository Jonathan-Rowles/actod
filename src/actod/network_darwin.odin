#+build darwin
package actod

import "core:net"

foreign import libc "system:System.framework"

IPPROTO_TCP :: 6
TCP_NODELAY :: 1
SOL_SOCKET :: 0xffff
SO_RCVBUF :: 0x1002
SO_SNDBUF :: 0x1001
SO_RCVTIMEO :: 0x1006
POLLIN :: 0x0001

Poll_Fd :: struct {
	fd:      i32,
	events:  i16,
	revents: i16,
}

foreign libc {
	@(link_name = "setsockopt")
	libc_setsockopt :: proc(sockfd: i32, level: i32, optname: i32, optval: rawptr, optlen: u32) -> i32 ---
	@(link_name = "poll")
	libc_poll :: proc(fds: [^]Poll_Fd, nfds: u32, timeout: i32) -> i32 ---
	@(link_name = "arc4random_buf")
	libc_arc4random_buf :: proc(buf: rawptr, nbytes: uint) ---
}

platform_setsockopt :: #force_inline proc(sock: net.TCP_Socket, level: i32, optname: i32, optval: rawptr, optlen: i32) -> i32 {
	return libc_setsockopt(i32(sock), level, optname, optval, u32(optlen))
}
platform_poll :: #force_inline proc(fds: ^Poll_Fd, nfds: u32, timeout: i32) -> i32 {
	return libc_poll(([^]Poll_Fd)(fds), nfds, timeout)
}
platform_socket_fd :: #force_inline proc(sock: net.TCP_Socket) -> i32 {
	return i32(sock)
}
platform_gen_random :: proc(buf: rawptr, len: uint) {
	libc_arc4random_buf(buf, len)
}

Timeval :: struct {
	tv_sec:  i64,
	tv_usec: i64,
}

platform_set_recv_timeout :: proc(sock: net.TCP_Socket, seconds: i64) -> bool {
	tv := Timeval {
		tv_sec  = seconds,
		tv_usec = 0,
	}
	return platform_setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, size_of(Timeval)) == 0
}
