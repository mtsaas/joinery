//! What the relay reads and writes of the wire format (docs/relay.md): the 24-byte header, the `hello` it reads, and
//! the frames it writes itself. Everything else it passes on as bytes it never reads. `Wire.swift` and
//! `RelayMessages.swift` are the reference.

const std = @import("std");
const assert = std.debug.assert;

pub const version = 1;
pub const header_size = 24;
/// The host is always peer 1.
pub const host_peer: u32 = 1;
/// The room version this relay's clients speak, for its welcome.
pub const room_version: u64 = 1;
/// The longest a `hello`'s client, name and title can be, in bytes, so a room keeps them in fixed space.
pub const max_client = 64;
pub const max_name = 64;
pub const max_title = 256;

pub const Kind = enum(u8) {
    hello = 1,
    ops,
    reject,
    change,
    snapshot,
    snapshot_request,
    presence,
    ping,
    pong,
    joined,
    left,
    bye,
    /// Presence over UDP (server/udp.zig): a connection's ticket; over UDP, a probe; from a client over its WebSocket,
    /// "send me nothing more by UDP".
    udp_ticket,
};

pub const Malformed = error{Malformed};

/// What a relay holds each room to, sent to everyone in its welcome so they can check before sending.
pub const Limits = struct {
    /// The largest frame, header included.
    max_frame: u32 = 1 << 20,
    max_snapshot: u32 = 1 << 20,
    /// How many bytes of frames a room's log holds.
    log_bytes: u32 = 2 << 20,
    max_peers: u32 = 32,
};

pub const Header = struct {
    kind: Kind,
    length: u32,
    seq: u64,
    peer: u32,

    /// The header of `frame`, which must be exactly as long as the header says.
    pub fn ofFrame(frame: []const u8) Malformed!Header {
        if (frame.len < header_size) return error.Malformed;
        if (frame[0] != version) return error.Malformed;
        const header: Header = .{
            .kind = std.enums.fromInt(Kind, frame[1]) orelse return error.Malformed,
            .length = std.mem.readInt(u32, frame[4..8], .little),
            .seq = seqOf(frame),
            .peer = std.mem.readInt(u32, frame[16..20], .little),
        };
        if (frame.len != header_size + @as(usize, header.length)) return error.Malformed;
        return header;
    }
};

/// The `seq` of a frame known to be whole.
pub fn seqOf(frame: []const u8) u64 {
    return std.mem.readInt(u64, frame[8..16], .little);
}

/// Sets the sender in a frame's header, in place: how the relay stamps a frame, changing nothing else.
pub fn stamp(frame: []u8, peer: u32) void {
    std.mem.writeInt(u32, frame[16..20], peer, .little);
}

pub const Role = enum(u8) { host = 1, @"resume", guest, view };

/// How a connection introduces itself. Its strings point into the frame it came in.
pub const Hello = struct {
    role: Role,
    /// For all but `host`, which makes a new room.
    room: []const u8,
    secret: []const u8,
    /// Who's connecting, kept through every reconnection.
    client: []const u8,
    /// The last change a guest has, if it has a copy at all.
    applied: ?u64,
    version: u64,
    name: []const u8,
    /// The host's: what the room's called.
    title: []const u8,

    pub fn parse(body: []const u8) Malformed!Hello {
        var r: Reader = .{ .bytes = body };
        const role = std.enums.fromInt(Role, try r.byte()) orelse return error.Malformed;
        const room = try r.string();
        const secret = try r.string();
        const client = try r.string();
        const applied = try r.varint();
        return .{
            .role = role,
            .room = room,
            .secret = secret,
            .client = client,
            // Written one more than it is, so 0 can mean none.
            .applied = if (applied == 0) null else applied - 1,
            .version = try r.varint(),
            .name = try r.blob(),
            .title = try r.blob(),
        };
    }
};

/// Reads a body as `Wire.Reader` does in Swift, refusing exactly what it refuses.
const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn byte(r: *Reader) Malformed!u8 {
        if (r.index == r.bytes.len) return error.Malformed;
        defer r.index += 1;
        return r.bytes[r.index];
    }

    /// At most ten bytes; bits past the 64th are dropped, as Swift's shift drops them.
    fn varint(r: *Reader) Malformed!u64 {
        var value: u64 = 0;
        var shift: u7 = 0;
        while (shift < 64) : (shift += 7) {
            const b = try r.byte();
            value |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return value;
        }
        return error.Malformed;
    }

    /// Length-prefixed bytes.
    fn blob(r: *Reader) Malformed![]const u8 {
        const length = try r.varint();
        if (length > r.bytes.len - r.index) return error.Malformed;
        const n: usize = @intCast(length);
        defer r.index += n;
        return r.bytes[r.index..][0..n];
    }

    fn string(r: *Reader) Malformed![]const u8 {
        const bytes = try r.blob();
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
        return bytes;
    }
};

