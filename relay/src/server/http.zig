//! The HTTP request a connection starts with: a WebSocket's upgrade, a share link opened in a browser, or a scrape of
//! the metrics. The relay reads only what it needs of it.

const std = @import("std");

pub const Request = struct {
    target: []const u8,
    /// `Sec-WebSocket-Key`, if it asked for one.
    key: ?[]const u8,
    /// Whether it asked to be a WebSocket.
    upgrade: bool,
    /// The request's length, to its blank line: what follows is the first of what's after it.
    len: usize,

    /// The request at the start of `bytes`, or null if it isn't whole yet.
    pub fn parse(bytes: []const u8) ?Request {
        const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
        const head = bytes[0 .. end + 4];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        var words = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
        _ = words.next();
        var request: Request = .{ .target = words.next() orelse "", .key = null, .upgrade = false, .len = head.len };
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) request.key = value;
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) request.upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        }
        return request;
    }
};

test "a WebSocket's upgrade, whole or not yet" {
    const text = "GET /r/abc HTTP/1.1\r\nHost: relay\r\nUpgrade: WebSocket\r\nSec-WebSocket-Key: k==\r\n\r\nafter";
    try std.testing.expectEqual(null, Request.parse(text[0..30]));
    const request = Request.parse(text).?;
    try std.testing.expectEqualStrings("/r/abc", request.target);
    try std.testing.expectEqualStrings("k==", request.key.?);
    try std.testing.expect(request.upgrade);
    try std.testing.expectEqualStrings("after", text[request.len..]);
}
