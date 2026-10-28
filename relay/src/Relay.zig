//! The relay, without the network: what's heard on each connection goes in, and what to send and close comes out
//! through `Out`. It's a port of `RelayCore.swift`, the reference, and replaying traces recorded from that must send
//! exactly the same bytes (replay_test.zig). See docs/relay.md.
//!
//! It never reads a change. It reads headers, `hello`s, and from the host the order of what it publishes: every `ops`
//! and `reject` frame must be the next `seq`. It keeps each room's published frames in a log, bounded in bytes, behind
//! a snapshot the host sends when asked, and catches guests up from the log, or from the snapshot when the log no
//! longer reaches back far enough.
//!
//! Each room's memory is allocated when the room is made and freed when it ends; nothing allocates in between.
//! It runs on one thread: the caller makes sure only one call is in it at a time.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const wire = @import("wire.zig");
const Log = @import("Log.zig");

const Relay = @This();

gpa: Allocator,
/// Makes room IDs and secrets.
random: std.Random,
out: Out,
limits: wire.Limits,
/// A room whose host has been gone this long ends, in ms.
host_grace: i64,
rooms: std.StringHashMapUnmanaged(*Room) = .empty,
/// The same rooms, to visit each on a tick.
room_list: DoublyLinkedList = .{},
/// Connections that haven't said hello yet.
lobby: DoublyLinkedList = .{},
now: i64 = 0,
/// Where the frames the relay writes itself are built, each sent before the next is built.
scratch: [scratch_size]u8 = undefined,

/// Connections are let go if nothing's heard on them in this long, in ms, as everyone pings every ten seconds.
pub const timeout = 30_000;
/// How many clients a room remembers, each keeping its peer for the room's life.
pub const max_clients = 1024;
/// The most peers a room can be set to hold, so a welcome always fits `scratch`.
pub const max_peers = 256;
const scratch_size = 32 * 1024;

/// Where the relay's sends and closes go.
pub const Out = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Sends a whole frame on `link`. The bytes are only good for the call.
        send: *const fn (ptr: *anyopaque, link: *Link, frame: []const u8) void,
        /// Closes `link`: the relay has let go of it and won't mention it again.
        close: *const fn (ptr: *anyopaque, link: *Link) void,
    };

    fn send(out: Out, link: *Link, frame: []const u8) void {
        out.vtable.send(out.ptr, link, frame);
    }

    fn close(out: Out, link: *Link) void {
        out.vtable.close(out.ptr, link);
    }
};

/// A connection, as the relay knows it. The caller owns it, and keeps it until the relay closes it or is told it's
/// closed.
pub const Link = struct {
    /// Orders connections, as the reference orders them: an increasing number.
    id: u64,
    heard: i64 = 0,
    /// Once it's said hello.
    room: ?*Room = null,
    /// In the lobby, until it's said hello.
    node: DoublyLinkedList.Node = .{},
};

pub const Config = struct {
    limits: wire.Limits = .{},
    host_grace: i64 = 30_000,
};

pub fn init(gpa: Allocator, random: std.Random, out: Out, config: Config) Relay {
    assert(config.limits.max_peers >= 2 and config.limits.max_peers <= max_peers);
    return .{ .gpa = gpa, .random = random, .out = out, .limits = config.limits, .host_grace = config.host_grace };
}

pub fn deinit(relay: *Relay) void {
    while (relay.room_list.first) |node| relay.free(@fieldParentPtr("node", node));
    relay.rooms.deinit(relay.gpa);
}

pub fn roomCount(relay: *const Relay) usize {
    return relay.rooms.count();
}

// Events

pub fn opened(relay: *Relay, link: *Link, now: i64) void {
    relay.now = now;
    link.heard = now;
    relay.lobby.append(&link.node);
}

pub fn closed(relay: *Relay, link: *Link, now: i64) void {
    relay.now = now;
    relay.forget(link);
}

