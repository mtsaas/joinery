//! `zig build bench`: times each step a frame takes through the relay, and counts what it allocates, which must be
//! nothing. Results for a commit go in bench/results.txt (docs/relay.md, "Measuring the relay").

const std = @import("std");
const Io = std.Io;
const Relay = @import("relay/Relay.zig");
const Log = @import("relay/Log.zig");
const websocket = @import("server/websocket.zig");
const wire = @import("relay/wire.zig");
const udp = @import("server/udp.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var counting: std.testing.FailingAllocator = .init(std.heap.page_allocator, .{});
    const gpa = counting.allocator();

    std.debug.print("{s:<52} {s:>10} {s:>12}\n", .{ "step", "ns/frame", "allocations" });

    var frame: [24 + 64]u8 = @splat(0);
    _ = writeHeader(&frame, .ops, 1);
    try bench(io, &counting, "read a header", 10_000_000, struct {
        fn run(f: *[88]u8, i: usize) void {
            f[8] = @truncate(i);
            std.mem.doNotOptimizeAway(wire.Header.ofFrame(f) catch unreachable);
        }
    }.run, .{&frame});

    // Unmasking: a change's worth, and a whole snapshot's, which is where it counts.
    const snapshot = try gpa.alloc(u8, 1 << 20);
    @memset(snapshot, 7);
    try bench(io, &counting, "unmask a 124-byte change", 10_000_000, struct {
        fn run(bytes: []u8, i: usize) void {
            websocket.unmask(bytes[0..124], .{ 1, 2, 3, @truncate(i) });
        }
    }.run, .{snapshot});
    try bench(io, &counting, "unmask a 1 MiB snapshot", 200, struct {
        fn run(bytes: []u8, i: usize) void {
            websocket.unmask(bytes, .{ 1, 2, 3, @truncate(i) });
        }
    }.run, .{snapshot});

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

    // The same, but each change in another of many rooms, so their guests aren't still in the cache from the last.
    var rooms: Rooms = undefined;
    try rooms.init(gpa, 2000);
    defer rooms.deinit();
    try bench(io, &counting, "a host's change, to 31 guests, across 2,000 rooms", 1_000_000, Rooms.publish, .{&rooms});
    std.debug.print("{d} frames sent in all\n", .{room.sink.sent + rooms.sink.sent});

    // Presence over UDP: a pointer update's frame, as the app seals one (a 64-byte presence, a nonce and a tag).
    var presence: [wire.header_size + 92]u8 = @splat(3);
    _ = writeHeader(&presence, .presence, 1);
    var one: Udp = .init(udp.vector.ticket, &presence);
    try bench(io, &counting, "seal a pointer update for a client", 10_000_000, Udp.seal, .{&one});
    try bench(io, &counting, "  its counter blocks: 3 of AES-128", 10_000_000, struct {
        fn run(u: *Udp, i: usize) void {
            var n: [12]u8 = @splat(0);
            n[11] = @truncate(i);
            std.mem.doNotOptimizeAway(u.session.gcm.keystream(n));
        }
    }.run, .{&one});
    try bench(io, &counting, "  its tag: GHASH over 9 blocks", 10_000_000, struct {
        fn run(u: *Udp, i: usize) void {
            var j: [16]u8 = @splat(@truncate(i));
            std.mem.doNotOptimizeAway(u.session.gcm.tagOf(&j, u.frame[0..24], u.frame[24..]));
        }
    }.run, .{&one});
    try bench(io, &counting, "  its counter's mask: 1 of AES-128", 10_000_000, struct {
        fn run(u: *Udp, i: usize) void {
            var b: [16]u8 = @splat(@truncate(i));
            std.mem.doNotOptimizeAway(u.session.maskOf(&b));
        }
    }.run, .{&one});

    try bench(io, &counting, "the same, keys expanded every time (std AES-128-GCM)", 10_000_000, Udp.sealUncached, .{&one});
    try bench(io, &counting, "open a pointer update from a client", 10_000_000, Udp.open, .{&one});
    const many = try Udps.init(gpa, 100_000, &presence);
    defer many.deinit(gpa);
    try bench(io, &counting, "find and open one, among 100,000 connections", 1_000_000, Udps.open, .{many});
    try bench(io, &counting, "the same, a batch of 32 asked for first", 1_000_000, Udps.openBatched, .{many});
    try bench(io, &counting, "one in, three out, among 100,000 connections", 1_000_000, Udps.fanOut, .{many});
    try bench(io, &counting, "the same, batched as the relay does", 1_000_000, Udps.fanOutBatched, .{many});
    std.debug.print("a session: {d} bytes ({d}-byte cache lines), at: mask key {d}, GCM key {d}, GHASH powers {d}, ID {d}, counters {d}..{d}\n", .{
        @sizeOf(udp.Session),                                                               std.atomic.cache_line,
        @offsetOf(udp.Session, "mask"),                                                     @offsetOf(udp.Session, "gcm"),
        @offsetOf(udp.Session, "gcm") + @offsetOf(@FieldType(udp.Session, "gcm"), "ghash"), @offsetOf(udp.Session, "id"),
        @offsetOf(udp.Session, "sent"),                                                     @offsetOf(udp.Session, "seen") + 8,
    });
}

