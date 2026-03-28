#+build windows
package actod

import "core:net"
import win32 "core:sys/windows"

IPPROTO_TCP :: 6
TCP_NODELAY :: 1
SOL_SOCKET :: 0xffff
SO_RCVBUF :: 0x1002
SO_SNDBUF :: 0x1001
SO_RCVTIMEO :: 0x1006
POLLIN :: 0x0300

Poll_Fd :: struct {
	fd:      win32.SOCKET,
	events:  i16,
	revents: i16,
}

platform_setsockopt :: #force_inline proc(
	sock: net.TCP_Socket,
	level: i32,
	optname: i32,
	optval: rawptr,
	optlen: i32,
) -> i32 {
	return win32.setsockopt(win32.SOCKET(sock), level, optname, optval, optlen)
}

platform_poll :: #force_inline proc(fds: ^Poll_Fd, nfds: u32, timeout: i32) -> i32 {
	return win32.WSAPoll(cast(^win32.WSA_POLLFD)fds, win32.c_ulong(nfds), timeout)
}

platform_socket_fd :: #force_inline proc(sock: net.TCP_Socket) -> win32.SOCKET {
	return win32.SOCKET(sock)
}

platform_gen_random :: proc(buf: rawptr, len: uint) {
	win32.RtlGenRandom(cast(^u8)buf, win32.ULONG(len))
}

platform_set_recv_timeout :: proc(sock: net.TCP_Socket, seconds: i64) -> bool {
	timeout_ms: u32 = u32(seconds * 1000)
	return platform_setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout_ms, size_of(u32)) == 0
}