/// A whole frame heard on `link`. The relay may change its header in place, stamping the sender.
pub fn received(relay: *Relay, link: *Link, frame: []u8, now: i64) void {
    relay.now = now;
    link.heard = now;
    const is_snapshot = frame.len > 1 and frame[1] == @backingInt(wire.Kind.snapshot);
    if (frame.len > if (is_snapshot) relay.limits.max_snapshot else relay.limits.max_frame) return relay.drop(link);
    const header = wire.Header.ofFrame(frame) catch return relay.drop(link);
    const room = link.room orelse return relay.hello(link, header, frame[wire.header_size..]);
    if (room.host == link) return relay.fromHost(room, header, frame);
    const guest = room.guest(link) orelse return relay.drop(link);
    relay.fromGuest(room, guest, header, frame);
}

/// Lets go of silent connections, and ends rooms whose host hasn't come back.
pub fn tick(relay: *Relay, now: i64) void {
    relay.now = now;
    var next = relay.lobby.first;
    while (next) |node| {
        next = node.next;
        const link: *Link = @fieldParentPtr("node", node);
        if (relay.isSilent(link)) relay.drop(link);
    }
    next = relay.room_list.first;
    while (next) |node| {
        next = node.next;
        const room: *Room = @fieldParentPtr("node", node);
        relay.dropSilent(room);
        if (room.host_gone) |gone| if (now - gone > relay.host_grace) relay.end(room, "The host stopped sharing.");
    }
}

fn isSilent(relay: *const Relay, link: *const Link) bool {
    return relay.now - link.heard > timeout;
}

/// Drops a room's silent connections in the order of their ids, the host's among the guests', as the reference does:
/// each one dropped is a `left` the next one hears.
fn dropSilent(relay: *Relay, room: *Room) void {
    var host_due = if (room.host) |host| relay.isSilent(host) else false;
    var i: usize = 0;
    while (i < room.guests.items.len) {
        const link = room.guests.items[i].link;
        if (host_due and room.host.?.id < link.id) {
            host_due = false;
            relay.drop(room.host.?);
        } else if (relay.isSilent(link)) {
            relay.drop(link);
        } else {
            i += 1;
        }
    }
    if (host_due) relay.drop(room.host.?);
}

// Joining

fn hello(relay: *Relay, link: *Link, header: wire.Header, body: []const u8) void {
    if (header.kind != .hello) return relay.drop(link);
    const h = wire.Hello.parse(body) catch return relay.drop(link);
    switch (h.role) {
        .host => {
            if (h.name.len > wire.max_name or h.title.len > wire.max_title) {
                return relay.refuse(link, "That name or title is too long.");
            }
            const room = relay.makeRoom(h) catch return relay.refuse(link, "The relay is full.");
            relay.attachHost(link, room);
        },
        .@"resume" => {
            const room = relay.rooms.get(h.room) orelse return relay.refuse(link, "That session has ended.");
            if (!matches(h.secret, room.host_secret)) return relay.refuse(link, "That session has ended.");
            if (room.host) |old| relay.drop(old);
            relay.attachHost(link, room);
        },
        .guest, .view => {
            const invalid = "That link isn't valid, or the session has ended.";
            const room = relay.rooms.get(h.room) orelse return relay.refuse(link, invalid);
            if (!matches(h.secret, if (h.role == .guest) room.guest_secret else room.view_secret)) {
                return relay.refuse(link, invalid);
            }
            if (h.client.len == 0 or h.client.len > wire.max_client) return relay.refuse(link, "Say which client this is.");
            if (h.name.len > wire.max_name) return relay.refuse(link, "That name is too long.");
            relay.join(link, h, room);
        },
    }
}

fn matches(given: []const u8, expected: Secret) bool {
    return given.len == expected.len and std.crypto.timing_safe.eql(Secret, given[0..expected.len].*, expected);
}

