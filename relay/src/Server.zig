//! The relay on the network: WebSocket connections in, `Relay` in the middle.
//!
//! Each connection has two tasks. Its reader reads whole messages and hands each to the relay. Its writer sends what
//! the relay has queued for it. The relay runs one call at a time, under `mutex`, and its sends only append to the
//! connection's outbox, so a slow connection never holds up anyone else. A connection whose outbox fills is too far
//! behind: it's closed, and when it comes back the relay catches it up from the snapshot.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const WebSocket = std.http.Server.WebSocket;
const Relay = @import("Relay.zig");
const wire = @import("wire.zig");

const Server = @This();
const log = std.log.scoped(.server);

io: Io,
gpa: Allocator,
limits: wire.Limits,
/// Guards the relay, and every connection's outbox and state.
mutex: Io.Mutex = .init,
relay: Relay,
csprng: std.Random.DefaultCsprng,
next_id: u64 = 1,
/// The network's side of the metrics, counted under the mutex.
counts: Counts = .{},
/// When it started, in seconds since 1970, for monitoring.
started: i64 = 0,

const Counts = struct {
    connections_open: u64 = 0,
    connections: u64 = 0,
    frames_in: u64 = 0,
    bytes_in: u64 = 0,
    frames_out: u64 = 0,
    bytes_out: u64 = 0,
    /// Connections closed for falling too far behind to queue for.
    lagging: u64 = 0,
};

/// Lets go of silent connections, and ends rooms whose host has gone, this often.
const tick_interval: Io.Duration = .fromSeconds(1);

pub fn init(server: *Server, io: Io, gpa: Allocator, config: Relay.Config) !void {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    server.* = .{
        .io = io,
        .gpa = gpa,
        .limits = config.limits,
        .csprng = .init(seed),
        .relay = undefined,
        .started = @divFloor(Io.Clock.real.now(io).toMilliseconds(), 1000),
    };
    server.relay = .init(gpa, server.csprng.random(), .{ .ptr = server, .vtable = &.{ .send = send, .close = close } }, config);
}

pub fn deinit(server: *Server) void {
    server.relay.deinit();
}

/// Accepts connections until the listener fails or the task's canceled.
pub fn serve(server: *Server, listener: *Io.net.Server) !void {
    const io = server.io;
    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, ticker, .{server});
    while (true) {
        const stream = try listener.accept(io);
        tasks.concurrent(io, connection, .{ server, stream }) catch {
            stream.close(io);
            log.warn("turned a connection away: no thread for it", .{});
        };
    }
}

// Metrics

/// Answers Prometheus's scrapes of `/metrics` on `listener`, one at a time, until it fails or the task's canceled.
pub fn serveMetrics(server: *Server, listener: *Io.net.Server) Io.Cancelable!void {
    const io = server.io;
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        defer stream.close(io);
        server.answerScrape(stream) catch {};
    }
}

fn answerScrape(server: *Server, stream: Io.net.Stream) !void {
    const io = server.io;
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try http.receiveHead();
    if (!std.mem.eql(u8, request.head.target, "/metrics")) return request.respond("Not found.\n", .{ .status = .not_found });
    var body_buffer: [16 * 1024]u8 = undefined;
    var body: Io.Writer = .fixed(&body_buffer);
    {
        try server.mutex.lock(io);
        defer server.mutex.unlock(io);
        try writeMetrics(&body, &server.relay, server.counts, server.started);
    }
    try request.respond(body.buffered(), .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
    } });
}

