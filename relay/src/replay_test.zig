//! Replays what the Swift relay (`RelayCore`) heard in the simulation, recorded by
//! `scripts/record-relay-traces.sh`, and checks this relay sends and closes exactly as it did: on every connection, the
//! same bytes, in the same order. And that it allocates only when it makes a room.
//!
//! A trace is "JRT1", the limits (four u32s) and the host's grace in ms (u64), then events: a tag (1 opened, 2 closed,
//! 3 received, 4 tick), the connection (u32), the bytes (u32 length, then them), the time in ms (u64), then what the
//! relay did: a count (u32) of effects, each a tag (1 send, 2 close), a connection and bytes as above. All
//! little-endian.

const std = @import("std");
const testing = std.testing;
const Relay = @import("Relay.zig");

const traces = .{ "seed-1", "seed-2", "seed-3", "seed-4", "host-gone" };

test "the relay does exactly what the Swift relay did" {
    inline for (traces) |name| {
        replay(@embedFile("testdata/" ++ name ++ ".trace")) catch |err| {
            std.debug.print("in {s}.trace\n", .{name});
            return err;
        };
    }
}

const Effect = struct {
    tag: u8,
    connection: u32,
    bytes: []const u8,

    /// Effects compared connection by connection: across connections, order can't matter.
    fn lessThan(_: void, a: Effect, b: Effect) bool {
        return a.connection < b.connection;
    }
};

/// What the relay does, written down.
const Recorder = struct {
    gpa: std.mem.Allocator,
    effects: std.ArrayList(Effect) = .empty,
    /// Links the relay has closed, freed once the event's done.
    closed: std.ArrayList(*Relay.Link) = .empty,

    fn out(recorder: *Recorder) Relay.Out {
        return .{ .ptr = recorder, .vtable = &.{ .send = send, .close = close } };
    }

    fn send(ptr: *anyopaque, link: *Relay.Link, frame: []const u8) void {
        const recorder: *Recorder = @ptrCast(@alignCast(ptr));
        const bytes = recorder.gpa.dupe(u8, frame) catch @panic("out of memory");
        recorder.effects.append(recorder.gpa, .{ .tag = 1, .connection = @intCast(link.id), .bytes = bytes }) catch @panic("out of memory");
    }

    fn close(ptr: *anyopaque, link: *Relay.Link) void {
        const recorder: *Recorder = @ptrCast(@alignCast(ptr));
        recorder.effects.append(recorder.gpa, .{ .tag = 2, .connection = @intCast(link.id), .bytes = &.{} }) catch @panic("out of memory");
        recorder.closed.append(recorder.gpa, link) catch @panic("out of memory");
    }
};

/// Makes secrets as the simulation does: the bytes count up, 1, 2, 3, as a little-endian u64 then zeros.
const CountingRandom = struct {
    count: u64 = 0,

    fn fill(c: *CountingRandom, buffer: []u8) void {
        c.count += 1;
        @memset(buffer, 0);
        std.mem.writeInt(u64, buffer[0..8], c.count, .little);
    }
};

const Trace = struct {
    bytes: []const u8,
    index: usize = 0,

    fn int(t: *Trace, comptime T: type) T {
        defer t.index += @sizeOf(T);
        return std.mem.readInt(T, t.bytes[t.index..][0..@sizeOf(T)], .little);
    }

    fn slice(t: *Trace) []const u8 {
        const n = t.int(u32);
        defer t.index += n;
        return t.bytes[t.index..][0..n];
    }
};

fn replay(bytes: []const u8) !void {
    const gpa = testing.allocator;
    var trace: Trace = .{ .bytes = bytes };
    try testing.expectEqualStrings("JRT1", bytes[0..4]);
    trace.index = 4;
    const limits: @import("wire.zig").Limits = .{
        .max_frame = trace.int(u32),
        .max_snapshot = trace.int(u32),
        .log_bytes = trace.int(u32),
        .max_peers = trace.int(u32),
    };
    const host_grace: i64 = @intCast(trace.int(u64));

    var recorder: Recorder = .{ .gpa = gpa };
    defer {
        for (recorder.effects.items) |e| gpa.free(e.bytes);
        recorder.effects.deinit(gpa);
        recorder.closed.deinit(gpa);
    }
    var counting: CountingRandom = .{};
    // The relay's own allocations, counted.
    var relay_gpa: std.testing.FailingAllocator = .init(gpa, .{});
    var relay: Relay = .init(relay_gpa.allocator(), .init(&counting, CountingRandom.fill), recorder.out(), .{
        .limits = limits,
        .host_grace = host_grace,
    });
    defer relay.deinit();
    var links: std.AutoHashMapUnmanaged(u32, *Relay.Link) = .empty;
    defer {
        var it = links.valueIterator();
        while (it.next()) |link| gpa.destroy(link.*);
        links.deinit(gpa);
    }
    var expected: std.ArrayList(Effect) = .empty;
    defer expected.deinit(gpa);
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);

    var event: usize = 0;
    while (trace.index < bytes.len) : (event += 1) {
        const tag = trace.int(u8);
        const connection = trace.int(u32);
        const body = trace.slice();
        const now: i64 = @intCast(trace.int(u64));
        expected.clearRetainingCapacity();
        for (0..trace.int(u32)) |_| {
            const effect_tag = trace.int(u8);
            const to = trace.int(u32);
            try expected.append(gpa, .{ .tag = effect_tag, .connection = to, .bytes = trace.slice() });
        }

        const allocations = relay_gpa.allocations;
        const rooms = relay.roomCount();
        switch (tag) {
            1 => {
                const link = try gpa.create(Relay.Link);
                link.* = .{ .id = connection };
                try links.put(gpa, connection, link);
                relay.opened(link, now);
            },
            2 => if (links.fetchRemove(connection)) |entry| {
                relay.closed(entry.value, now);
                gpa.destroy(entry.value);
            },
            3 => {
                // The relay stamps frames in place, so it gets its own copy.
                frame.clearRetainingCapacity();
                try frame.appendSlice(gpa, body);
                relay.received(links.get(connection).?, frame.items, now);
            },
            4 => relay.tick(now),
            else => return error.BadTrace,
        }
        if (relay_gpa.allocations != allocations and relay.roomCount() <= rooms) {
            std.debug.print("event {d}: allocated without making a room\n", .{event});
            return error.Allocated;
        }

        std.sort.insertion(Effect, expected.items, {}, Effect.lessThan);
        std.sort.insertion(Effect, recorder.effects.items, {}, Effect.lessThan);
        expectSame(expected.items, recorder.effects.items) catch |err| {
            std.debug.print("event {d} (tag {d}, connection {d}): expected {d} effects, got {d}\n", .{
                event, tag, connection, expected.items.len, recorder.effects.items.len,
            });
            return err;
        };
        for (recorder.effects.items) |e| gpa.free(e.bytes);
        recorder.effects.clearRetainingCapacity();
        for (recorder.closed.items) |link| if (links.fetchRemove(@intCast(link.id))) |entry| gpa.destroy(entry.value);
        recorder.closed.clearRetainingCapacity();
    }
}

fn expectSame(expected: []const Effect, actual: []const Effect) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.tag, a.tag);
        try testing.expectEqual(e.connection, a.connection);
        try testing.expectEqualSlices(u8, e.bytes, a.bytes);
    }
}