/// One connection's session, a datagram from its client kept as it came (opening it works in place), and the counter
/// window put back each time, so the same datagram opens again.
const Udp = struct {
    session: udp.Session,
    ticket: udp.Ticket,
    frame: []const u8,
    out: [udp.max_datagram]u8 = undefined,
    datagram: [udp.max_datagram]u8 = undefined,
    len: usize = 0,
    work: [udp.max_datagram]u8 = undefined,

    fn init(ticket: udp.Ticket, frame: []const u8) Udp {
        var u: Udp = .{ .session = .init(ticket), .ticket = ticket, .frame = frame };
        var client: udp.Session = .init(ticket);
        u.len = client.seal(.to_relay, frame, &u.datagram).len;
        return u;
    }

    fn seal(u: *Udp, _: usize) void {
        std.mem.doNotOptimizeAway(u.session.seal(.to_client, u.frame, &u.out).ptr);
    }

    /// What sealing costs with the standard library's AES-GCM, which works out the key's schedule and GHASH's key for
    /// every message, as a first version of this did.
    fn sealUncached(u: *Udp, i: usize) void {
        const body = u.frame[wire.header_size..];
        var nonce: [12]u8 = @splat(0);
        std.mem.writeInt(u64, nonce[4..12], i, .little);
        std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(u.out[udp.prefix..][0..wire.header_size], u.out[16..32], u.frame[0..wire.header_size], body, nonce, u.ticket.key);
        const mask = std.crypto.core.aes.Aes128.initEnc(u.ticket.mask_key);
        var block: [16]u8 = undefined;
        mask.encrypt(&block, u.out[udp.prefix..][0..16]);
        std.mem.doNotOptimizeAway(&block);
    }

    /// A fixed-size copy (2 ns), not `@memcpy` of a runtime length: that's a call into libc, and reading straight back
    /// what it wrote stalled store forwarding and doubled what this measured.
    fn open(u: *Udp, _: usize) void {
        u.work[0 .. udp.prefix + wire.header_size + 92].* = u.datagram[0 .. udp.prefix + wire.header_size + 92].*;
        u.session.newest = 0;
        u.session.seen = 0;
        std.mem.doNotOptimizeAway((u.session.open(.to_relay, u.work[0..u.len]) orelse unreachable).ptr);
    }
};

/// Many connections, each a session and a datagram from its client, visited in a scattered order so each is cold, as a
/// relay's are when thousands are sending.
const Udps = struct {
    sessions: []udp.Session,
    datagrams: [][udp.prefix + wire.header_size + 92]u8,
    order: []u32,
    frame: []const u8,
    work: [udp.max_datagram]u8 = undefined,
    out: [3][udp.max_datagram]u8 = undefined,
    queued: [96][udp.prefix + wire.header_size + 92]u8 = undefined,
    recipients: [96]u32 = undefined,

    fn init(gpa: std.mem.Allocator, count: usize, frame: []const u8) !*Udps {
        const u = try gpa.create(Udps);
        u.* = .{ .sessions = try gpa.alloc(udp.Session, count), .datagrams = try gpa.alloc([udp.prefix + wire.header_size + 92]u8, count), .order = try gpa.alloc(u32, count), .frame = frame };
        var prng: std.Random.DefaultPrng = .init(3);
        for (u.sessions, u.datagrams, u.order, 0..) |*s, *d, *o, i| {
            var ticket = udp.vector.ticket;
            ticket.id = i;
            prng.random().bytes(&ticket.key);
            s.* = .init(ticket);
            var client: udp.Session = .init(ticket);
            _ = client.seal(.to_relay, frame, d);
            o.* = @intCast(i);
        }
        prng.random().shuffle(u32, u.order);
        return u;
    }

    fn deinit(u: *Udps, gpa: std.mem.Allocator) void {
        gpa.free(u.sessions);
        gpa.free(u.datagrams);
        gpa.free(u.order);
        gpa.destroy(u);
    }

    /// As the relay does for a datagram: its connection by the slot in its ID, then open it.
    fn open(u: *Udps, i: usize) void {
        const d = &u.datagrams[u.order[i % u.order.len]];
        @memcpy(u.work[0..d.len], d);
        const s = &u.sessions[udp.slotOf(udp.idOf(&u.work).?)];
        s.newest = 0;
        s.seen = 0;
        std.mem.doNotOptimizeAway((s.open(.to_relay, u.work[0..d.len]) orelse unreachable).ptr);
    }

    /// As `open`, but at each 32nd, the next 32's sessions asked for first, as the relay does for each batch it reads.
    fn openBatched(u: *Udps, i: usize) void {
        if (i % 32 == 0) for (0..32) |k| u.sessions[u.order[(i + k) % u.order.len]].prefetch();
        u.open(i);
    }

    /// As `fanOut`, but sealing as the relay does: the frames queued, then at each 32nd, every recipient's session
    /// asked for first and all sealed in place.
    fn fanOutBatched(u: *Udps, i: usize) void {
        u.openBatched(i);
        const n = u.order.len;
        for (0..3) |k| {
            const at = (i % 32) * 3 + k;
            @memcpy(u.queued[at][udp.prefix..][0..u.frame.len], u.frame);
            u.recipients[at] = u.order[(i * 7 + k * 7919 + 1) % n];
        }
        if (i % 32 != 31) return;
        for (u.recipients) |r| u.sessions[r].prefetch();
        for (&u.queued, u.recipients) |*q, r| std.mem.doNotOptimizeAway(u.sessions[r].sealInPlace(.to_client, q[0 .. udp.prefix + u.frame.len]).ptr);
    }

    /// A guest's pointer update in a room of four: opened, then sealed for each of the three others, each cold.
    fn fanOut(u: *Udps, i: usize) void {
        u.open(i);
        const n = u.order.len;
        for (0..3) |k| {
            const s = &u.sessions[u.order[(i * 7 + k * 7919 + 1) % n]];
            std.mem.doNotOptimizeAway(s.seal(.to_client, u.frame, &u.out[k]).ptr);
        }
    }
};

