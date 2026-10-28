//! `zig build bench`: times each step a frame takes through the relay, and counts what it allocates, which must be
//! nothing. Results for a commit go in bench/results.txt (docs/relay.md, "Measuring the relay").

const std = @import("std");
const Io = std.Io;
const Relay = @import("Relay.zig");
const Log = @import("Log.zig");
const wire = @import("wire.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var counting: std.testing.FailingAllocator = .init(std.heap.page_allocator, .{});
    const gpa = counting.allocator();

    std.debug.print("{s:<44} {s:>10} {s:>12}\n", .{ "step", "ns/frame", "allocations" });

    var frame: [24 + 64]u8 = @splat(0);
    _ = writeHeader(&frame, .ops, 1);
    try bench(io, &counting, "read a header", 10_000_000, struct {
        fn run(f: *[88]u8, i: usize) void {
            f[8] = @truncate(i);
            std.mem.doNotOptimizeAway(wire.Header.ofFrame(f) catch unreachable);
        }
    }.run, .{&frame});

    const buffer = try gpa.alloc(u8, Log.capacity(2 << 20, 1 << 20));
    var log: Log = .init(buffer);
    try bench(io, &counting, "append to the log, trimming it", 10_000_000, struct {
        fn run(l: *Log, f: *[88]u8, _: usize) void {
            if (l.bytes + f.len > 2 << 20) l.pop();
            l.push(f);
        }
    }.run, .{ &log, &frame });

    var room: Room = undefined;
    try room.init(gpa, 31);
    defer room.deinit();
    try bench(io, &counting, "a host's change, to 31 guests", 1_000_000, Room.publish, .{&room});
    try bench(io, &counting, "a guest's change, to the host", 10_000_000, Room.change, .{&room});
    std.debug.print("{d} frames sent in all\n", .{room.sink.sent});
}

/// Runs `step` `n` times and prints the time each took and the allocations made, which must be none.
fn bench(io: Io, counting: *std.testing.FailingAllocator, name: []const u8, n: usize, step: anytype, args: anytype) !void {
    const allocations = counting.allocations;
    const start = Io.Clock.awake.now(io);
    for (0..n) |i| @call(.auto, step, args ++ .{i});
    const elapsed = start.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const made = counting.allocations - allocations;
    std.debug.print("{s:<44} {d:>10.1} {d:>12}\n", .{ name, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(n)), made });
    if (made != 0) return error.Allocated;
}

fn writeHeader(frame: []u8, kind: wire.Kind, seq: u64) []u8 {
    var w: wire.FrameWriter = .{ .buffer = frame, .len = frame.len };
    return w.finish(kind, seq, 0);
}

/// Counts what the relay sends, and answers its snapshot requests once it returns.
const Sink = struct {
    sent: usize = 0,
    snapshot_requested: bool = false,

    fn send(ptr: *anyopaque, _: *Relay.Link, frame: []const u8) void {
        const sink: *Sink = @ptrCast(@alignCast(ptr));
        sink.sent += 1;
        if (frame[1] == @backingInt(wire.Kind.snapshot_request)) sink.snapshot_requested = true;
    }

    fn close(_: *anyopaque, _: *Relay.Link) void {
        @panic("nothing should be closed");
    }
};

/// A room with a host and guests, kept going: the guests ping now and then, so the log can be trimmed, and the host
/// sends a snapshot when asked.
const Room = struct {
    sink: Sink = .{},
    relay: Relay,
    prng: std.Random.DefaultPrng = .init(1),
    host: Relay.Link = .{ .id = 1 },
    guests: [31]Relay.Link = undefined,
    seq: u64 = 0,
    frame: [24 + 200]u8 = @splat(0),
    now: i64 = 0,

    fn init(room: *Room, gpa: std.mem.Allocator, guests: usize) !void {
        room.* = .{ .relay = undefined };
        room.relay = .init(gpa, room.prng.random(), .{ .ptr = &room.sink, .vtable = &.{ .send = Sink.send, .close = Sink.close } }, .{});
        var buffer: [512]u8 = undefined;
        var w: wire.FrameWriter = .{ .buffer = &buffer };
        w.byte(@backingInt(wire.Role.host));
        for (0..3) |_| w.blob("");
        w.varint(0);
        w.varint(wire.room_version);
        w.blob("Host");
        w.blob("Bench");
        room.relay.opened(&room.host, 0);
        room.relay.received(&room.host, w.finish(.hello, 0, 0), 0);
        room.snapshot();
        const r = room.host.room.?;
        for (room.guests[0..guests], 0..) |*g, i| {
            g.* = .{ .id = 2 + i };
            var client: [8]u8 = undefined;
            w = .{ .buffer = &buffer };
            w.byte(@backingInt(wire.Role.guest));
            w.blob(&r.id);
            w.blob(&r.guest_secret);
            w.blob(std.fmt.bufPrint(&client, "c{d}", .{i}) catch unreachable);
            w.varint(0);
            w.varint(wire.room_version);
            w.blob("Guest");
            w.blob("");
            room.relay.opened(g, 0);
            room.relay.received(g, w.finish(.hello, 0, 0), 0);
        }
    }

    fn deinit(room: *Room) void {
        room.relay.deinit();
    }

    fn snapshot(room: *Room) void {
        var buffer: [24 + 4096]u8 = @splat(0);
        room.relay.received(&room.host, writeHeader(&buffer, .snapshot, room.seq), room.now);
        room.sink.snapshot_requested = false;
    }

    /// The host publishes a 200-byte change, as a sealed rename would be with room to spare.
    fn publish(room: *Room, i: usize) void {
        room.seq += 1;
        room.relay.received(&room.host, writeHeader(&room.frame, .ops, room.seq), room.now);
        if (room.sink.snapshot_requested) room.snapshot();
        if (i % 1000 == 0) {
            var ping: [24]u8 = undefined;
            for (&room.guests) |*g| room.relay.received(g, writeHeader(&ping, .ping, room.seq), room.now);
        }
    }

    fn change(room: *Room, i: usize) void {
        room.relay.received(&room.guests[i % room.guests.len], writeHeader(room.frame[0..88], .change, i), room.now);
    }
};
