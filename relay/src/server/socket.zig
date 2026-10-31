//! Setting up sockets: the relay's listeners, and the options every connection it accepts gets.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// The most that's not yet on its way a connection's socket holds: past it, what's queued waits in the outbox.
const unsent_limit = 16 * 1024;
/// TCP_NOTSENT_LOWAT, which std doesn't name for macOS.
const tcp_notsent_lowat: u32 = if (builtin.os.tag == .linux) std.os.linux.TCP.NOTSENT_LOWAT else 0x201;

/// A non-blocking TCP listener on `address`, with room for a burst of connections, as after a network blip. With
/// `reuse_port`, others can listen on the same port, and Linux spreads connections across them.
pub fn listen(address: std.Io.net.Ip4Address, reuse_port: bool) !c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemResources;
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    if (reuse_port) _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, &one, @sizeOf(c_int));
    var sockaddr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.bytes) };
    if (c.bind(fd, @ptrCast(&sockaddr), @sizeOf(c.sockaddr.in)) < 0) return error.AddressInUse;
    if (c.listen(fd, 4096) < 0) return error.SystemResources;
    try setNonblocking(fd);
    return fd;
}

/// A non-blocking UDP socket on `address`, for presence (udp.zig), with room for bursts. With
/// `reuse_port`, each loop has its own, and `steerByLoop` sends each datagram to its connection's loop.
pub fn bindUdp(address: std.Io.net.Ip4Address, reuse_port: bool) !c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
    if (fd < 0) return error.SystemResources;
    const one: c_int = 1;
    if (reuse_port) _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, &one, @sizeOf(c_int));
    const buffer: c_int = 4 << 20;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &buffer, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &buffer, @sizeOf(c_int));
    var sockaddr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.bytes) };
    if (c.bind(fd, @ptrCast(&sockaddr), @sizeOf(c.sockaddr.in)) < 0) return error.AddressInUse;
    try setNonblocking(fd);
    return fd;
}

/// On Linux, sends each datagram on a reuse-port group to the socket of the loop its connection ID names: the ID's
/// last byte (it's little-endian), the sockets joining in loop order. Classic BPF, from the UDP payload: A = byte 7;
/// return A.
pub fn steerByLoop(fd: c.fd_t) !void {
    const Insn = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
    const program = [_]Insn{ .{ .code = 0x30, .k = 7 }, .{ .code = 0x16, .k = 0 } };
    const Fprog = extern struct { len: u16, filter: [*]const Insn };
    const fprog: Fprog = .{ .len = program.len, .filter = &program };
    const so_attach_reuseport_cbpf = 51;
    if (c.setsockopt(fd, c.SOL.SOCKET, so_attach_reuseport_cbpf, &fprog, @sizeOf(Fprog)) < 0) return error.Unsupported;
}

/// A connection just accepted: non-blocking, small messages sent at once, and little waiting in the kernel.
pub fn configure(fd: c.fd_t) !void {
    try setNonblocking(fd);
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &one, @sizeOf(c_int));
    if (builtin.os.tag.isDarwin()) _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    // Little that isn't on its way yet waits in the kernel: what a slow connection is behind on waits in the relay,
    // where pointer updates can be replaced by newer ones. What's in flight isn't limited, so fast links stay fast.
    const unsent: c_int = unsent_limit;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, tcp_notsent_lowat, &unsent, @sizeOf(c_int));
}

pub fn setNonblocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.Unexpected;
    var o: c.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    if (c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(o))))) < 0) return error.Unexpected;
}