fn attachHost(relay: *Relay, link: *Link, room: *Room) void {
    relay.lobby.remove(&link.node);
    link.room = room;
    room.host = link;
    room.host_gone = null;
    room.awaiting_snapshot = true;
    room.snapshot_requested = false;
    relay.welcome(link, room, wire.host_peer, .with_secrets);
}

fn join(relay: *Relay, link: *Link, h: wire.Hello, room: *Room) void {
    const known = room.client(h.client);
    // The same client on another connection is a dead one it's left behind.
    if (known) |client| {
        for (room.guests.items, 0..) |g, i| {
            if (g.client != client) continue;
            _ = room.guests.orderedRemove(i);
            relay.out.close(g.link);
            break;
        }
    }
    if (room.guests.items.len >= relay.limits.max_peers - 1 or (known == null and room.clients.items.len == max_clients)) {
        return relay.refuse(link, "This session is full.");
    }
    const client = known orelse room.remember(h.client);
    relay.lobby.remove(&link.node);
    link.room = room;
    const peer = room.clients.items[client].peer;
    relay.welcome(link, room, peer, .without_secrets);

    var g: Guest = .{
        .link = link,
        .peer = peer,
        .client = client,
        .name = .init(h.name),
        .can_edit = h.role == .guest,
        .applied = h.applied orelse 0,
        .sent = room.latest,
    };
    // Caught up from the log if it reaches back to what the guest has, from the snapshot if not.
    const log_start = if (room.log.first()) |frame| wire.seqOf(frame) else room.latest + 1;
    if (h.applied != null and h.applied.? + 1 >= log_start and h.applied.? <= room.latest) {
        relay.sendLog(link, room, h.applied.?);
    } else if (room.snapshot) |snapshot| {
        relay.out.send(link, snapshot);
        relay.sendLog(link, room, wire.seqOf(snapshot));
        g.applied = wire.seqOf(snapshot);
    }
    room.add(g);
    var w = relay.frameWriter();
    w.raw(h.name);
    relay.sendToEveryone(room, link, w.finish(.joined, 0, peer));
}

/// The log's frames after `seq`.
fn sendLog(relay: *Relay, link: *Link, room: *const Room, seq: u64) void {
    var it = room.log.iterator();
    while (it.next()) |frame| if (wire.seqOf(frame) > seq) relay.out.send(link, frame);
}

/// The relay's answer to `hello`: the room, its limits, and who's here, with the secrets its links carry for the host.
fn welcome(relay: *Relay, link: *Link, room: *const Room, peer: u32, secrets: enum { with_secrets, without_secrets }) void {
    var w = relay.frameWriter();
    w.varint(peer);
    w.blob(&room.id);
    for ([_]*const Secret{ &room.host_secret, &room.guest_secret, &room.view_secret }) |s| {
        w.blob(if (secrets == .with_secrets) s else &.{});
    }
    const limits = relay.limits;
    for ([_]u32{ limits.max_frame, limits.max_snapshot, limits.log_bytes, limits.max_peers }) |limit| w.varint(limit);
    w.varint(room.latest);
    w.varint(room.version);
    w.blob(room.title.slice());

    // Who's here besides the one welcomed, by peer: the guests, and to a guest, the host.
    const Peer = struct { peer: u32, name: []const u8 };
    var peers: [max_peers]Peer = undefined;
    var count: usize = 0;
    for (room.guests.items) |*g| {
        peers[count] = .{ .peer = g.peer, .name = g.name.slice() };
        count += 1;
    }
    if (peer != wire.host_peer and room.host != null) {
        peers[count] = .{ .peer = wire.host_peer, .name = room.host_name.slice() };
        count += 1;
    }
    std.mem.sortUnstable(Peer, peers[0..count], {}, struct {
        fn lessThan(_: void, a: Peer, b: Peer) bool {
            return a.peer < b.peer;
        }
    }.lessThan);
    w.varint(count);
    for (peers[0..count]) |p| {
        w.varint(p.peer);
        w.blob(p.name);
    }
    relay.out.send(link, w.finish(.hello, 0, 0));
}

