//! A room's log: the host's frames in order, in a ring of bytes allocated once. Each frame is stored whole, never split
//! across the end of the ring, so it's always one slice to send. A frame that doesn't fit before the end goes at the
//! start instead, leaving the space after the last frame unused until the ring comes round.
//!
//! So that a frame always fits whole while the frames add up to at most the room's limit, the ring is bigger than the
//! limit by the largest frame (`capacity`). Proof, for a frame of `f` bytes with `live + f <= limit`, `f <= max_frame`:
//! - Not wrapped, no room before the end: `head > capacity - f`, so `tail = head - live > capacity - limit >= f`, and
//!   the frame fits at the start.
//! - Wrapped: the free space is `tail - head = end - live`, and `end > capacity - max_frame = limit`, as the ring only
//!   wraps when a frame doesn't fit before the end. So the free space is more than `limit - live >= f`.

const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");

const Log = @This();

buffer: []u8,
/// Where the oldest frame starts, and where the next one goes.
tail: usize = 0,
head: usize = 0,
/// Whether frames have gone on from the start, and if so, where they stop before it.
wrapped: bool = false,
end: usize = 0,
count: usize = 0,
/// The frames' total size, which the room keeps under its limit.
bytes: usize = 0,

pub fn capacity(limit: usize, max_frame: usize) usize {
    return limit + max_frame;
}

pub fn init(buffer: []u8) Log {
    return .{ .buffer = buffer };
}

pub fn first(log: *const Log) ?[]const u8 {
    return if (log.count == 0) null else log.frameAt(log.tail);
}

/// Adds a whole frame, which the room has made room for.
pub fn push(log: *Log, frame: []const u8) void {
    var at = log.head;
    if (!log.wrapped and at + frame.len > log.buffer.len) {
        log.wrapped = true;
        log.end = at;
        at = 0;
    }
    assert(at + frame.len <= if (log.wrapped) log.tail else log.buffer.len);
    @memcpy(log.buffer[at..][0..frame.len], frame);
    log.head = at + frame.len;
    log.count += 1;
    log.bytes += frame.len;
}

/// Lets go of the oldest frame.
pub fn pop(log: *Log) void {
    const frame = log.first().?;
    log.count -= 1;
    log.bytes -= frame.len;
    log.tail += frame.len;
    if (log.count == 0) {
        log.clear();
    } else if (log.wrapped and log.tail == log.end) {
        log.wrapped = false;
        log.tail = 0;
    }
}

pub fn clear(log: *Log) void {
    log.* = .init(log.buffer);
}

pub fn iterator(log: *const Log) Iterator {
    return .{ .log = log, .at = log.tail, .left = log.count };
}

pub const Iterator = struct {
    log: *const Log,
    at: usize,
    left: usize,

    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.left == 0) return null;
        const frame = it.log.frameAt(it.at);
        it.left -= 1;
        it.at += frame.len;
        if (it.log.wrapped and it.at == it.log.end) it.at = 0;
        return frame;
    }
};

fn frameAt(log: *const Log, at: usize) []const u8 {
    const length = std.mem.readInt(u32, log.buffer[at + 4 ..][0..4], .little);
    return log.buffer[at..][0 .. wire.header_size + length];
}

test "the log keeps every frame whole, in order, against a plain list" {
    const gpa = std.testing.allocator;
    const limit = 1000;
    const max_frame = 300;
    const buffer = try gpa.alloc(u8, capacity(limit, max_frame));
    defer gpa.free(buffer);
    var log: Log = .init(buffer);
    var model: std.ArrayList([]u8) = .empty;
    defer {
        for (model.items) |frame| gpa.free(frame);
        model.deinit(gpa);
    }
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    for (0..20_000) |seq| {
        // A frame of a random size, its seq and length in its header, its body filled with its seq.
        const frame = try gpa.alloc(u8, random.intRangeAtMost(usize, wire.header_size, max_frame));
        @memset(frame, @truncate(seq));
        std.mem.writeInt(u32, frame[4..8], @intCast(frame.len - wire.header_size), .little);
        std.mem.writeInt(u64, frame[8..16], seq, .little);
        while (log.bytes + frame.len > limit or (log.count > 0 and random.uintLessThan(u8, 4) == 0)) {
            log.pop();
            gpa.free(model.orderedRemove(0));
        }
        log.push(frame);
        try model.append(gpa, frame);

        var it = log.iterator();
        for (model.items) |expected| try std.testing.expectEqualSlices(u8, expected, it.next().?);
        try std.testing.expectEqual(null, it.next());
    }
}