/// The metrics, in Prometheus's text format.
fn writeMetrics(w: *Io.Writer, relay: *const Relay, counts: Counts, started: i64) Io.Writer.Error!void {
    const g = relay.gauges();
    const m = relay.metrics;
    const Metric = struct { name: []const u8, kind: []const u8, help: []const u8, value: u64 };
    const metrics = [_]Metric{
        .{ .name = "rooms", .kind = "gauge", .help = "Rooms open.", .value = g.rooms },
        .{ .name = "peers", .kind = "gauge", .help = "Hosts and guests connected to rooms.", .value = g.peers },
        .{ .name = "lobby", .kind = "gauge", .help = "Connections that haven't said hello yet.", .value = g.lobby },
        .{ .name = "log_bytes", .kind = "gauge", .help = "Bytes of frames held in rooms' logs.", .value = g.log_bytes },
        .{ .name = "connections", .kind = "gauge", .help = "WebSocket connections open.", .value = counts.connections_open },
        .{ .name = "connections_total", .kind = "counter", .help = "WebSocket connections accepted.", .value = counts.connections },
        .{ .name = "lagging_total", .kind = "counter", .help = "Connections closed for falling too far behind.", .value = counts.lagging },
        .{ .name = "frames_received_total", .kind = "counter", .help = "Frames received.", .value = counts.frames_in },
        .{ .name = "bytes_received_total", .kind = "counter", .help = "Bytes of frames received.", .value = counts.bytes_in },
        .{ .name = "frames_sent_total", .kind = "counter", .help = "Frames sent.", .value = counts.frames_out },
        .{ .name = "bytes_sent_total", .kind = "counter", .help = "Bytes of frames sent.", .value = counts.bytes_out },
        .{ .name = "rooms_made_total", .kind = "counter", .help = "Rooms made.", .value = m.rooms_made },
        .{ .name = "rooms_ended_total", .kind = "counter", .help = "Rooms ended.", .value = m.rooms_ended },
        .{ .name = "joins_total", .kind = "counter", .help = "Guests let into rooms.", .value = m.joins },
        .{ .name = "decisions_total", .kind = "counter", .help = "Hosts' decisions taken into logs.", .value = m.decisions },
        .{ .name = "changes_total", .kind = "counter", .help = "Guests' changes passed to hosts.", .value = m.changes },
        .{ .name = "snapshots_total", .kind = "counter", .help = "Snapshots received from hosts.", .value = m.snapshots },
        .{ .name = "snapshot_requests_total", .kind = "counter", .help = "Snapshots asked of hosts.", .value = m.snapshot_requests },
        .{ .name = "start_time_seconds", .kind = "gauge", .help = "When the relay started, in seconds since 1970.", .value = @intCast(started) },
    };
    for (metrics) |metric| {
        try w.print("# HELP joinery_relay_{s} {s}\n# TYPE joinery_relay_{s} {s}\njoinery_relay_{s} {d}\n", .{
            metric.name, metric.help, metric.name, metric.kind, metric.name, metric.value,
        });
    }
    try w.writeAll("# HELP joinery_relay_dropped_total Connections let go of or turned away, by why.\n" ++
        "# TYPE joinery_relay_dropped_total counter\n");
    for (m.drops[0..m.reasons]) |r| {
        try w.writeAll("joinery_relay_dropped_total{reason=\"");
        // Label values escape backslashes, quotes and newlines.
        for (r.why) |c| switch (c) {
            '\\', '"' => try w.print("\\{c}", .{c}),
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(c),
        };
        try w.print("\"}} {d}\n", .{r.count});
    }
}

test "metrics are in Prometheus's format" {
    var prng: std.Random.DefaultPrng = .init(1);
    const Discard = struct {
        fn send(_: *anyopaque, _: *Relay.Link, _: []const u8) void {}
        fn close(_: *anyopaque, _: *Relay.Link) void {}
    };
    var ignored: u8 = 0;
    var relay: Relay = .init(std.testing.allocator, prng.random(), .{ .ptr = &ignored, .vtable = &.{ .send = Discard.send, .close = Discard.close } }, .{});
    defer relay.deinit();
    var link: Relay.Link = .{ .id = 1 };
    relay.opened(&link, 0);
    var frame: [24]u8 = @splat(0);
    frame[0] = wire.version;
    frame[1] = @backingInt(wire.Kind.ping);
    relay.received(&link, &frame, 0); // Not a hello: dropped.

    var buffer: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeMetrics(&w, &relay, .{ .connections_open = 2 }, 1700000000);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE joinery_relay_rooms gauge\njoinery_relay_rooms 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "joinery_relay_connections 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "joinery_relay_dropped_total{reason=\"something other than hello first\"} 1\n") != null);
}

