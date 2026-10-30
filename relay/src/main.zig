//! joinery-relay: shares Joinery sessions between people, end-to-end encrypted, without reading them. See
//! docs/relay.md.
//!
//!     joinery-relay [--address 127.0.0.1] [--port 8787] [--metrics-address 127.0.0.1] [--metrics-port 9187]
//!                   [--threads <half the cores>] [--pin <first CPU>] [--batch-ms 5]
//!                   [--max-rooms 256] [--max-connections 768] [--max-outbox-mib 128]
//!
//! Prometheus metrics are at http://<metrics address>:<metrics port>/metrics, on this machine only unless the metrics
//! address says otherwise.

const std = @import("std");
const builtin = @import("builtin");
const Server = @import("server/Server.zig");
const Relay = @import("relay/Relay.zig");
const socket = @import("server/socket.zig");

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
    // Half the cores: the kernel's network work needs the rest. On 8 and 16 cores, more loops than that delivered no
    // more, and past it, less (bench/load-results.md).
    var threads: usize = (std.Thread.getCpuCount() catch 2) / 2;
    // Linux: loop i runs only on CPU `pin + i`, so its sockets' data stays in that CPU's caches.
    var pin: ?usize = null;
    // How long a connection's queue waits for more before it's sent: 5 ms did the same work with 40% less CPU and
    // took a relay from 750 full rooms to 1,000, for a wait well under a frame (bench/load-results.md).
    var batch_ms: i64 = 5;
    // What anyone can make the relay hold, without signing in, sized for 2 GiB at worst: a room up to its log's ring
    // and a snapshot, about 4 MiB, and a connection up to a snapshot's worth of input, about 1 MiB. Raise them with
    // the memory the relay's given.
    var max_rooms: usize = 256;
    var max_connections: usize = 768;
    // And what connections that don't read can make it hold, queued for them, all together: what's left of 2 GiB.
    var max_outbox_mib: usize = 128;
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
        } else if (std.mem.eql(u8, arg, "--threads")) {
            threads = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--batch-ms")) {
            batch_ms = std.fmt.parseInt(i64, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--max-rooms")) {
            max_rooms = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--max-connections")) {
            max_connections = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--max-outbox-mib")) {
            max_outbox_mib = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--pin")) {
            pin = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else return usage();
    }
    // A room's ID names its loop in a byte.
    threads = std.math.clamp(threads, 1, 256);

    const address = try std.Io.net.Ip4Address.parse(address_text, port);
    const metrics_address = try std.Io.net.Ip4Address.parse(metrics_address_text, metrics_port);
    // On Linux each loop has its own listener on the port, and the kernel spreads connections across them evenly. One
    // shared, it woke the same few loops first: they took most of the rooms, the busiest 20 times the quietest's work.
    const own_listeners = builtin.os.tag == .linux;
    const shared_listener = try socket.listen(address, own_listeners);
    const metrics_listener = try socket.listen(metrics_address, false);
    // A loop per thread, each with its own rooms; this thread runs the first.
    const loops = try init.gpa.alloc(*Server, threads);
    for (loops, 0..) |*loop, i| {
        loop.* = try init.gpa.create(Server);
        const listener = if (own_listeners and i > 0) try socket.listen(address, true) else shared_listener;
        // ponytail: each loop gets an even share, as the kernel spreads connections evenly; one loop can turn hosts
        // away while another has room. A count shared across loops if that matters.
        const config: Relay.Config = .{ .max_rooms = std.math.divCeil(usize, max_rooms, threads) catch unreachable };
        try loop.*.init(io, init.gpa, config, @intCast(i), listener, metrics_listener);
    }
    for (loops) |loop| {
        loop.loops = loops;
        loop.batch_ms = batch_ms;
        // ponytail: an even share each, like the rooms.
        loop.out_budget = (max_outbox_mib *| (1 << 20)) / threads;
    }
    const cap = Server.limitConnections(threads, max_connections);
    std.log.info("relaying on {f} with {d} loops, up to {d} rooms and {d} connections, metrics at http://{f}/metrics", .{ address, threads, max_rooms, cap, metrics_address });
    for (loops[1..]) |loop| {
        const thread = try std.Thread.spawn(.{}, runLoop, .{ loop, pin });
        thread.detach();
    }
    runLoop(loops[0], pin);
}

fn runLoop(loop: *Server, pin: ?usize) void {
    if (pin) |first| {
        if (builtin.os.tag != .linux) @panic("--pin is for Linux");
        var set: std.os.linux.cpu_set_t = @splat(0);
        const cpu = first + loop.index;
        set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
        std.os.linux.sched_setaffinity(0, &set) catch |err| std.debug.panic("couldn't pin loop {d} to CPU {d}: {t}", .{ loop.index, cpu, err });
    }
    loop.run() catch |err| std.debug.panic("loop {d} stopped: {t}", .{ loop.index, err });
}

fn usage() error{Usage} {
    std.log.err("usage: joinery-relay [--address 127.0.0.1] [--port 8787] [--metrics-address 127.0.0.1] [--metrics-port 9187] [--threads n] [--pin first-cpu] [--batch-ms n] [--max-rooms n] [--max-connections n] [--max-outbox-mib n]", .{});
    return error.Usage;
}
