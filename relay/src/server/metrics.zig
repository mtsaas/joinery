//! What the relay counts, and how it's shown to Prometheus. Each loop counts its own, publishes a copy once a tick,
//! and the loop answering a scrape adds them up.

const std = @import("std");
const Io = std.Io;
const Relay = @import("../relay/Relay.zig");
const wire = @import("../relay/wire.zig");

/// The network's side of the metrics: the relay keeps its own.
pub const Counts = struct {
    connections_open: u64 = 0,
    connections: u64 = 0,
    frames_in: u64 = 0,
    bytes_in: u64 = 0,
    frames_out: u64 = 0,
    bytes_out: u64 = 0,
    /// Connections closed for falling too far behind to queue for.
    lagging: u64 = 0,
    /// Pointer updates a connection was behind on, replaced by newer ones from the same person before they went.
    pointers_replaced: u64 = 0,
    /// Times a loop fell behind and held its hosts back, and how many it's holding back now.
    hold_backs: u64 = 0,
    hosts_held_back: u64 = 0,
};

/// A loop's metrics, as it last published them.
pub const Published = struct {
    counts: Counts = .{},
    metrics: Relay.Metrics = .{},
    gauges: Relay.Gauges = .{ .rooms = 0, .peers = 0, .lobby = 0, .log_bytes = 0 },

    /// Adds `other`'s to these.
    pub fn add(total: *Published, other: Published) void {
        inline for (@typeInfo(Counts).@"struct".field_names) |name| @field(total.counts, name) += @field(other.counts, name);
        inline for (@typeInfo(Relay.Gauges).@"struct".field_names) |name| @field(total.gauges, name) += @field(other.gauges, name);
        inline for (@typeInfo(Relay.Metrics).@"struct".field_names) |name| {
            if (@TypeOf(@field(total.metrics, name)) == u64) @field(total.metrics, name) += @field(other.metrics, name);
        }
        for (other.metrics.drops[0..other.metrics.reasons]) |reason| total.metrics.droppedBy(reason.why, reason.count);
    }
};

/// The metrics, in Prometheus's text format.
pub fn write(w: *Io.Writer, total: Published, loops: usize, started: i64) Io.Writer.Error!void {
    const g = total.gauges;
    const m = total.metrics;
    const counts = total.counts;
    const Metric = struct { name: []const u8, kind: []const u8, help: []const u8, value: u64 };
    const metrics = [_]Metric{
        .{ .name = "rooms", .kind = "gauge", .help = "Rooms open.", .value = g.rooms },
        .{ .name = "peers", .kind = "gauge", .help = "Hosts and guests connected to rooms.", .value = g.peers },
        .{ .name = "lobby", .kind = "gauge", .help = "Connections that haven't said hello yet.", .value = g.lobby },
        .{ .name = "log_bytes", .kind = "gauge", .help = "Bytes of frames held in rooms' logs.", .value = g.log_bytes },
        .{ .name = "connections", .kind = "gauge", .help = "WebSocket connections open.", .value = counts.connections_open },
        .{ .name = "connections_total", .kind = "counter", .help = "WebSocket connections accepted.", .value = counts.connections },
        .{ .name = "lagging_total", .kind = "counter", .help = "Connections closed for falling too far behind.", .value = counts.lagging },
        .{ .name = "hold_backs_total", .kind = "counter", .help = "Times a loop fell behind and held its rooms' hosts back.", .value = counts.hold_backs },
        .{ .name = "hosts_held_back", .kind = "gauge", .help = "Hosts not being read while their loop catches up.", .value = counts.hosts_held_back },
        .{ .name = "pointers_replaced_total", .kind = "counter", .help = "Pointer updates replaced by newer ones before a connection that was behind was sent them.", .value = counts.pointers_replaced },
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
        .{ .name = "loops", .kind = "gauge", .help = "Event loops, one to a thread, each with its own rooms.", .value = loops },
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
        for (r.why) |char| switch (char) {
            '\\', '"' => try w.print("\\{c}", .{char}),
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(char),
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

    // Two loops' worth: one with the drop, one with two connections.
    var total: Published = .{};
    total.add(.{ .metrics = relay.metrics, .gauges = relay.gauges() });
    total.add(.{ .counts = .{ .connections_open = 2 }, .metrics = relay.metrics });
    var buffer: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try write(&w, total, 2, 1700000000);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE joinery_relay_rooms gauge\njoinery_relay_rooms 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "joinery_relay_connections 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "joinery_relay_dropped_total{reason=\"something other than hello first\"} 2\n") != null);
}
