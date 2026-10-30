//! What the replayed traces don't reach: turning connections away, a host's goodbye, a full session, and a view link.
//! testing.allocator also checks every room's memory is given back.

const std = @import("std");
const testing = std.testing;
const Relay = @import("Relay.zig");
const wire = @import("wire.zig");

/// A relay, with what it sent and closed since the last look.
const Harness = struct {
    relay: Relay,
    prng: std.Random.DefaultPrng = .init(1),
    sent: std.ArrayList(struct { link: *Relay.Link, frame: []u8 }) = .empty,
    closed: std.ArrayList(*Relay.Link) = .empty,
    links: [9]Relay.Link = undefined,

    fn init(h: *Harness, limits: wire.Limits) void {
        h.* = .{ .relay = undefined };
        h.relay = .init(testing.allocator, h.prng.random(), .{ .ptr = h, .vtable = &.{ .send = send, .close = close } }, .{ .limits = limits });
        for (&h.links, 0..) |*link, i| {
            link.* = .{ .id = i };
            h.relay.opened(link, 0);
        }
    }

    fn deinit(h: *Harness) void {
        h.forget();
        h.sent.deinit(testing.allocator);
        h.closed.deinit(testing.allocator);
        h.relay.deinit();
    }

    fn send(ptr: *anyopaque, link: *Relay.Link, frame: []const u8) void {
        const h: *Harness = @ptrCast(@alignCast(ptr));
        h.sent.append(testing.allocator, .{ .link = link, .frame = testing.allocator.dupe(u8, frame) catch unreachable }) catch unreachable;
    }

    fn close(ptr: *anyopaque, link: *Relay.Link) void {
        const h: *Harness = @ptrCast(@alignCast(ptr));
        h.closed.append(testing.allocator, link) catch unreachable;
    }

    fn forget(h: *Harness) void {
        for (h.sent.items) |s| testing.allocator.free(s.frame);
        h.sent.clearRetainingCapacity();
        h.closed.clearRetainingCapacity();
    }

    fn receive(h: *Harness, link: usize, frame: []const u8) void {
        h.forget();
        var copy: [512]u8 = undefined;
        @memcpy(copy[0..frame.len], frame);
        h.relay.received(&h.links[link], copy[0..frame.len], 0);
    }

    /// The bye `link` was last sent, if it was sent one and closed.
    fn bye(h: *const Harness, link: usize) ?[]const u8 {
        const l = &h.links[link];
        if (std.mem.indexOfScalar(*const Relay.Link, h.closed.items, l) == null) return null;
        var i = h.sent.items.len;
        while (i > 0) {
            i -= 1;
            const s = h.sent.items[i];
            if (s.link != l) continue;
            return if (s.frame[1] == @backingInt(wire.Kind.bye)) s.frame[wire.header_size..] else null;
        }
        return null;
    }

    fn kindsSentTo(h: *const Harness, link: usize, kinds: []wire.Kind) []wire.Kind {
        var n: usize = 0;
        for (h.sent.items) |s| if (s.link == &h.links[link]) {
            kinds[n] = @fromBackingInt(@intCast(s.frame[1]));
            n += 1;
        };
        return kinds[0..n];
    }

    /// Link 0 makes a room and sends its snapshot.
    fn host(h: *Harness, name: []const u8, title: []const u8) *Relay.Room {
        h.receive(0, hello(.host, "", "", "", name, title));
        h.receive(0, makeFrame(.snapshot, 0, "snapshot"));
        return h.links[0].room.?;
    }

    fn join(h: *Harness, link: usize, role: wire.Role, secret: []const u8, client: []const u8) void {
        h.receive(link, hello(role, &h.links[0].room.?.id, secret, client, "Guest", ""));
    }
};

var frame_buffer: [512]u8 = undefined;

fn hello(role: wire.Role, room: []const u8, secret: []const u8, client: []const u8, name: []const u8, title: []const u8) []u8 {
    var w: wire.FrameWriter = .{ .buffer = &frame_buffer };
    w.byte(@backingInt(role));
    w.blob(room);
    w.blob(secret);
    w.blob(client);
    w.varint(0);
    w.varint(wire.room_version);
    w.blob(name);
    w.blob(title);
    return w.finish(.hello, 0, 0);
}

fn makeFrame(kind: wire.Kind, seq: u64, body: []const u8) []u8 {
    var w: wire.FrameWriter = .{ .buffer = &frame_buffer };
    w.raw(body);
    return w.finish(kind, seq, 0);
}

