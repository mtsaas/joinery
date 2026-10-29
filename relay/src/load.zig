//! `zig build load -- [--host 127.0.0.1] [--port 8787] [--rooms 10] [--guests 3] [--rate 20] [--presence 0]
//! [--slow 0] [--seconds 10] [--threads <cores>] [--sources 10.0.0.5,10.0.0.6]`: a load generator for a relay already running, here or at `--host`.
//! Each room has a host publishing changes at `rate` a second, each carrying when it was sent, and `guests` guests
//! that read them, pinging now and then so the log can be trimmed, and each sending `presence` pointer updates a
//! second, as a moving pointer does. At the end it prints changes delivered a second and the time from the host's
//! send to a guest's receive. On one machine, the times are the relay's, the kernel's and this program's, with no
//! network.
//!
//! It runs as the relay does, an event loop a core, each with its share of the rooms, so one machine can drive many
//! connections without a thread for each.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const c = std.c;
const wire = @import("relay/wire.zig");
const poller = @import("server/poller.zig");
const socket = @import("server/socket.zig");

/// Where the relay is.
var relay_address: [4]u8 = .{ 127, 0, 0, 1 };
/// This machine's addresses to connect from, in turn: one has ports for about 55,000 connections to the relay.
var sources: [16][4]u8 = undefined;
var source_count: usize = 0;
var next_source: std.atomic.Value(usize) = .init(0);

const Config = struct {
    port: u16 = 8787,
    rooms: usize = 10,
    guests: usize = 3,
    /// Changes a second, per room.
    rate: u64 = 20,
    /// Pointer updates a second, per guest.
    presence: u64 = 0,
    /// Guests in each room on a slow connection, reading 50 messages a second, measured on their own.
    slow: u64 = 0,
    seconds: u64 = 10,
    /// Event loops: one a core if 0.
    threads: usize = 0,
};

/// Loops that have opened their rooms, and when they all start counting, once they have.
var opened: std.atomic.Value(usize) = .init(0);
var start_ns: std.atomic.Value(i64) = .init(0);