// Frames

fn fromHost(relay: *Relay, room: *Room, header: wire.Header, frame: []u8) void {
    const host = room.host.?;
    switch (header.kind) {
        .snapshot => {
            // After hello, its copy as it is, which may be past what reached here before it left. Asked for, the copy
            // as of its latest change, all of which has come first.
            const fits = if (room.awaiting_snapshot) header.seq >= room.latest else header.seq == room.latest;
            if (!fits) return relay.drop(host);
            const snapshot = room.snapshot_buffer[0..frame.len];
            @memcpy(snapshot, frame);
            room.snapshot = snapshot;
            room.snapshot_requested = false;
            if (header.seq > room.latest) {
                // Changes that never reached here: the log can't catch anyone up past them, so it starts again.
                room.log.clear();
                room.latest = header.seq;
                for (room.guests.items) |*g| {
                    if (g.sent >= header.seq) continue;
                    relay.out.send(g.link, snapshot);
                    g.sent = header.seq;
                }
            }
            if (room.awaiting_snapshot) {
                room.awaiting_snapshot = false;
                // Back: guests send again whatever it may have missed.
                var w = relay.frameWriter();
                w.raw(room.host_name.slice());
                const back = w.finish(.joined, 0, wire.host_peer);
                for (room.guests.items) |g| relay.out.send(g.link, back);
            }
            room.trim();
        },
        .ops, .reject => {
            if (room.awaiting_snapshot or header.seq != room.latest + 1) return relay.drop(host);
            // Room for it: frames the snapshot covers go, and with them any guest still behind them, which comes back
            // and catches up from the snapshot. Frames past the snapshot can't go, so the host comes back with a new
            // one.
            while (room.log.bytes + frame.len > relay.limits.log_bytes) {
                const first = room.log.first() orelse return relay.drop(host);
                const snapshot = room.snapshot orelse return relay.drop(host);
                const first_seq = wire.seqOf(first);
                if (first_seq > wire.seqOf(snapshot)) return relay.drop(host);
                var i: usize = 0;
                while (i < room.guests.items.len) {
                    if (room.guests.items[i].applied < first_seq) relay.drop(room.guests.items[i].link) else i += 1;
                }
                // With no one behind it, the snapshot covers it, so trimming takes it.
                room.trim();
                if (room.log.first()) |f| if (wire.seqOf(f) == first_seq) room.log.pop();
            }
            room.log.push(frame);
            room.latest = header.seq;
            for (room.guests.items) |*g| {
                relay.out.send(g.link, frame);
                g.sent = room.latest;
            }
            if (!room.snapshot_requested and room.log.bytes * 2 > relay.limits.log_bytes) {
                room.snapshot_requested = true;
                var w = relay.frameWriter();
                relay.out.send(host, w.finish(.snapshot_request, 0, 0));
            }
        },
        .presence => {
            wire.stamp(frame, wire.host_peer);
            for (room.guests.items) |g| relay.out.send(g.link, frame);
        },
        .ping => relay.pong(host, room),
        .bye => {
            // Passed on as the relay's own bye: the host's header, cleared but for its kind and length.
            @memset(frame[8..wire.header_size], 0);
            frame[2] = 0;
            frame[3] = 0;
            relay.endWith(room, frame);
        },
        else => {},
    }
}

fn fromGuest(relay: *Relay, room: *Room, g: *Guest, header: wire.Header, frame: []u8) void {
    switch (header.kind) {
        .change => {
            if (!g.can_edit) return relay.drop(g.link);
            // While the host's away, changes go nowhere; guests send them again when it's back.
            const host = room.host orelse return;
            wire.stamp(frame, g.peer);
            relay.out.send(host, frame);
        },
        .presence => {
            wire.stamp(frame, g.peer);
            relay.sendToEveryone(room, g.link, frame);
        },
        .ping => {
            g.applied = @min(header.seq, room.latest);
            const link = g.link;
            room.trim();
            relay.pong(link, room);
        },
        else => {},
    }
}

