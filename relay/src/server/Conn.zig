//! A connection: its socket, what's come in and what's queued to go, and its link to the relay. Its address is its
//! tag in the event queue.

const std = @import("std");
const c = std.c;
const assert = std.debug.assert;
const Relay = @import("../relay/Relay.zig");
const wire = @import("../relay/wire.zig");
const Pointers = @import("Pointers.zig");

/// What every send to it touches, together: 64 bytes, a cache line or two. Not aligned to one: the
/// allocator gives over-aligned things a page each.
hot: Hot,
link: Relay.Link,
fd: c.fd_t,
kind: Kind,
/// While it's being handed to another loop, the next in that loop's inbox, and which loop.
next_handed: ?*Conn = null,
owner: u8 = 0,
/// Whether the relay knows it: from its upgrade to a WebSocket, until it's closed.
in_relay: bool = false,
in: []u8,
in_len: usize = 0,
/// When it was accepted, or when the relay closed it.
since: i64,
/// The newest pointer update from each person, waiting for the queue to go: made on the first one, as some
/// connections never get any.
pointers: ?*Pointers = null,
/// Its place in its loop's table of UDP paths, once it's been sent a ticket (`--udp on`).
udp_slot: ?u32 = null,
node: std.DoublyLinkedList.Node = .{},

const Conn = @This();

pub const Kind = enum { http, websocket, metrics };

pub const Hot = struct {
    /// What's queued to send: `out_len` bytes from `out_start`, wrapping round the end. A ring, so queueing a frame
    /// never moves what's already queued, however full it is or however slowly the peer reads.
    out: []u8,
    out_start: usize = 0,
    out_len: usize = 0,
    /// How far into `out` has been written since it was last given back: what it's holding in memory.
    out_used: usize = 0,
    state: enum {
        open,
        /// The relay's closed it: what's queued goes, then the socket.
        closing,
        /// Too far behind: closed, and the relay told at the end of the turn.
        lagging,
        /// Closed; let go of at the end of the turn.
        gone,
        /// For another loop, whose room it's joining: handed to it at the end of the turn.
        leaving,
    } = .open,
    is_dirty: bool = false,
    wants_write: bool = false,
    /// When its queue was last empty and got something: with a batch window, it's sent once it's waited that long.
    dirty_since: i64 = 0,
    /// When its queue last went from empty to not: how long it's been behind.
    behind_since: i64 = 0,

    comptime {
        assert(@sizeOf(Hot) <= std.atomic.cache_line);
    }

    /// Queues bytes after what's there. False if they don't fit: it's too far behind.
    pub fn push(hot: *Hot, bytes: []const u8) bool {
        if (hot.out_len + bytes.len > hot.out.len) return false;
        const end = (hot.out_start + hot.out_len) % hot.out.len;
        const first = @min(bytes.len, hot.out.len - end);
        @memcpy(hot.out[end..][0..first], bytes[0..first]);
        @memcpy(hot.out[0 .. bytes.len - first], bytes[first..]);
        hot.out_len += bytes.len;
        return true;
    }

    /// What goes next, up to the end of the buffer: the rest, from the start of it, after.
    pub fn pending(hot: *const Hot) []const u8 {
        return hot.out[hot.out_start..][0..@min(hot.out_len, hot.out.len - hot.out_start)];
    }

    /// Lets go of the first `n` bytes queued, once they're sent.
    pub fn sent(hot: *Hot, n: usize) void {
        hot.out_len -= n;
        // Empty: back to the start, so a connection that keeps up only touches the front of its buffer.
        hot.out_start = if (hot.out_len == 0) 0 else (hot.out_start + n) % hot.out.len;
    }
};

/// Drops what's been read up to `used`: what's left is the start of what's next.
pub fn consume(conn: *Conn, used: usize) void {
    // Nothing whole yet: a slow sender's part of a message stays where it is, not copied onto itself each read.
    if (used == 0) return;
    @memmove(conn.in[0 .. conn.in_len - used], conn.in[used..conn.in_len]);
    conn.in_len -= used;
}

/// The largest message, the snapshot, with its WebSocket header, and room for the HTTP request before it.
pub fn inSize(limits: wire.Limits) usize {
    return @as(usize, limits.max_snapshot) + 14 + 8192;
}

/// The most a connection can have queued: a joiner's catch-up, the snapshot and the whole log, with each frame's
/// WebSocket header. The memory's only touched as it's used.
pub fn outSize(limits: wire.Limits) usize {
    // ponytail: twice what the frames take covers the headers of the smallest frames; per-frame cursors into the log
    // would make this zero, as docs/relay.md has it.
    return 2 * (@as(usize, limits.max_snapshot) + limits.log_bytes);
}

/// The start of each outbox that's kept once it's sent, and not counted against the loop's budget: enough for the
/// usual turn's frames, so a connection that's keeping up never costs a system call to give memory back.
pub const out_free = 64 * 1024;

test "the outbox wraps round its end, and turns away what doesn't fit" {
    var buffer: [8]u8 = undefined;
    var hot: Hot = .{ .out = &buffer };
    try std.testing.expect(hot.push("abcdef"));
    hot.sent(5);
    // Room for 7, but only 2 before the end: the rest goes at the start, and nothing queued moves.
    try std.testing.expect(hot.push("ghijkl"));
    try std.testing.expect(!hot.push("mn"));
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    while (hot.out_len > 0) {
        // A slow reader: a byte at a time.
        try got.append(std.testing.allocator, hot.pending()[0]);
        hot.sent(1);
    }
    try std.testing.expectEqualStrings("fghijkl", got.items);
    try std.testing.expectEqual(0, hot.out_start);
}