/// What a loop's guests saw: changes delivered, and their latencies in buckets an eighth of a doubling wide (9%
/// apart), from a microsecond to over an hour. Each loop keeps its own, added up at the end.
const Stats = struct {
    delivered: u64 = 0,
    presence: u64 = 0,
    /// Pointer updates sent, each due to everyone else in the room.
    presence_sent: u64 = 0,
    buckets: [bucket_count]u64 = @splat(0),
    const per_doubling = 8;
    const bucket_count = 32 * per_doubling;

    fn record(stats: *Stats, latency_ns: i64) void {
        stats.delivered += 1;
        const us: f64 = @max(@as(f64, @floatFromInt(latency_ns)) / 1000, 1);
        const bucket: usize = @intFromFloat(@min(@log2(us) * per_doubling, bucket_count - 1));
        stats.buckets[bucket] += 1;
    }

    fn add(total: *Stats, other: Stats) void {
        total.delivered += other.delivered;
        total.presence += other.presence;
        total.presence_sent += other.presence_sent;
        for (&total.buckets, other.buckets) |*t, o| t.* += o;
    }

    /// The `p` quantile's latency, in µs: the top of its bucket.
    fn percentile(stats: *const Stats, p: f64) f64 {
        if (stats.delivered == 0) return 0;
        const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(stats.delivered)) * p));
        var seen: u64 = 0;
        for (stats.buckets, 0..) |b, i| {
            seen += b;
            if (seen >= target) return @round(std.math.pow(f64, 2, @as(f64, @floatFromInt(i + 1)) / per_doubling));
        }
        return std.math.inf(f64);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var config: Config = .{};
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        const text = args.next() orelse return error.Usage;
        // The relay's address, if it's on another machine.
        if (std.mem.eql(u8, arg, "--host")) {
            relay_address = (Io.net.Ip4Address.parse(text, 0) catch return error.Usage).bytes;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sources")) {
            var each = std.mem.tokenizeScalar(u8, text, ',');
            while (each.next()) |source| : (source_count += 1) {
                if (source_count == sources.len) return error.Usage;
                sources[source_count] = (Io.net.Ip4Address.parse(source, 0) catch return error.Usage).bytes;
            }
            continue;
        }
        const value = std.fmt.parseInt(u64, text, 10) catch return error.Usage;
        // Each flag sets the field it names: --rooms 10 sets rooms.
        const name = if (std.mem.startsWith(u8, arg, "--")) arg[2..] else return error.Usage;
        inline for (@typeInfo(Config).@"struct".field_names) |field| {
            if (std.mem.eql(u8, name, field)) {
                @field(config, field) = @intCast(value);
                break;
            }
        } else return error.Usage;
    }
    if (config.threads == 0) config.threads = std.Thread.getCpuCount() catch 1;
    config.threads = std.math.clamp(config.threads, 1, @max(config.rooms, 1));

    // Each loop opens its share of the rooms; when all have, every loop counts from a second later.
    const loops = try init.gpa.alloc(Loop, config.threads);
    const threads = try init.gpa.alloc(std.Thread, config.threads);
    for (loops, threads, 0..) |*loop, *thread, i| {
        const rooms = config.rooms / config.threads + @intFromBool(i < config.rooms % config.threads);
        loop.* = .{
            .io = io,
            .config = config,
            .rooms = try init.gpa.alloc(Room, rooms),
            .conns = try init.gpa.alloc(Conn, rooms * (1 + config.guests)),
            .poller = try poller.Poller.init(),
        };
        thread.* = try std.Thread.spawn(.{}, Loop.run, .{loop});
    }
    while (opened.load(.acquire) < loops.len) try io.sleep(.fromMilliseconds(1), .awake);
    start_ns.store(nowNs(io) + std.time.ns_per_s, .release);
    for (threads) |thread| thread.join();

    var stats: Stats = .{};
    var slow: Stats = .{};
    var sent: u64 = 0;
    var unopened: u64 = 0;
    var lost: u64 = 0;
    for (loops) |*loop| {
        stats.add(loop.stats);
        slow.add(loop.slow);
        sent += loop.published;
        unopened += loop.unopened;
        lost += loop.lost;
    }
    // Only guests count what they're sent: each update is due to the other guests (the host gets it too, uncounted).
    const presence_due = stats.presence_sent * (config.guests -| 1);
    const seconds: f64 = @floatFromInt(config.seconds);
    const due = sent * (config.guests - config.slow);
    std.debug.print(
        \\rooms {d}, guests each {d}, {d} changes/s each: {d} connections, {d} loops
        \\published {d:.0} changes/s, delivered {d:.0}/s ({d:.0}% of {d})
        \\latency, send to receive: p50 {d:.0} µs, p99 {d:.0} µs, p99.9 {d:.0} µs
        \\pointer updates delivered {d:.0}/s ({d:.0}% of {d} due)
        \\
    , .{
        config.rooms,                                       config.guests,
        config.rate,                                        config.rooms * (config.guests + 1),
        config.threads,                                     @as(f64, @floatFromInt(sent)) / seconds,
        @as(f64, @floatFromInt(stats.delivered)) / seconds, 100 * @as(f64, @floatFromInt(stats.delivered)) / @as(f64, @floatFromInt(@max(due, 1))),
        due,                                                stats.percentile(0.5),
        stats.percentile(0.99),                             stats.percentile(0.999),
        @as(f64, @floatFromInt(stats.presence)) / seconds,  100 * @as(f64, @floatFromInt(stats.presence)) / @as(f64, @floatFromInt(@max(presence_due, 1))),
        presence_due,
    });
    if (config.slow > 0) std.debug.print("slow guests: changes delivered {d:.0}/s, p50 {d:.0} µs, p99 {d:.0} µs, pointer updates {d:.0}/s\n", .{
        @as(f64, @floatFromInt(slow.delivered)) / seconds, slow.percentile(0.5),
        slow.percentile(0.99),                             @as(f64, @floatFromInt(slow.presence)) / seconds,
    });
    if (unopened + lost > 0) std.debug.print("failed: {d} rooms didn't open, {d} connections closed\n", .{ unopened, lost });
}

/// A room's host's schedule: when its next change is due, and the last one's number.
const Room = struct { next_ns: i64 = 0, seq: u64 = 0 };

