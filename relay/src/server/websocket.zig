//! The WebSocket framing the relay speaks (RFC 6455): the handshake's answer, a frame's header in each direction, and
//! unmasking what clients send. Only final binary messages carry the relay's frames; clients mask everything.

const std = @import("std");

pub const Opcode = struct {
    pub const binary = 0x2;
    pub const close = 0x8;
    pub const ping = 0x9;
    pub const pong = 0xA;
};

/// What a client's frame says of itself, read from its first bytes.
pub const Head = struct {
    fin: bool,
    opcode: u8,
    masked: bool,
    /// The payload's length, after the header and the mask.
    length: u64,
    /// The header's length, before the mask.
    size: usize,

    /// The header at the start of `bytes`, or null if it hasn't all come in yet.
    pub fn parse(bytes: []const u8) ?Head {
        if (bytes.len < 2) return null;
        var head: Head = .{
            .fin = bytes[0] & 0x80 != 0,
            .opcode = bytes[0] & 0x0f,
            .masked = bytes[1] & 0x80 != 0,
            .length = bytes[1] & 0x7f,
            .size = 2,
        };
        if (head.length == 126) {
            if (bytes.len < 4) return null;
            head.length = std.mem.readInt(u16, bytes[2..4], .big);
            head.size = 4;
        } else if (head.length == 127) {
            if (bytes.len < 10) return null;
            head.length = std.mem.readInt(u64, bytes[2..10], .big);
            head.size = 10;
        }
        return head;
    }
};

/// A final, unmasked message's header, as a server sends it.
pub fn header(buffer: *[10]u8, opcode: u8, length: usize) []const u8 {
    buffer[0] = 0x80 | opcode;
    if (length < 126) {
        buffer[1] = @intCast(length);
        return buffer[0..2];
    } else if (length <= 0xffff) {
        buffer[1] = 126;
        std.mem.writeInt(u16, buffer[2..4], @intCast(length), .big);
        return buffer[0..4];
    }
    buffer[1] = 127;
    std.mem.writeInt(u64, buffer[2..10], length, .big);
    return buffer[0..10];
}

/// Unmasks a client's message in place: the one pass the relay makes over a body. Sixteen bytes at a time, the mask
/// repeated across a vector: byte by byte, it was four instructions a byte, a millisecond for a 1 MiB snapshot.
pub fn unmask(payload: []u8, mask: [4]u8) void {
    const V = @Vector(16, u8);
    const repeated: V = @bitCast(@as(@Vector(4, u32), @splat(@bitCast(mask))));
    var i: usize = 0;
    while (i + 16 <= payload.len) : (i += 16) {
        const chunk: V = payload[i..][0..16].*;
        payload[i..][0..16].* = chunk ^ repeated;
    }
    // The rest; `i` is a multiple of 16, so the mask lines up.
    for (payload[i..], i..) |*b, j| b.* ^= mask[j % 4];
}

/// The answer to a client's `Sec-WebSocket-Key`, for its `Sec-WebSocket-Accept`.
pub fn acceptKey(key: []const u8) [28]u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

test "headers" {
    var buffer: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0 }, header(&buffer, 2, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 125 }, header(&buffer, 2, 125));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0, 126 }, header(&buffer, 2, 126));
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 126, 0xff, 0xff }, header(&buffer, 0xA, 0xffff));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0 }, header(&buffer, 2, 0x10000));
}

test "a client's header, whole or not yet" {
    try std.testing.expectEqual(null, Head.parse(&.{0x82}));
    try std.testing.expectEqual(null, Head.parse(&.{ 0x82, 0xfe, 0 }));
    const head = Head.parse(&.{ 0x82, 0xfe, 1, 0 }).?;
    try std.testing.expect(head.fin and head.masked);
    try std.testing.expectEqual(@as(u8, 2), head.opcode);
    try std.testing.expectEqual(@as(u64, 256), head.length);
    try std.testing.expectEqual(@as(usize, 4), head.size);
}

test "the handshake's answer, from RFC 6455's example" {
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "unmasking, sixteen at a time, matches byte by byte" {
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    for ([_]usize{ 0, 1, 15, 16, 17, 100, 1000 }) |len| {
        var bytes: [1000]u8 = undefined;
        for (&bytes, 0..) |*b, i| b.* = @truncate(i * 7);
        var expected = bytes;
        for (expected[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
        unmask(bytes[0..len], mask);
        try std.testing.expectEqualSlices(u8, expected[0..len], bytes[0..len]);
    }
}
