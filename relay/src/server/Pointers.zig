//! A connection's newest pointer update from each person, while its queue goes: `count` of them, each in its slot.
//! Apart from the connection, which every send touches; this is touched only for pointer updates. So a connection
//! that's behind is sent where pointers are, not where they were.

const std = @import("std");

const Pointers = @This();

count: usize,
peers: [slots]u32,
lens: [slots]u16,
bytes: [slots * slot_size]u8,

/// Pointer updates held, at most, per connection: one per person, as many as a room holds.
pub const slots = 32;
/// A pointer update bigger than this (a big selection) is queued like anything else.
pub const slot_size = 1024;

/// Holds the newest pointer update from `peer`, in place of any held already.
pub fn hold(pointers: *Pointers, peer: u32, frame: []const u8) enum { held, replaced, full } {
    var result: @TypeOf(pointers.hold(peer, frame)) = .held;
    const slot = for (pointers.peers[0..pointers.count], 0..) |p, i| {
        if (p == peer) {
            result = .replaced;
            break i;
        }
    } else slot: {
        if (pointers.count == slots) return .full;
        pointers.count += 1;
        break :slot pointers.count - 1;
    };
    pointers.peers[slot] = peer;
    pointers.lens[slot] = @intCast(frame.len);
    @memcpy(pointers.bytes[slot * slot_size ..][0..frame.len], frame);
    return result;
}

pub fn held(pointers: *const Pointers, slot: usize) []const u8 {
    return pointers.bytes[slot * slot_size ..][0..pointers.lens[slot]];
}

/// Lets go of `peer`'s update: they've left, and one from before can't follow them, or they'd seem to be back.
pub fn drop(pointers: *Pointers, peer: u32) void {
    for (pointers.peers[0..pointers.count], 0..) |p, i| {
        if (p != peer) continue;
        // The last slot fills the gap.
        const last = pointers.count - 1;
        if (i != last) {
            pointers.peers[i] = pointers.peers[last];
            pointers.lens[i] = pointers.lens[last];
            @memcpy(pointers.bytes[i * slot_size ..][0..pointers.lens[last]], pointers.bytes[last * slot_size ..][0..pointers.lens[last]]);
        }
        pointers.count = last;
        return;
    }
}

test "a connection that's behind holds only the newest pointer update from each person" {
    const pointers = try std.testing.allocator.create(Pointers);
    defer std.testing.allocator.destroy(pointers);
    pointers.count = 0;
    try std.testing.expectEqual(.held, pointers.hold(2, "ann at 1"));
    try std.testing.expectEqual(.held, pointers.hold(3, "bob at 1"));
    try std.testing.expectEqual(.replaced, pointers.hold(2, "ann at 2"));
    try std.testing.expectEqual(@as(usize, 2), pointers.count);
    try std.testing.expectEqualStrings("ann at 2", pointers.held(0));
    // Ann leaves: her update goes, and Bob's fills the gap.
    pointers.drop(2);
    try std.testing.expectEqual(@as(usize, 1), pointers.count);
    try std.testing.expectEqualStrings("bob at 1", pointers.held(0));
    for (0..slots - 1) |peer| _ = pointers.hold(@intCast(100 + peer), "x");
    try std.testing.expectEqual(.full, pointers.hold(999, "y"));
}
