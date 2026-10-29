//! `zig build load -- [--port 8787] [--rooms 10] [--guests 3] [--rate 20] [--seconds 10]`: a load generator for a
//! relay already running. Each room has a host publishing changes at `rate` a second, each carrying when it was sent,
//! and `guests` guests that read them, pinging now and then so the log can be trimmed. At the end it prints changes
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
    seconds: u64 = 10,
};

/// What every guest saw, added up: changes delivered, and their latencies in 10 µs buckets.
const Stats = struct {
    delivered: std.atomic.Value(u64) = .init(0),
    buckets: [bucket_count]std.atomic.Value(u64) = @splat(.init(0)),
    const bucket_us = 10;
    const bucket_count = 10_000;

    fn record(stats: *Stats, latency_ns: i96) void {
        _ = stats.delivered.fetchAdd(1, .monotonic);
        const bucket: usize = @intCast(@min(@max(@divFloor(latency_ns, bucket_us * 1000), 0), bucket_count - 1));
        _ = stats.buckets[bucket].fetchAdd(1, .monotonic);
    }

    fn percentile(stats: *const Stats, p: f64) f64 {
        const total = stats.delivered.load(.monotonic);
        const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * p));
        var seen: u64 = 0;
        for (&stats.buckets, 0..) |*b, i| {
            seen += b.load(.monotonic);
            if (seen >= target) return @floatFromInt((i + 1) * bucket_us);
        }
        return @floatFromInt(bucket_count * bucket_us);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var config: Config = .{};
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        const value = std.fmt.parseInt(u64, args.next() orelse return error.Usage, 10) catch return error.Usage;
        if (std.mem.eql(u8, arg, "--port")) config.port = @intCast(value) else if (std.mem.eql(u8, arg, "--rooms")) config.rooms = value else if (std.mem.eql(u8, arg, "--guests")) config.guests = value else if (std.mem.eql(u8, arg, "--rate")) config.rate = value else if (std.mem.eql(u8, arg, "--seconds")) config.seconds = value else return error.Usage;
    }

    var stats: Stats = .{};
    var published: std.atomic.Value(u64) = .init(0);
    var tasks: Io.Group = .init;
    // Started a millisecond apart, as people arrive, not all in one burst at the listen queue.
    const warmup_ms: i64 = @intCast(1000 + config.rooms);
    const deadline = nowNs(io) + (@as(i96, warmup_ms) + @as(i96, config.seconds) * 1000) * std.time.ns_per_ms;
    for (0..config.rooms) |_| {
        try tasks.concurrent(io, room, .{ io, config, &stats, &published, deadline });
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try io.sleep(.fromMilliseconds(1000), .awake);
    // Counted from when every room's had time to start.
    for (&stats.buckets) |*b| b.store(0, .monotonic);
    stats.delivered.store(0, .monotonic);
    const published_at_start = published.load(.monotonic);
    try io.sleep(.fromSeconds(@intCast(config.seconds)), .awake);
    const delivered = stats.delivered.load(.monotonic);
    const sent = published.load(.monotonic) - published_at_start;
    tasks.cancel(io);

    const seconds: f64 = @floatFromInt(config.seconds);
    std.debug.print(
        \\rooms {d}, guests each {d}, {d} changes/s each: {d} connections
        \\published {d:.0} changes/s, delivered {d:.0}/s ({d:.0}% of {d})
        \\latency, send to receive: p50 {d:.0} µs, p99 {d:.0} µs, p99.9 {d:.0} µs
        \\
    , .{
        config.rooms,                                                                                      config.guests,
        config.rate,                                                                                       config.rooms * (config.guests + 1),
        @as(f64, @floatFromInt(sent)) / seconds,                                                           @as(f64, @floatFromInt(delivered)) / seconds,
        100 * @as(f64, @floatFromInt(delivered)) / @as(f64, @floatFromInt(@max(sent * config.guests, 1))), sent * config.guests,
        stats.percentile(0.5),                                                                             stats.percentile(0.99),
        stats.percentile(0.999),
    });
}

/// One room: its host, publishing until `deadline`, and its guests.
fn room(io: Io, config: Config, stats: *Stats, published: *std.atomic.Value(u64), deadline: i96) Io.Cancelable!void {
    var host: Socket = undefined;
    host.open(io, config.port) catch return;
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
        guests.concurrent(io, guest, .{ io, config.port, id_buffer[0..room_id.len], secret_buffer[0..guest_secret.len], i, stats }) catch return;
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

fn guest(io: Io, port: u16, room_id: []const u8, secret: []const u8, index: usize, stats: *Stats) Io.Cancelable!void {
    var socket: Socket = undefined;
    socket.open(io, port) catch return;
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
    var seq: u64 = 0;
    var unpinged: usize = 0;
    while (true) {
        try io.checkCancel();
        const frame = socket.receive() catch return;
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
            socket.send(pw.finish(.ping, seq, 0)) catch return;
        }
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
    fn open(socket: *Socket, io: Io, port: u16) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", port);
        socket.* = .{ .io = io, .stream = try address.connect(io, .{ .mode = .stream }) };
        socket.reader = socket.stream.reader(io, &socket.read_buffer);
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