test "connections that can't join are told why and let go" {
    var h: Harness = undefined;
    h.init(.{ .max_peers = 3 });
    defer h.deinit();

    h.receive(1, hello(.host, "", "", "", &@as([wire.max_name + 1]u8, @splat('N')), ""));
    try testing.expectEqualStrings("That name or title is too long.", h.bye(1).?);
    const room = h.host("Host", "Model");
    h.join(2, .guest, "not the secret", "a");
    try testing.expectEqualStrings("That link isn't valid, or the session has ended.", h.bye(2).?);
    h.join(3, .guest, &room.guest_secret, "");
    try testing.expectEqualStrings("Say which client this is.", h.bye(3).?);
    h.receive(4, hello(.@"resume", &room.id, &room.guest_secret, "", "", ""));
    try testing.expectEqualStrings("That session has ended.", h.bye(4).?);
    // Not a hello at all: let go without a word.
    h.receive(5, makeFrame(.ping, 0, ""));
    try testing.expectEqual(null, h.bye(5));
    try testing.expectEqual(&h.links[5], h.closed.items[0]);

    // Room for two guests, with the host making three.
    h.join(6, .guest, &room.guest_secret, "a");
    h.join(7, .guest, &room.guest_secret, "b");
    try testing.expectEqual(null, h.bye(7));
    h.join(8, .guest, &room.guest_secret, "c");
    try testing.expectEqualStrings("This session is full.", h.bye(8).?);
}

test "a view link sees everything and changes nothing" {
    var h: Harness = undefined;
    h.init(.{});
    defer h.deinit();
    const room = h.host("Host", "Model");
    h.join(1, .view, &room.view_secret, "v");
    var kinds: [8]wire.Kind = undefined;
    try testing.expectEqualSlices(wire.Kind, &.{ .hello, .snapshot }, h.kindsSentTo(1, &kinds));
    h.receive(1, makeFrame(.change, 1, "change"));
    try testing.expectEqual(&h.links[1], h.closed.items[0]);
    try testing.expectEqualSlices(wire.Kind, &.{.left}, h.kindsSentTo(0, &kinds));
}

test "a host's goodbye ends the room for everyone, in its words" {
    var h: Harness = undefined;
    h.init(.{});
    defer h.deinit();
    const room = h.host("Host", "Model");
    h.join(1, .guest, &room.guest_secret, "a");
    h.receive(0, makeFrame(.bye, 7, "Stopped sharing."));
    try testing.expectEqualStrings("Stopped sharing.", h.bye(0).?);
    try testing.expectEqualStrings("Stopped sharing.", h.bye(1).?);
    // Its header cleared, as the relay's own byes are.
    try testing.expectEqual(@as(u64, 0), wire.seqOf(h.sent.items[1].frame));
    try testing.expectEqual(@as(usize, 0), h.relay.roomCount());
}

test "a guest coming back on a new connection keeps its peer, and its old connection goes" {
    var h: Harness = undefined;
    h.init(.{});
    defer h.deinit();
    const room = h.host("Host", "Model");
    h.join(1, .guest, &room.guest_secret, "a");
    const peer = room.guests.items[0].peer;
    h.join(2, .guest, &room.guest_secret, "a");
    try testing.expectEqual(&h.links[1], h.closed.items[0]);
    try testing.expectEqual(@as(usize, 1), room.guests.items.len);
    try testing.expectEqual(peer, room.guests.items[0].peer);
}

test "a host's frame at the last seq drops it, and the room still takes guests" {
    const last = std.math.maxInt(u64);
    var h: Harness = undefined;
    h.init(.{});
    defer h.deinit();

    // A snapshot at the last seq: before, an ops frame or a guest's hello after it overflowed `room.latest + 1`.
    h.receive(0, hello(.host, "", "", "", "Host", "Model"));
    const room = h.links[0].room.?;
    h.receive(0, makeFrame(.snapshot, last, "snapshot"));
    try testing.expectEqualSlices(*Relay.Link, &.{&h.links[0]}, h.closed.items);
    try testing.expectEqual(@as(u64, 0), room.latest);
    h.receive(0, makeFrame(.ops, 1, "ops"));
    h.receive(1, hello(.guest, &room.id, &room.guest_secret, "a", "Guest", ""));
    try testing.expectEqual(null, h.bye(1));

    // A decision at the last seq, right after a snapshot one short of it.
    h.receive(2, hello(.host, "", "", "", "Host", "Model"));
    const other = h.links[2].room.?;
    h.receive(2, makeFrame(.snapshot, last - 1, "snapshot"));
    h.receive(2, makeFrame(.ops, last, "ops"));
    try testing.expectEqualSlices(*Relay.Link, &.{&h.links[2]}, h.closed.items);
    try testing.expectEqual(last - 1, other.latest);
    h.receive(3, hello(.guest, &other.id, &other.guest_secret, "b", "Guest", ""));
    try testing.expectEqual(null, h.bye(3));
}

test "past the most rooms, a host is told the relay is full, and rooms already open carry on" {
    var h: Harness = undefined;
    h.init(.{});
    defer h.deinit();
    h.relay.max_rooms = 1;
    const room = h.host("Host", "Model");
    h.receive(1, hello(.host, "", "", "", "Host", "Model"));
    try testing.expectEqualStrings("The relay is full.", h.bye(1).?);
    try testing.expectEqual(@as(usize, 1), h.relay.roomCount());
    h.join(2, .guest, &room.guest_secret, "a");
    try testing.expectEqual(null, h.bye(2));
    // A room ending makes room for the next.
    h.receive(0, makeFrame(.bye, 0, "Stopped sharing."));
    h.receive(3, hello(.host, "", "", "", "Host", "Model"));
    try testing.expectEqual(null, h.bye(3));
    try testing.expectEqual(@as(usize, 1), h.relay.roomCount());
}
