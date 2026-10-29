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