/// An event loop and its share of the rooms: each room's host, then its guests, in `conns`.
const Loop = struct {
    io: Io,
    config: Config,
    rooms: []Room,
    conns: []Conn,
    poller: poller.Poller,
    /// Whether it's past the start: only then does what's sent and delivered count.
    counting: bool = false,
    stats: Stats = .{},
    slow: Stats = .{},
    published: u64 = 0,
    unopened: u64 = 0,
    lost: u64 = 0,

    fn run(loop: *Loop) void {
        for (loop.rooms, 0..) |*room, r| {
            room.* = .{};
            loop.open(r) catch {
                loop.unopened += 1;
                for (loop.roomConns(r)) |*conn| conn.close();
            };
        }
        _ = opened.fetchAdd(1, .release);
        var events: [256]poller.Event = undefined;
        var end: i64 = std.math.maxInt(i64);
        while (true) {
            for (loop.poller.wait(&events, 1) catch return) |event| loop.receive(@ptrFromInt(event.tag));
            const now = nowNs(loop.io);
            if (now >= end) return;
            const start = start_ns.load(.acquire);
            if (start != 0) {
                end = start + @as(i64, @intCast(loop.config.seconds * std.time.ns_per_s));
                loop.counting = now >= start;
            }
            loop.tick(now);
        }
    }

    fn roomConns(loop: *Loop, r: usize) []Conn {
        return loop.conns[r * (1 + loop.config.guests) ..][0 .. 1 + loop.config.guests];
    }

    /// Opens room `r`: its host, which says hello, sends its snapshot and is welcomed, then its guests, who join
    /// with the room's secret. Blocking until it's done, then watched without blocking.
    fn open(loop: *Loop, r: usize) !void {
        const conns = loop.roomConns(r);
        for (conns, 0..) |*conn, i| conn.* = .{ .room = @intCast(r), .role = if (i == 0) .host else if (i - 1 < loop.config.slow) .slow else .guest };
        const host = &conns[0];
        try host.connect(loop.config.port);
        var w = frameWriter();
        w.byte(@backingInt(wire.Role.host));
        for (0..3) |_| w.blob("");
        w.varint(0);
        w.varint(wire.room_version);
        w.blob("Load");
        w.blob("Load");
        _ = host.queue(w.finish(.hello, 0, 0));
        _ = host.queueSnapshot(0);
        try host.flushAll();
        // The welcome: the room, and the guests' secret.
        var welcome: Reader = .{ .bytes = (try host.receiveBlocking())[wire.header_size..] };
        _ = welcome.varint();
        var id: [32]u8 = undefined;
        var secret: [32]u8 = undefined;
        const room_id = id[0..welcome.blobInto(&id)];
        _ = welcome.blob();
        const guest_secret = secret[0..welcome.blobInto(&secret)];

        for (conns[1..], 0..) |*guest, i| {
            try guest.connect(loop.config.port);
            var client: [16]u8 = undefined;
            w = frameWriter();
            w.byte(@backingInt(wire.Role.guest));
            w.blob(room_id);
            w.blob(guest_secret);
            w.blob(std.fmt.bufPrint(&client, "load-{d}", .{i}) catch unreachable);
            w.varint(0);
            w.varint(wire.room_version);
            w.blob("Guest");
            w.blob("");
            _ = guest.queue(w.finish(.hello, 0, 0));
            try guest.flushAll();
        }
        for (conns) |*conn| {
            try socket.setNonblocking(conn.fd);
            // A slow guest reads on a timer, not when there's something to.
            if (conn.role != .slow) try loop.poller.add(conn.fd, @intFromPtr(conn));
        }
    }

    fn receive(loop: *Loop, conn: *Conn) void {
        if (conn.fd < 0) return;
        conn.fill(conn.in.len) catch return loop.lose(conn);
        while (conn.next()) |frame| loop.handle(conn, frame);
    }

    fn handle(loop: *Loop, conn: *Conn, frame: []const u8) void {
        if (frame.len < wire.header_size) return;
        const kind = frame[1];
        if (conn.role == .host) {
            if (kind == @backingInt(wire.Kind.snapshot_request)) _ = conn.queueSnapshot(loop.rooms[conn.room].seq);
            return;
        }
        const stats = if (conn.role == .slow) &loop.slow else &loop.stats;
        if (kind == @backingInt(wire.Kind.presence) and loop.counting) stats.presence += 1;
        if (kind != @backingInt(wire.Kind.ops) or frame.len < wire.header_size + 8) return;
        conn.seq = wire.seqOf(frame);
        const sent = std.mem.readInt(i64, frame[wire.header_size..][0..8], .little);
        if (loop.counting) stats.record(nowNs(loop.io) - sent);
        // Now and then: what it has, so the log can let go of what's before it.
        conn.unpinged += 1;
        if (conn.unpinged >= 200) {
            conn.unpinged = 0;
            var ping: [wire.header_size]u8 = undefined;
            var pw: wire.FrameWriter = .{ .buffer = &ping };
            _ = conn.queue(pw.finish(.ping, conn.seq, 0));
        }
    }

    /// What's due: hosts' changes, guests' pointer updates and slow guests' reads. Then what's queued goes out.
    fn tick(loop: *Loop, now: i64) void {
        const change_ns: i64 = @intCast(std.time.ns_per_s / @max(loop.config.rate, 1));
        const pointer_ns: i64 = @intCast(std.time.ns_per_s / @max(loop.config.presence, 1));
        for (loop.rooms, 0..) |*room, r| {
            const conns = loop.roomConns(r);
            const host = &conns[0];
            if (host.fd < 0) continue;
            if (room.next_ns == 0) room.next_ns = now;
            // A change about the size of a sealed rename: when it was sent, then padding. One that doesn't fit, as
            // the relay's behind on reading, isn't sent.
            while (room.next_ns <= now) : (room.next_ns += change_ns) {
                var body: [96]u8 = @splat(0);
                std.mem.writeInt(i64, body[0..8], now, .little);
                var w = frameWriter();
                w.raw(&body);
                if (!host.queue(w.finish(.ops, room.seq + 1, 0))) continue;
                room.seq += 1;
                if (loop.counting) loop.published += 1;
            }
            for (conns[1..]) |*guest| {
                if (guest.fd < 0) continue;
                if (loop.config.presence > 0 and now >= guest.pointer_ns) {
                    // A pointer moving across the canvas, each update about the size of a sealed one.
                    var buffer: [wire.header_size + 64]u8 = @splat(0);
                    var w: wire.FrameWriter = .{ .buffer = &buffer, .len = buffer.len };
                    if (guest.queue(w.finish(.presence, 0, 0)) and loop.counting) {
                        (if (guest.role == .slow) &loop.slow else &loop.stats).presence_sent += 1;
                    }
                    guest.pointer_ns = @max(guest.pointer_ns + pointer_ns, now - pointer_ns);
                }
                // On a slow connection: 50 messages a second, reading only what it needs, not ahead.
                if (guest.role == .slow and now >= guest.read_ns) {
                    guest.read_ns = now + 20 * std.time.ns_per_ms;
                    if (guest.peek() == null) guest.fill(slow_window) catch {
                        loop.lose(guest);
                        continue;
                    };
                    if (guest.next()) |frame| loop.handle(guest, frame);
                }
            }
        }
        for (loop.conns) |*conn| {
            if (conn.fd >= 0 and conn.out_len > 0) conn.flush() catch loop.lose(conn);
        }
    }

    fn lose(loop: *Loop, conn: *Conn) void {
        if (conn.fd < 0) return;
        conn.close();
        loop.lost += 1;
    }
};

