//! A connection: its socket, what's come in and what's queued to go, and its link to the relay. Its address is its
//! tag in the event queue.

const std = @import("std");
const c = std.c;
const assert = std.debug.assert;
const Relay = @import("../relay/Relay.zig");
const wire = @import("../relay/wire.zig");
const Pointers = @import("Pointers.zig");

/// What every send to it touches, together: 48 bytes, so usually one cache line, two at most. Not aligned to one: the
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
node: std.DoublyLinkedList.Node = .{},

const Conn = @This();

pub const Kind = enum { http, websocket, metrics };

pub const Hot = struct {
    /// What's queued to send, `out[out_start..out_end]`.
    out: []u8,
    out_start: usize = 0,
    out_end: usize = 0,
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

    comptime {
        assert(@sizeOf(Hot) <= std.atomic.cache_line);
    }
};

/// Drops what's been read up to `used`: what's left is the start of what's next.
pub fn consume(conn: *Conn, used: usize) void {
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
