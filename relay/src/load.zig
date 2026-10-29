//! `zig build load -- [--port 8787] [--rooms 10] [--guests 3] [--rate 20] [--presence 0] [--seconds 10]`: a load
//! generator for a relay already running. Each room has a host publishing changes at `rate` a second, each carrying
//! when it was sent, and `guests` guests that read them, pinging now and then so the log can be trimmed, and each
//! sending `presence` pointer updates a second, as a moving pointer does. At the end it prints changes
//! delivered a second and the time from the host's send to a guest's receive. Everything's on this machine, so the
//! times are the relay's, the kernel's and this program's, with no network.

const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");

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
};

/// What every guest saw, added up: changes delivered, and their latencies in buckets an eighth of a doubling wide
/// (9% apart), from a microsecond to over an hour.
const Stats = struct {
    delivered: std.atomic.Value(u64) = .init(0),
    presence: std.atomic.Value(u64) = .init(0),
    /// Pointer updates sent, each due to everyone else in the room.
    presence_sent: std.atomic.Value(u64) = .init(0),
    buckets: [bucket_count]std.atomic.Value(u64) = @splat(.init(0)),
    const per_doubling = 8;
    const bucket_count = 32 * per_doubling;

    fn record(stats: *Stats, latency_ns: i96) void {
        _ = stats.delivered.fetchAdd(1, .monotonic);
        const us: f64 = @max(@as(f64, @floatFromInt(latency_ns)) / 1000, 1);
        const bucket: usize = @intFromFloat(@min(@log2(us) * per_doubling, bucket_count - 1));
        _ = stats.buckets[bucket].fetchAdd(1, .monotonic);
    }

    /// The `p` quantile's latency, in µs: the top of its bucket.
    fn percentile(stats: *const Stats, p: f64) f64 {
        const total = stats.delivered.load(.monotonic);
        if (total == 0) return 0;
        const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * p));
        var seen: u64 = 0;
        for (&stats.buckets, 0..) |*b, i| {
            seen += b.load(.monotonic);
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
        const value = std.fmt.parseInt(u64, args.next() orelse return error.Usage, 10) catch return error.Usage;
        // Each flag sets the field it names: --rooms 10 sets rooms.
        const name = if (std.mem.startsWith(u8, arg, "--")) arg[2..] else return error.Usage;
        inline for (@typeInfo(Config).@"struct".field_names) |field| {
            if (std.mem.eql(u8, name, field)) {
                @field(config, field) = @intCast(value);
                break;
            }
        } else return error.Usage;
    }

    var stats: Stats = .{};
    var slow_stats: Stats = .{};
    var published: std.atomic.Value(u64) = .init(0);
    var tasks: Io.Group = .init;
    // Started a millisecond apart, as people arrive, not all in one burst at the listen queue.
    const warmup_ms: i64 = @intCast(1000 + config.rooms);
    const deadline = nowNs(io) + (@as(i96, warmup_ms) + @as(i96, config.seconds) * 1000) * std.time.ns_per_ms;
    for (0..config.rooms) |_| {
        try tasks.concurrent(io, room, .{ io, config, &stats, &slow_stats, &published, deadline });
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try io.sleep(.fromMilliseconds(1000), .awake);
    // Counted from when every room's had time to start.
    for (&stats.buckets) |*b| b.store(0, .monotonic);
    stats.delivered.store(0, .monotonic);
    stats.presence.store(0, .monotonic);
    stats.presence_sent.store(0, .monotonic);
    slow_stats = .{};
    const published_at_start = published.load(.monotonic);
    try io.sleep(.fromSeconds(@intCast(config.seconds)), .awake);
    const delivered = stats.delivered.load(.monotonic);
    const presence = stats.presence.load(.monotonic);
    // Only guests count what they're sent: each update is due to the other guests (the host gets it too, uncounted).
    const presence_due = stats.presence_sent.load(.monotonic) * (config.guests -| 1);
    const sent = published.load(.monotonic) - published_at_start;
    tasks.cancel(io);

    const seconds: f64 = @floatFromInt(config.seconds);
    std.debug.print(
        \\rooms {d}, guests each {d}, {d} changes/s each: {d} connections
        \\published {d:.0} changes/s, delivered {d:.0}/s ({d:.0}% of {d})
        \\latency, send to receive: p50 {d:.0} µs, p99 {d:.0} µs, p99.9 {d:.0} µs
        \\pointer updates delivered {d:.0}/s ({d:.0}% of {d} due)
        \\
    , .{
        config.rooms,                                                                                                      config.guests,
        config.rate,                                                                                                       config.rooms * (config.guests + 1),
        @as(f64, @floatFromInt(sent)) / seconds,                                                                           @as(f64, @floatFromInt(delivered)) / seconds,
        100 * @as(f64, @floatFromInt(delivered)) / @as(f64, @floatFromInt(@max(sent * (config.guests - config.slow), 1))), sent * (config.guests - config.slow),
        stats.percentile(0.5),                                                                                             stats.percentile(0.99),
        stats.percentile(0.999),                                                                                           @as(f64, @floatFromInt(presence)) / seconds,
        100 * @as(f64, @floatFromInt(presence)) / @as(f64, @floatFromInt(@max(presence_due, 1))),                          presence_due,
    });
    if (config.slow > 0) std.debug.print("slow guests: changes delivered {d:.0}/s, p50 {d:.0} µs, p99 {d:.0} µs, pointer updates {d:.0}/s\n", .{
        @as(f64, @floatFromInt(slow_stats.delivered.load(.monotonic))) / seconds, slow_stats.percentile(0.5),
        slow_stats.percentile(0.99),                                              @as(f64, @floatFromInt(slow_stats.presence.load(.monotonic))) / seconds,
    });
}