/// The network holds little for a slow guest, so what it's behind on waits at the relay, as it would.
const slow_window = 4096;

/// A WebSocket client's connection: frames out masked (with a zero mask, which changes nothing), frames in whole.
const Conn = struct {
    fd: c.fd_t = -1,
    room: u32,
    role: enum { host, guest, slow },
    /// A guest's last change, and changes since it last said so.
    seq: u64 = 0,
    unpinged: u32 = 0,
    /// When a guest's next pointer update is due, and a slow guest's next read.
    pointer_ns: i64 = 0,
    read_ns: i64 = 0,
    in_start: usize = 0,
    in_len: usize = 0,
    out_len: usize = 0,
    in: [32 * 1024]u8 = undefined,
    out: [16 * 1024]u8 = undefined,

    /// Connects and upgrades to a WebSocket, blocking. A slow guest's small receive buffer is set before connecting,
    /// as the window it offers is fixed then.
    fn connect(conn: *Conn, port: u16) !void {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SystemResources;
        conn.fd = fd;
        const one: c_int = 1;
        // Small messages go at once, as the app's do, not held for the last one's acknowledgement.
        _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &one, @sizeOf(c_int));
        if (builtin.os.tag.isDarwin()) _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        if (conn.role == .slow) {
            const small: c_int = slow_window;
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &small, @sizeOf(c_int));
        }
        if (source_count > 0) {
            const source: c.sockaddr.in = .{ .port = 0, .addr = @bitCast(sources[next_source.fetchAdd(1, .monotonic) % source_count]) };
            if (c.bind(fd, @ptrCast(&source), @sizeOf(c.sockaddr.in)) < 0) return error.AddressNotAvailable;
        }
        var address: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(relay_address) };
        if (c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr.in)) < 0) return error.ConnectionRefused;
        const request = "GET / HTTP/1.1\r\nHost: relay\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
        @memcpy(conn.out[0..request.len], request);
        conn.out_len = request.len;
        try conn.flushAll();
        // Its answer, to the blank line; anything after is the first frames.
        while (std.mem.indexOf(u8, conn.in[0..conn.in_len], "\r\n\r\n") == null) try conn.fill(conn.in.len);
        conn.in_start = std.mem.indexOf(u8, conn.in[0..conn.in_len], "\r\n\r\n").? + 4;
    }

    /// Queues a frame to go out, if there's room.
    fn queue(conn: *Conn, frame: []const u8) bool {
        var head: [14]u8 = undefined;
        head[0] = 0x82;
        var n: usize = 2;
        if (frame.len < 126) {
            head[1] = 0x80 | @as(u8, @intCast(frame.len));
        } else if (frame.len <= 0xffff) {
            head[1] = 0x80 | 126;
            std.mem.writeInt(u16, head[2..4], @intCast(frame.len), .big);
            n = 4;
        } else {
            head[1] = 0x80 | 127;
            std.mem.writeInt(u64, head[2..10], frame.len, .big);
            n = 10;
        }
        @memset(head[n..][0..4], 0);
        n += 4;
        if (conn.out_len + n + frame.len > conn.out.len) return false;
        @memcpy(conn.out[conn.out_len..][0..n], head[0..n]);
        @memcpy(conn.out[conn.out_len + n ..][0..frame.len], frame);
        conn.out_len += n + frame.len;
        return true;
    }

    fn queueSnapshot(conn: *Conn, seq: u64) bool {
        var buffer: [wire.header_size + 2048]u8 = @splat(0);
        var w: wire.FrameWriter = .{ .buffer = &buffer, .len = buffer.len };
        return conn.queue(w.finish(.snapshot, seq, 0));
    }

    /// Sends what it can of what's queued.
    fn flush(conn: *Conn) !void {
        const flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
        const n = c.send(conn.fd, &conn.out, conn.out_len, flags);
        if (n < 0) return if (c.errno(n) == .AGAIN) {} else error.Closed;
        const sent: usize = @intCast(n);
        std.mem.copyForwards(u8, conn.out[0 .. conn.out_len - sent], conn.out[sent..conn.out_len]);
        conn.out_len -= sent;
    }

    /// Sends all that's queued, blocking: while opening.
    fn flushAll(conn: *Conn) !void {
        while (conn.out_len > 0) try conn.flush();
    }

    /// Reads what's there, up to `limit` bytes held.
    fn fill(conn: *Conn, limit: usize) !void {
        if (conn.in_start > 0) {
            std.mem.copyForwards(u8, conn.in[0 .. conn.in_len - conn.in_start], conn.in[conn.in_start..conn.in_len]);
            conn.in_len -= conn.in_start;
            conn.in_start = 0;
        }
        if (conn.in_len >= limit) return;
        const n = c.recv(conn.fd, conn.in[conn.in_len..].ptr, limit - conn.in_len, 0);
        if (n == 0) return error.Closed;
        if (n < 0) return if (c.errno(n) == .AGAIN) {} else error.Closed;
        conn.in_len += @intCast(n);
    }

    /// The next whole frame read, if there is one, and its length with its WebSocket header.
    fn peek(conn: *Conn) ?struct { []u8, usize } {
        const in = conn.in[conn.in_start..conn.in_len];
        if (in.len < 2) return null;
        var head: usize = 2;
        const length: usize = switch (in[1] & 0x7f) {
            126 => if (in.len < 4) return null else blk: {
                head = 4;
                break :blk std.mem.readInt(u16, in[2..4], .big);
            },
            127 => if (in.len < 10) return null else blk: {
                head = 10;
                break :blk @intCast(std.mem.readInt(u64, in[2..10], .big));
            },
            else => |n| n,
        };
        if (in.len < head + length) return null;
        return .{ in[head..][0..length], head + length };
    }

    /// The next whole frame read, good until the next read.
    fn next(conn: *Conn) ?[]u8 {
        const frame, const size = conn.peek() orelse return null;
        conn.in_start += size;
        return frame;
    }

    /// The next frame, blocking: while opening.
    fn receiveBlocking(conn: *Conn) ![]u8 {
        while (true) {
            if (conn.next()) |frame| return frame;
            try conn.fill(conn.in.len);
        }
    }

    fn close(conn: *Conn) void {
        if (conn.fd >= 0) _ = c.close(conn.fd);
        conn.fd = -1;
    }
};

fn nowNs(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

fn frameWriter() wire.FrameWriter {
    const S = struct {
        threadlocal var buffer: [4096]u8 = undefined;
    };
    return .{ .buffer = &S.buffer };
}

/// Reads the welcome's fields.
const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn varint(r: *Reader) u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) : (shift += 7) {
            const b = r.bytes[r.index];
            r.index += 1;
            value |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return value;
        }
    }

    fn blob(r: *Reader) []const u8 {
        const n: usize = @intCast(r.varint());
        defer r.index += n;
        return r.bytes[r.index..][0..n];
    }

    /// A blob, copied: what it's read from is reused.
    fn blobInto(r: *Reader, out: []u8) usize {
        const b = r.blob();
        @memcpy(out[0..b.len], b);
        return b.len;
    }
};