fn pong(relay: *Relay, link: *Link, room: *const Room) void {
    var w = relay.frameWriter();
    relay.out.send(link, w.finish(.pong, room.latest, 0));
}

// Leaving

/// To the host, then the guests in order, but for `excluded`.
fn sendToEveryone(relay: *Relay, room: *const Room, excluded: ?*const Link, frame: []const u8) void {
    if (room.host) |host| if (host != excluded) relay.out.send(host, frame);
    for (room.guests.items) |g| if (g.link != excluded) relay.out.send(g.link, frame);
}

/// Closes a connection, as the relay's decision.
fn drop(relay: *Relay, link: *Link) void {
    relay.out.close(link);
    relay.forget(link);
}

fn refuse(relay: *Relay, link: *Link, reason: []const u8) void {
    relay.out.send(link, relay.bye(reason));
    relay.drop(link);
}

fn bye(relay: *Relay, reason: []const u8) []const u8 {
    var w = relay.frameWriter();
    w.raw(reason);
    return w.finish(.bye, 0, 0);
}

/// A connection's gone: others are told who's left.
fn forget(relay: *Relay, link: *Link) void {
    const room = link.room orelse return relay.lobby.remove(&link.node);
    var w = relay.frameWriter();
    if (room.host == link) {
        room.host = null;
        room.host_gone = relay.now;
        const left = w.finish(.left, 0, wire.host_peer);
        for (room.guests.items) |g| relay.out.send(g.link, left);
        return;
    }
    const g = room.remove(link) orelse return;
    room.trim();
    relay.sendToEveryone(room, null, w.finish(.left, 0, g.peer));
}

fn end(relay: *Relay, room: *Room, reason: []const u8) void {
    relay.endWith(room, relay.bye(reason));
}

fn endWith(relay: *Relay, room: *Room, bye_frame: []const u8) void {
    if (room.host) |host| {
        relay.out.send(host, bye_frame);
        relay.out.close(host);
    }
    for (room.guests.items) |g| {
        relay.out.send(g.link, bye_frame);
        relay.out.close(g.link);
    }
    relay.free(room);
}

fn frameWriter(relay: *Relay) wire.FrameWriter {
    return .{ .buffer = &relay.scratch };
}

// Rooms

const Secret = [32]u8;

/// Bytes up to a fixed length, kept in place.
fn Text(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8,
        len: std.math.IntFittingRange(0, capacity),

        fn init(bytes: []const u8) @This() {
            var text: @This() = .{ .buffer = undefined, .len = @intCast(bytes.len) };
            @memcpy(text.buffer[0..bytes.len], bytes);
            return text;
        }

        fn slice(text: *const @This()) []const u8 {
            return text.buffer[0..text.len];
        }
    };
}

const Guest = struct {
    link: *Link,
    peer: u32,
    /// Its index in the room's clients.
    client: usize,
    name: Text(wire.max_name),
    can_edit: bool,
    /// The last change it's said it has, from its pings, which the log keeps until it's past. 0 for none.
    applied: u64,
    /// The last change sent to it.
    sent: u64,
};

const Client = struct {
    id: Text(wire.max_client),
    peer: u32,
};