/// One room: its host, publishing until `deadline`, and its guests.
fn room(io: Io, config: Config, stats: *Stats, slow: *Stats, published: *std.atomic.Value(u64), deadline: i96) Io.Cancelable!void {
    var host: Socket = undefined;
    host.open(io, config.port, false) catch return;
    defer host.close();
    var w = frameWriter();
    w.byte(@backingInt(wire.Role.host));
    for (0..3) |_| w.blob("");
    w.varint(0);
    w.varint(wire.room_version);
    w.blob("Load");
    w.blob("Load");
    host.send(w.finish(.hello, 0, 0)) catch return;
    var seq: u64 = 0;
    host.sendSnapshot(seq) catch return;
    // The welcome: the room, and the guests' secret.
    const welcome = host.receive() catch return;
    var r: Reader = .{ .bytes = welcome[wire.header_size..] };
    _ = r.varint();
    const room_id = r.blob();
    _ = r.blob();
    const guest_secret = r.blob();
    var id_buffer: [32]u8 = undefined;
    var secret_buffer: [32]u8 = undefined;
    @memcpy(id_buffer[0..room_id.len], room_id);
    @memcpy(secret_buffer[0..guest_secret.len], guest_secret);

    var guests: Io.Group = .init;
    defer guests.cancel(io);
    for (0..config.guests) |i| {
        guests.concurrent(io, guest, .{ io, config, id_buffer[0..room_id.len], secret_buffer[0..guest_secret.len], i, if (i < config.slow) slow else stats }) catch return;
    }
    // Snapshot requests, answered by the host's reader, which shares its writer with publishing.
    var writing: Io.Mutex = .init;
    var reader = io.concurrent(hostReader, .{ io, &host, &writing, &seq }) catch return;
    defer reader.cancel(io) catch {};

    const interval_ns: i96 = @divFloor(std.time.ns_per_s, @as(i96, config.rate));
    var next = nowNs(io);
    while (true) {
        const now = nowNs(io);
        if (now >= deadline) return;
        if (now < next) {
            try io.sleep(.fromNanoseconds(@min(next - now, std.time.ns_per_ms)), .awake);
            continue;
        }
        next += interval_ns;
        try writing.lock(io);
        defer writing.unlock(io);
        seq += 1;
        // A change about the size of a sealed rename: when it was sent, then padding.
        var body: [96]u8 = @splat(0);
        std.mem.writeInt(i96, body[0..12], nowNs(io), .little);
        w = frameWriter();
        w.raw(&body);
        host.send(w.finish(.ops, seq, 0)) catch return;
        _ = published.fetchAdd(1, .monotonic);
    }
}

fn hostReader(io: Io, host: *Socket, writing: *Io.Mutex, seq: *u64) Io.Cancelable!void {
    while (true) {
        const frame = host.receive() catch return;
        if (frame[1] != @backingInt(wire.Kind.snapshot_request)) continue;
        try writing.lock(io);
        defer writing.unlock(io);
        host.sendSnapshot(seq.*) catch return;
    }
}

fn guest(io: Io, config: Config, room_id: []const u8, secret: []const u8, index: usize, stats: *Stats) Io.Cancelable!void {
    var socket: Socket = undefined;
    // A slow connection: the network holds little, so what it's behind on waits at the relay, as it would.
    socket.open(io, config.port, index < config.slow) catch return;
    defer socket.close();
    var client: [16]u8 = undefined;
    var w = frameWriter();
    w.byte(@backingInt(wire.Role.guest));
    w.blob(room_id);
    w.blob(secret);
    w.blob(std.fmt.bufPrint(&client, "load-{d}", .{index}) catch unreachable);
    w.varint(0);
    w.varint(wire.room_version);
    w.blob("Guest");
    w.blob("");
    socket.send(w.finish(.hello, 0, 0)) catch return;
    // Pointer updates, from a task of their own, sharing the socket's writing with pings.
    var writing: Io.Mutex = .init;
    var pointer: ?Io.Future(Io.Cancelable!void) = if (config.presence > 0)
        io.concurrent(movePointer, .{ io, &socket, &writing, config.presence, stats }) catch return
    else
        null;
    defer if (pointer) |*f| f.cancel(io) catch {};
    var seq: u64 = 0;
    var unpinged: usize = 0;
    while (true) {
        try io.checkCancel();
        const frame = socket.receive() catch return;
        // On a slow connection: 50 messages a second.
        if (index < config.slow) try io.sleep(.fromMilliseconds(20), .awake);
        if (frame[1] == @backingInt(wire.Kind.presence)) _ = stats.presence.fetchAdd(1, .monotonic);
        if (frame[1] != @backingInt(wire.Kind.ops)) continue;
        seq = wire.seqOf(frame);
        const sent = std.mem.readInt(i96, frame[wire.header_size..][0..12], .little);
        stats.record(nowNs(io) - sent);
        // Now and then: what it has, so the log can let go of what's before it.
        unpinged += 1;
        if (unpinged >= 200) {
            unpinged = 0;
            var ping: [wire.header_size]u8 = undefined;
            var pw: wire.FrameWriter = .{ .buffer = &ping };
            try writing.lock(io);
            defer writing.unlock(io);
            socket.send(pw.finish(.ping, seq, 0)) catch return;
        }
    }
}