fn now(server: *const Server) i64 {
    return Io.Clock.boot.now(server.io).toMilliseconds();
}

fn ticker(server: *Server) Io.Cancelable!void {
    const io = server.io;
    while (true) {
        try io.sleep(tick_interval, .boot);
        try server.mutex.lock(io);
        defer server.mutex.unlock(io);
        server.relay.tick(server.now());
    }
}

// Connections

const Connection = struct {
    link: Relay.Link,
    stream: Io.net.Stream,
    /// What the relay's queued to send, as WebSocket messages, and what the writer's sending: swapped when it starts.
    outbox: []u8,
    outbox_len: usize = 0,
    sending: []u8,
    /// Signaled when there's something to send, or the state changes.
    ready: Io.Condition = .init,
    state: enum {
        open,
        /// The relay's closed it: the writer sends what's left, then shuts the connection.
        closing,
        /// Too far behind: what's queued is dropped, and the connection shut, so the reader ends and tells the relay.
        lagging,
        /// The reader's ended: nothing more to send.
        gone,
    } = .open,
};

/// The most a connection can have queued: a joiner's catch-up, the snapshot and the whole log, with each frame's
/// WebSocket header. The memory's only touched as it's used.
fn outboxSize(limits: wire.Limits) usize {
    // ponytail: twice what the frames take covers the headers of the smallest frames; per-frame cursors into the log
    // would make this zero, as docs/relay.md has it.
    return 2 * (@as(usize, limits.max_snapshot) + limits.log_bytes);
}

fn connection(server: *Server, stream: Io.net.Stream) Io.Cancelable!void {
    const io = server.io;
    defer stream.close(io);
    const pages = std.heap.page_allocator;
    // The largest message, the snapshot, with its WebSocket header.
    const read_buffer = Relay.reserve(pages, server.limits.max_snapshot + 14) catch return;
    defer Relay.release(pages, read_buffer);
    const outbox = Relay.reserve(pages, 2 * outboxSize(server.limits)) catch return;
    defer Relay.release(pages, outbox);

    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var ws = upgrade(&http) catch return;

    var conn: Connection = .{
        .link = undefined,
        .stream = stream,
        .outbox = outbox[0 .. outbox.len / 2],
        .sending = outbox[outbox.len / 2 ..],
    };
    {
        try server.mutex.lock(io);
        defer server.mutex.unlock(io);
        conn.link = .{ .id = server.next_id };
        server.next_id += 1;
        server.counts.connections += 1;
        server.counts.connections_open += 1;
        server.relay.opened(&conn.link, server.now());
    }
    var sender = io.concurrent(write, .{ server, &conn, &writer.interface }) catch null;
    if (sender != null) server.read(&conn, &ws) catch {};

    // Done reading: the relay's told, unless it's the one that closed it, in which case the writer finishes.
    server.mutex.lockUncancelable(io);
    server.counts.connections_open -= 1;
    switch (conn.state) {
        .open, .lagging => {
            server.relay.closed(&conn.link, server.now());
            conn.state = .gone;
        },
        .closing, .gone => {},
    }
    conn.ready.signal(io);
    server.mutex.unlock(io);
    if (sender) |*s| s.await(io);
}

/// The reader: hands each message to the relay, until the connection ends or the relay closes it.
fn read(server: *Server, conn: *Connection, ws: *WebSocket) !void {
    const io = server.io;
    while (true) {
        const message = try ws.readSmallMessage();
        if (message.opcode != .binary) continue;
        try server.mutex.lock(io);
        defer server.mutex.unlock(io);
        if (conn.state != .open) return;
        server.counts.frames_in += 1;
        server.counts.bytes_in += message.data.len;
        server.relay.received(&conn.link, message.data, server.now());
    }
}

