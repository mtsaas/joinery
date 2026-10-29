//! The OS's event queue: kqueue, or epoll on Linux. Level-triggered: a socket with something left to read is reported
//! again. Each watched thing has a tag, handed back with its events: for a connection, its address.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Poller = switch (builtin.os.tag) {
    .linux => Epoll,
    else => Kqueue,
};

pub const Event = struct { tag: usize, readable: bool, writable: bool };

const Kqueue = struct {
    fd: c.fd_t,
    raw: [256]c.Kevent = undefined,

    pub fn init() !Kqueue {
        const fd = c.kqueue();
        if (fd < 0) return error.SystemResources;
        return .{ .fd = fd };
    }

    fn change(k: *Kqueue, fd: c.fd_t, filter: i16, flags: u16, tag: usize) !void {
        const ev: c.Kevent = .{ .ident = @intCast(fd), .filter = filter, .flags = flags, .fflags = 0, .data = 0, .udata = tag };
        if (c.kevent(k.fd, (&ev)[0..1], 1, &k.raw, 0, null) < 0) return error.SystemResources;
    }

    pub fn add(k: *Kqueue, fd: c.fd_t, tag: usize) !void {
        try k.change(fd, c.EVFILT.READ, c.EV.ADD, tag);
    }

    /// A listening socket other loops may watch too: each is woken, and whichever accepts first has the connection.
    pub fn addListener(k: *Kqueue, fd: c.fd_t, tag: usize) !void {
        try k.add(fd, tag);
    }

    pub fn remove(k: *Kqueue, fd: c.fd_t, writing: bool) void {
        k.change(fd, c.EVFILT.READ, c.EV.DELETE, 0) catch {};
        if (writing) k.change(fd, c.EVFILT.WRITE, c.EV.DELETE, 0) catch {};
    }

    /// Whether the socket's reported readable; writable stays as it is.
    pub fn wantRead(k: *Kqueue, fd: c.fd_t, tag: usize, on: bool, writing: bool) !void {
        _ = writing;
        try k.change(fd, c.EVFILT.READ, if (on) c.EV.ENABLE else c.EV.DISABLE, tag);
    }

    /// Whether the socket's reported writable; readable stays as it is.
    pub fn wantWrite(k: *Kqueue, fd: c.fd_t, tag: usize, on: bool, reading: bool) !void {
        _ = reading;
        try k.change(fd, c.EVFILT.WRITE, if (on) c.EV.ADD | c.EV.ENABLE else c.EV.DELETE, tag);
    }

    pub fn wait(k: *Kqueue, events: []Event, timeout_ms: u64) ![]Event {
        const timeout: c.timespec = .{ .sec = @intCast(timeout_ms / 1000), .nsec = @intCast(timeout_ms % 1000 * std.time.ns_per_ms) };
        const n = c.kevent(k.fd, &k.raw, 0, &k.raw, @intCast(@min(events.len, k.raw.len)), &timeout);
        if (n < 0) return if (c.errno(n) == .INTR) events[0..0] else error.SystemResources;
        for (k.raw[0..@intCast(n)], events[0..@intCast(n)]) |raw, *event| {
            // An end of file or error is reported as readable: reading finds it.
            event.* = .{ .tag = raw.udata, .readable = raw.filter == c.EVFILT.READ, .writable = raw.filter == c.EVFILT.WRITE };
        }
        return events[0..@intCast(n)];
    }
};

const Epoll = struct {
    fd: c.fd_t,
    raw: [256]c.epoll_event = undefined,

    pub fn init() !Epoll {
        const fd = c.epoll_create1(0);
        if (fd < 0) return error.SystemResources;
        return .{ .fd = fd };
    }

    fn control(e: *Epoll, op: u32, fd: c.fd_t, events: u32, tag: usize) !void {
        var ev: c.epoll_event = .{ .events = events, .data = .{ .ptr = tag } };
        if (c.epoll_ctl(e.fd, op, fd, &ev) < 0) return error.SystemResources;
    }

    pub fn add(e: *Epoll, fd: c.fd_t, tag: usize) !void {
        try e.control(std.os.linux.EPOLL.CTL_ADD, fd, std.os.linux.EPOLL.IN, tag);
    }

    /// A listening socket other loops may watch too: one is woken for each connection, not all.
    pub fn addListener(e: *Epoll, fd: c.fd_t, tag: usize) !void {
        const linux = std.os.linux;
        try e.control(linux.EPOLL.CTL_ADD, fd, linux.EPOLL.IN | linux.EPOLL.EXCLUSIVE, tag);
    }

    pub fn remove(e: *Epoll, fd: c.fd_t, writing: bool) void {
        _ = writing;
        e.control(std.os.linux.EPOLL.CTL_DEL, fd, 0, 0) catch {};
    }

    /// What the socket's reported for: epoll sets both at once.
    fn watchFor(e: *Epoll, fd: c.fd_t, tag: usize, reading: bool, writing: bool) !void {
        const linux = std.os.linux;
        const in: u32 = if (reading) linux.EPOLL.IN else 0;
        const out: u32 = if (writing) linux.EPOLL.OUT else 0;
        try e.control(linux.EPOLL.CTL_MOD, fd, in | out, tag);
    }

    pub fn wantRead(e: *Epoll, fd: c.fd_t, tag: usize, on: bool, writing: bool) !void {
        try e.watchFor(fd, tag, on, writing);
    }

    pub fn wantWrite(e: *Epoll, fd: c.fd_t, tag: usize, on: bool, reading: bool) !void {
        try e.watchFor(fd, tag, reading, on);
    }

    pub fn wait(e: *Epoll, events: []Event, timeout_ms: u64) ![]Event {
        const linux = std.os.linux;
        const n = c.epoll_wait(e.fd, &e.raw, @intCast(@min(events.len, e.raw.len)), @intCast(timeout_ms));
        if (n < 0) return if (c.errno(n) == .INTR) events[0..0] else error.SystemResources;
        for (e.raw[0..@intCast(n)], events[0..@intCast(n)]) |raw, *event| {
            event.* = .{
                .tag = raw.data.ptr,
                .readable = raw.events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0,
                .writable = raw.events & linux.EPOLL.OUT != 0,
            };
        }
        return events[0..@intCast(n)];
    }
};