/// Builds a frame the relay writes itself in a buffer big enough for it, its header written last, once the body's
/// length is known.
pub const FrameWriter = struct {
    buffer: []u8,
    len: usize = header_size,

    pub fn byte(w: *FrameWriter, b: u8) void {
        w.buffer[w.len] = b;
        w.len += 1;
    }

    pub fn varint(w: *FrameWriter, value: u64) void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) w.byte(@as(u8, @truncate(v)) | 0x80);
        w.byte(@intCast(v));
    }

    pub fn raw(w: *FrameWriter, bytes: []const u8) void {
        @memcpy(w.buffer[w.len..][0..bytes.len], bytes);
        w.len += bytes.len;
    }

    /// Length-prefixed bytes, strings included.
    pub fn blob(w: *FrameWriter, bytes: []const u8) void {
        w.varint(bytes.len);
        w.raw(bytes);
    }

    pub fn finish(w: *FrameWriter, kind: Kind, seq: u64, peer: u32) []u8 {
        const h = w.buffer[0..header_size];
        h.* = @splat(0);
        h[0] = version;
        h[1] = @backingInt(kind);
        std.mem.writeInt(u32, h[4..8], @intCast(w.len - header_size), .little);
        std.mem.writeInt(u64, h[8..16], seq, .little);
        std.mem.writeInt(u32, h[16..20], peer, .little);
        return w.buffer[0..w.len];
    }
};

const testing = std.testing;

test "a hello reads back as Swift writes it" {
    // Relay.Hello(role: .resume, room: "room", secret: "s", client: "c", applied: 0, version: 3, name: [1, 2],
    // title: [3]).frame.body, as Swift writes it.
    const body = [_]u8{ 2, 4, 'r', 'o', 'o', 'm', 1, 's', 1, 'c', 1, 3, 2, 1, 2, 1, 3 };
    const hello = try Hello.parse(&body);
    try testing.expectEqual(Role.@"resume", hello.role);
    try testing.expectEqualStrings("room", hello.room);
    try testing.expectEqual(@as(?u64, 0), hello.applied);
    try testing.expectEqual(@as(u64, 3), hello.version);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, hello.name);
    // No copy at all is written as 0.
    try testing.expectEqual(@as(?u64, null), (try Hello.parse(&.{ 3, 0, 0, 0, 0, 1, 0, 0 })).applied);
}

test "bad bytes are refused, not trusted" {
    const bads = [_][]const u8{
        &.{},
        &.{9}, // an unknown role
        &.{ 3, 5, 'a' }, // a string past the end
        &.{ 3, 1, 0xff }, // a string that isn't UTF-8
        &.{ 3, 0, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 }, // a number too long
    };
    for (bads) |bad| try testing.expectError(error.Malformed, Hello.parse(bad));
    var frame: [header_size]u8 = @splat(0);
    frame[0] = version;
    frame[1] = @backingInt(Kind.ping);
    _ = try Header.ofFrame(&frame);
    frame[1] = 99;
    try testing.expectError(error.Malformed, Header.ofFrame(&frame));
    frame[1] = @backingInt(Kind.ping);
    frame[4] = 1; // a length that isn't the body's
    try testing.expectError(error.Malformed, Header.ofFrame(&frame));
}

test "frames written read back" {
    var buffer: [64]u8 = undefined;
    var w: FrameWriter = .{ .buffer = &buffer };
    w.varint(300);
    w.blob("hi");
    const frame = w.finish(.joined, 7, 3);
    const header = try Header.ofFrame(frame);
    try testing.expectEqual(Kind.joined, header.kind);
    try testing.expectEqual(@as(u64, 7), header.seq);
    try testing.expectEqual(@as(u32, 3), header.peer);
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x02, 2, 'h', 'i' }, frame[header_size..]);
    stamp(frame, 9);
    try testing.expectEqual(@as(u32, 9), (try Header.ofFrame(frame)).peer);
}
