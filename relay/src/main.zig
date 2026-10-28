//! joinery-relay: shares Joinery sessions between people, end-to-end encrypted, without reading them. See
//! docs/relay.md.
//!
//!     joinery-relay [--address 127.0.0.1] [--port 8787]

const std = @import("std");
const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var address_text: []const u8 = "127.0.0.1";
    var port: u16 = 8787;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        const value = args.next() orelse return usage();
        if (std.mem.eql(u8, arg, "--address")) {
            address_text = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            port = std.fmt.parseInt(u16, value, 10) catch return usage();
        } else return usage();
    }

    const address = try std.Io.net.IpAddress.parse(address_text, port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var server: Server = undefined;
    try server.init(io, init.gpa, .{});
    defer server.deinit();
    std.log.info("relaying on {f}", .{address});
    try server.serve(&listener);
}

fn usage() error{Usage} {
    std.log.err("usage: joinery-relay [--address 127.0.0.1] [--port 8787]", .{});
    return error.Usage;
}
