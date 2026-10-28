//! joinery-relay: shares Joinery sessions between people, end-to-end encrypted, without reading them. See
//! docs/relay.md.
//!
//!     joinery-relay [--address 127.0.0.1] [--port 8787] [--metrics-address 127.0.0.1] [--metrics-port 9187]
//!
//! Prometheus metrics are at http://<metrics address>:<metrics port>/metrics, on this machine only unless the metrics
//! address says otherwise.

const std = @import("std");
const Server = @import("Server.zig");

pub const std_options: std.Options = .{ .logFn = log };

/// The std log, each line with the time it was written, in UTC.
fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    const second: u64 = @intCast(@mod(@divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000), 86400));
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.print("{d:0>2}:{d:0>2}:{d:0>2}Z ", .{ second / 3600, second / 60 % 60, second % 60 }) catch return;
    std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var address_text: []const u8 = "127.0.0.1";
    var port: u16 = 8787;
    var metrics_address_text: []const u8 = "127.0.0.1";
    var metrics_port: u16 = 9187;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        const value = args.next() orelse return usage();
        if (std.mem.eql(u8, arg, "--address")) {
            address_text = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            port = std.fmt.parseInt(u16, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--metrics-address")) {
            metrics_address_text = value;
        } else if (std.mem.eql(u8, arg, "--metrics-port")) {
            metrics_port = std.fmt.parseInt(u16, value, 10) catch return usage();
        } else return usage();
    }

    const address = try std.Io.net.IpAddress.parse(address_text, port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const metrics_address = try std.Io.net.IpAddress.parse(metrics_address_text, metrics_port);
    var metrics_listener = try metrics_address.listen(io, .{ .reuse_address = true });
    defer metrics_listener.deinit(io);
    var server: Server = undefined;
    try server.init(io, init.gpa, .{});
    defer server.deinit();
    std.log.info("relaying on {f}, metrics at http://{f}/metrics", .{ address, metrics_address });
    var metrics = try io.concurrent(Server.serveMetrics, .{ &server, &metrics_listener });
    defer metrics.cancel(io) catch {};
    try server.serve(&listener);
}

fn usage() error{Usage} {
    std.log.err("usage: joinery-relay [--address 127.0.0.1] [--port 8787] [--metrics-address 127.0.0.1] [--metrics-port 9187]", .{});
    return error.Usage;
}