/// Runs `step` `n` times, five times over, and prints the best of the five, per step, and the allocations made, which
/// must be none. The best, not the mean: what else the machine's doing only ever adds time.
fn bench(io: Io, counting: *std.testing.FailingAllocator, name: []const u8, n: usize, step: anytype, args: anytype) !void {
    const allocations = counting.allocations;
    var best: f64 = std.math.inf(f64);
    for (0..5) |round| {
        const start = Io.Clock.awake.now(io);
        for (0..n) |i| @call(.auto, step, args ++ .{round * n + i});
        const elapsed = start.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
        best = @min(best, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(n)));
    }
    const made = counting.allocations - allocations;
    std.debug.print("{s:<52} {d:>10.1} {d:>12}\n", .{ name, best, made });
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

/// Many rooms of a host and 31 guests in one relay, each change going to the next room round.
const Rooms = struct {
    sink: Sink = .{},
    relay: Relay,
    prng: std.Random.DefaultPrng = .init(2),
    links: []Relay.Link,
    seqs: []u64,
    frame: [24 + 200]u8 = @splat(0),
    const per_room = 32;

    fn init(rooms: *Rooms, gpa: std.mem.Allocator, count: usize) !void {
        rooms.* = .{ .relay = undefined, .links = try gpa.alloc(Relay.Link, count * per_room), .seqs = try gpa.alloc(u64, count) };
        @memset(rooms.seqs, 0);
        rooms.relay = .init(gpa, rooms.prng.random(), .{ .ptr = &rooms.sink, .vtable = &.{ .send = Sink.send, .close = Sink.close } }, .{});
        var buffer: [512]u8 = undefined;
        var snapshot: [24 + 4096]u8 = @splat(0);
        for (0..count) |r| {
            const host = &rooms.links[r * per_room];
            host.* = .{ .id = r * per_room };
            var w: wire.FrameWriter = .{ .buffer = &buffer };
            w.byte(@backingInt(wire.Role.host));
            for (0..3) |_| w.blob("");
            w.varint(0);
            w.varint(wire.room_version);
            w.blob("Host");
            w.blob("Bench");
            rooms.relay.opened(host, 0);
            rooms.relay.received(host, w.finish(.hello, 0, 0), 0);
            rooms.relay.received(host, writeHeader(&snapshot, .snapshot, 0), 0);
            const room = host.room.?;
            for (1..per_room) |i| {
                const g = &rooms.links[r * per_room + i];
                g.* = .{ .id = r * per_room + i };
                var client: [8]u8 = undefined;
                w = .{ .buffer = &buffer };
                w.byte(@backingInt(wire.Role.guest));
                w.blob(&room.id);
                w.blob(&room.guest_secret);
                w.blob(std.fmt.bufPrint(&client, "c{d}", .{i}) catch unreachable);
                w.varint(0);
                w.varint(wire.room_version);
                w.blob("Guest");
                w.blob("");
                rooms.relay.opened(g, 0);
                rooms.relay.received(g, w.finish(.hello, 0, 0), 0);
            }
        }
    }

    fn deinit(rooms: *Rooms) void {
        rooms.relay.deinit();
    }

    fn publish(rooms: *Rooms, i: usize) void {
        const r = i % rooms.seqs.len;
        rooms.seqs[r] += 1;
        rooms.relay.received(&rooms.links[r * per_room], writeHeader(&rooms.frame, .ops, rooms.seqs[r]), 0);
    }
};