/// Answers the HTTP request a connection starts with, which must be for a WebSocket. A link opened in a browser is told
/// where it goes.
fn upgrade(http: *std.http.Server) !WebSocket {
    var request = try http.receiveHead();
    switch (request.upgradeRequested()) {
        .websocket => |key| if (key) |k| {
            var ws = try request.respondWebSocket(.{ .key = k });
            try ws.flush();
            return ws;
        },
        .other, .none => {},
    }
    const share_link = std.mem.startsWith(u8, request.head.target, "/r/");
    try request.respond(if (share_link)
        "This is a Joinery share link. Copy it, and paste it into Join in Joinery's library.\n"
    else
        "This is a Joinery relay. Share from Joinery to use it.\n", .{ .status = if (share_link) .ok else .not_found });
    return error.NotWebSocket;
}

/// The writer: sends whatever's queued, until the connection's done.
fn write(server: *Server, conn: *Connection, out: *Io.Writer) void {
    const io = server.io;
    server.mutex.lockUncancelable(io);
    while (true) {
        while (conn.outbox_len == 0 and conn.state == .open) conn.ready.waitUncancelable(io, &server.mutex);
        if (conn.outbox_len == 0 or conn.state == .lagging or conn.state == .gone) break;
        std.mem.swap([]u8, &conn.outbox, &conn.sending);
        const n = conn.outbox_len;
        conn.outbox_len = 0;
        server.mutex.unlock(io);
        const sent = if (out.writeAll(conn.sending[0..n])) out.flush() else |err| err;
        server.mutex.lockUncancelable(io);
        sent catch break;
    }
    server.mutex.unlock(io);
    // Ends the reader too, if it's still reading.
    conn.stream.shutdown(io, .both) catch {};
}

// What the relay does, under the mutex.

fn send(ptr: *anyopaque, link: *Relay.Link, frame: []const u8) void {
    const server: *Server = @ptrCast(@alignCast(ptr));
    const conn: *Connection = @fieldParentPtr("link", link);
    if (conn.state != .open) return;
    var header: [10]u8 = undefined;
    const head = webSocketHeader(&header, frame.len);
    if (conn.outbox_len + head.len + frame.len > conn.outbox.len) {
        log.info("connection {d} dropped: its outbox is full, so it's too far behind", .{link.id});
        server.counts.lagging += 1;
        conn.state = .lagging;
        conn.ready.signal(server.io);
        return;
    }
    @memcpy(conn.outbox[conn.outbox_len..][0..head.len], head);
    @memcpy(conn.outbox[conn.outbox_len + head.len ..][0..frame.len], frame);
    conn.outbox_len += head.len + frame.len;
    server.counts.frames_out += 1;
    server.counts.bytes_out += frame.len;
    conn.ready.signal(server.io);
}

fn close(ptr: *anyopaque, link: *Relay.Link) void {
    const server: *Server = @ptrCast(@alignCast(ptr));
    const conn: *Connection = @fieldParentPtr("link", link);
    if (conn.state == .open) conn.state = .closing;
    conn.ready.signal(server.io);
}

/// A final, unmasked binary message's header, as a server sends it.
fn webSocketHeader(buffer: *[10]u8, length: usize) []const u8 {
    buffer[0] = 0x82;
    if (length < 126) {
        buffer[1] = @intCast(length);
        return buffer[0..2];
    } else if (length <= 0xffff) {
        buffer[1] = 126;
        std.mem.writeInt(u16, buffer[2..4], @intCast(length), .big);
        return buffer[0..4];
    }
    buffer[1] = 127;
    std.mem.writeInt(u64, buffer[2..10], length, .big);
    return buffer[0..10];
}

test "WebSocket headers" {
    var buffer: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0 }, webSocketHeader(&buffer, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 125 }, webSocketHeader(&buffer, 125));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0, 126 }, webSocketHeader(&buffer, 126));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0xff, 0xff }, webSocketHeader(&buffer, 0xffff));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0 }, webSocketHeader(&buffer, 0x10000));
}