/// A pointer moving across the canvas: `rate` updates a second, each about the size of a sealed one.
fn movePointer(io: Io, socket: *Socket, writing: *Io.Mutex, rate: u64, stats: *Stats) Io.Cancelable!void {
    var buffer: [wire.header_size + 64]u8 = @splat(0);
    while (true) {
        try io.sleep(.fromNanoseconds(@divFloor(std.time.ns_per_s, rate)), .awake);
        try writing.lock(io);
        defer writing.unlock(io);
        var w: wire.FrameWriter = .{ .buffer = &buffer, .len = buffer.len };
        socket.send(w.finish(.presence, 0, 0)) catch return;
        _ = stats.presence_sent.fetchAdd(1, .monotonic);
    }
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn frameWriter() wire.FrameWriter {
    const S = struct {
        threadlocal var buffer: [4096]u8 = undefined;
    };
    return .{ .buffer = &S.buffer };
}

/// A WebSocket client: frames out masked (with a zero mask, which changes nothing), frames in whole.
const Socket = struct {
    io: Io,
    stream: Io.net.Stream,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [16 * 1024]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    upgraded: bool = false,

    /// Connects, in place: its reader and writer point into it.
    /// Connects, in place: its reader and writer point into it. A slow one has a small receive buffer, set before
    /// connecting, as the window it offers is fixed then, and reads only what it needs, not ahead.
    fn open(socket: *Socket, io: Io, port: u16, slow: bool) !void {
        const c = std.c;
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SystemResources;
        errdefer _ = c.close(fd);
        if (slow) {
            const small: c_int = 4096;
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &small, @sizeOf(c_int));
        }
        var address: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        if (c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr.in)) < 0) return error.ConnectionRefused;
        socket.* = .{ .io = io, .stream = .{ .socket = .{ .handle = fd, .address = try Io.net.IpAddress.parse("127.0.0.1", port) } } };
        socket.reader = socket.stream.reader(io, if (slow) socket.read_buffer[0..4096] else &socket.read_buffer);
        socket.writer = socket.stream.writer(io, &socket.write_buffer);
    }

    fn upgrade(socket: *Socket) !void {
        try socket.writer.interface.writeAll("GET / HTTP/1.1\r\nHost: relay\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
        try socket.writer.interface.flush();
        // Its answer, to the blank line.
        var matched: usize = 0;
        while (matched < 4) {
            const c = try socket.reader.interface.takeByte();
            matched = if (c == "\r\n\r\n"[matched]) matched + 1 else @intFromBool(c == '\r');
        }
    }

    fn send(socket: *Socket, frame: []const u8) !void {
        if (!socket.upgraded) {
            try socket.upgrade();
            socket.upgraded = true;
        }
        const out = &socket.writer.interface;
        try out.writeByte(0x82);
        if (frame.len < 126) {
            try out.writeByte(0x80 | @as(u8, @intCast(frame.len)));
        } else if (frame.len <= 0xffff) {
            try out.writeByte(0x80 | 126);
            try out.writeInt(u16, @intCast(frame.len), .big);
        } else {
            try out.writeByte(0x80 | 127);
            try out.writeInt(u64, frame.len, .big);
        }
        try out.writeAll(&.{ 0, 0, 0, 0 });
        try out.writeAll(frame);
        try out.flush();
    }

    fn sendSnapshot(socket: *Socket, seq: u64) !void {
        var buffer: [wire.header_size + 2048]u8 = @splat(0);
        var w: wire.FrameWriter = .{ .buffer = &buffer, .len = buffer.len };
        try socket.send(w.finish(.snapshot, seq, 0));
    }

    /// The next whole frame, good until the next call.
    fn receive(socket: *Socket) ![]u8 {
        const in = &socket.reader.interface;
        const head = try in.takeArray(2);
        const length: usize = switch (head[1] & 0x7f) {
            126 => try in.takeInt(u16, .big),
            127 => @intCast(try in.takeInt(u64, .big)),
            else => |n| n,
        };
        return in.take(length);
    }

    fn close(socket: *Socket) void {
        socket.stream.close(socket.io);
    }
};

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
};