pub const Room = struct {
    node: DoublyLinkedList.Node = .{},
    id: Secret,
    host_secret: Secret,
    guest_secret: Secret,
    view_secret: Secret,
    version: u64,
    title: Text(wire.max_title),
    host_name: Text(wire.max_name),
    host: ?*Link = null,
    host_gone: ?i64 = null,
    /// Between the host's hello and its snapshot, which always follows it.
    awaiting_snapshot: bool = true,
    snapshot_requested: bool = false,
    log: Log,
    latest: u64 = 0,
    snapshot: ?[]const u8 = null,
    snapshot_buffer: []u8,
    /// Connected, in the order of their links' ids.
    guests: std.ArrayList(Guest),
    /// Everyone who's joined, each with their peer for the room's life, so they're the same person through
    /// reconnecting.
    clients: std.ArrayList(Client),
    next_peer: u32 = wire.host_peer + 1,
    /// The one block the log and snapshot live in.
    memory: []u8,

    fn guest(room: *Room, link: *const Link) ?*Guest {
        for (room.guests.items) |*g| if (g.link == link) return g;
        return null;
    }

    fn add(room: *Room, g: Guest) void {
        var i = room.guests.items.len;
        while (i > 0 and room.guests.items[i - 1].link.id > g.link.id) i -= 1;
        room.guests.insertAssumeCapacity(i, g);
    }

    fn remove(room: *Room, link: *const Link) ?Guest {
        for (room.guests.items, 0..) |g, i| if (g.link == link) return room.guests.orderedRemove(i);
        return null;
    }

    fn client(room: *const Room, id: []const u8) ?usize {
        for (room.clients.items, 0..) |c, i| if (std.mem.eql(u8, c.id.slice(), id)) return i;
        return null;
    }

    fn remember(room: *Room, id: []const u8) usize {
        room.clients.appendAssumeCapacity(.{ .id = .init(id), .peer = room.next_peer });
        room.next_peer += 1;
        return room.clients.items.len - 1;
    }

    /// The log keeps everything back to the older of the snapshot and the oldest guest's last change: frames no one
    /// needs to catch up from go.
    fn trim(room: *Room) void {
        const snapshot = room.snapshot orelse return;
        var needed = wire.seqOf(snapshot);
        for (room.guests.items) |g| needed = @min(needed, g.applied);
        while (room.log.first()) |frame| {
            if (wire.seqOf(frame) > needed) break;
            room.log.pop();
        }
    }
};

fn makeRoom(relay: *Relay, h: wire.Hello) Allocator.Error!*Room {
    const gpa = relay.gpa;
    const limits = relay.limits;
    const log_capacity = Log.capacity(limits.log_bytes, limits.max_frame);
    const room = try gpa.create(Room);
    errdefer gpa.destroy(room);
    const memory = try gpa.alloc(u8, log_capacity + limits.max_snapshot);
    errdefer gpa.free(memory);
    const guests = try gpa.alloc(Guest, limits.max_peers - 1);
    errdefer gpa.free(guests);
    const clients = try gpa.alloc(Client, max_clients);
    errdefer gpa.free(clients);
    try relay.rooms.ensureUnusedCapacity(gpa, 1);

    // In the reference's order: the room's ID, then the host's, guests' and viewers' secrets.
    const id = relay.makeSecret();
    const host_secret = relay.makeSecret();
    const guest_secret = relay.makeSecret();
    const view_secret = relay.makeSecret();
    room.* = .{
        .id = id,
        .host_secret = host_secret,
        .guest_secret = guest_secret,
        .view_secret = view_secret,
        .version = h.version,
        .title = .init(h.title),
        .host_name = .init(h.name),
        .log = .init(memory[0..log_capacity]),
        .snapshot_buffer = memory[log_capacity..],
        .guests = .initBuffer(guests),
        .clients = .initBuffer(clients),
        .memory = memory,
    };
    relay.rooms.putAssumeCapacityNoClobber(&room.id, room);
    relay.room_list.append(&room.node);
    return room;
}

fn free(relay: *Relay, room: *Room) void {
    assert(relay.rooms.remove(&room.id));
    relay.room_list.remove(&room.node);
    relay.gpa.free(room.guests.allocatedSlice());
    relay.gpa.free(room.clients.allocatedSlice());
    relay.gpa.free(room.memory);
    relay.gpa.destroy(room);
}

/// 16 random bytes, as hex.
fn makeSecret(relay: *Relay) Secret {
    var bytes: [16]u8 = undefined;
    relay.random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}
