//! The relay on the network: one loop per core, each on its own thread with its own event queue (kqueue, or epoll on
//! Linux), its own relay and its own rooms, sharing nothing as they run. Every loop watches the one listening socket,
//! and whichever's free takes a new connection. A room's ID says which loop has it, so a guest's connection that
//! comes in on another loop is handed to that one, with what it's sent so far, before the relay sees its hello. That,
//! and adding up the metrics, is all the loops ever do together.
//!
//! Each turn of the loop reads whatever's come in, hands each whole WebSocket message to the relay, then writes
//! everything queued for each connection in one `send`, so a frame going to 31 guests costs 31 sends however many
//! frames came in that turn, not more. Nothing waits on a socket: what a socket won't take yet stays in its outbox
//! until it's writable. A connection whose outbox fills is too far behind: it's closed, and when it comes back the
//! relay catches it up from the snapshot. With one thread to each relay, no relay needs a lock.
//!
//! Pointer updates are the exception to "everything queued goes": each connection holds only the newest from each
//! person until its queue has gone, so a connection that's behind is sent where pointers are, not where they were.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Relay = @import("Relay.zig");
const wire = @import("wire.zig");

const Server = @This();
const log = std.log.scoped(.server);

io: Io,
gpa: Allocator,
/// Which loop this is, and all of them, this one included.
index: u8,
loops: []const *Server = &.{},
/// Connections handed to this loop by others, and the pipe that wakes it for them.
inbox: std.atomic.Value(?*Conn) = .init(null),
wake: [2]c.fd_t,
/// Connections to hand to another loop at the end of this turn.
leaving: std.ArrayList(*Conn) = .empty,
/// Hosts not being read while this loop catches up, so they send no faster than it can pass their changes on.
held_back: std.ArrayList(*Conn) = .empty,
/// This loop's metrics as of its last tick, for the loop answering scrapes to add up.
published: Published = .{},
published_lock: Io.Mutex = .init,
limits: wire.Limits,
relay: Relay,
csprng: std.Random.DefaultCsprng,
poller: Poller,
listener: c.fd_t,
metrics_listener: c.fd_t,
next_id: u64 = 1,
/// The time, in ms, read once a turn: the relay works in milliseconds, and reading the clock for every message showed
/// up in profiles.
time: i64 = 0,
/// Every connection, for the tick to visit.
conns: std.DoublyLinkedList = .{},
conn_count: usize = 0,
/// Connections with something to send this turn, each once.
dirty: std.ArrayList(*Conn) = .empty,
/// Connections to let go of at the end of this turn, once nothing more can mention them.
done: std.ArrayList(*Conn) = .empty,
/// The network's side of the metrics.
counts: Counts = .{},
/// When it started, in seconds since 1970, for monitoring.
started: i64,

const Counts = struct {
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

/// Lets go of silent connections, and ends rooms whose host has gone, this often.
const tick_ms = 1000;
/// A connection the relay has closed gets this long to take what's queued for it, its goodbye say.
const closing_grace_ms = 5000;
/// The most that's not yet on its way a connection's socket holds: past it, what's queued waits in the outbox.
const unsent_limit = 16 * 1024;
/// TCP_NOTSENT_LOWAT, which std doesn't name for macOS.
const tcp_notsent_lowat: u32 = if (builtin.os.tag == .linux) std.os.linux.TCP.NOTSENT_LOWAT else 0x201;
/// A turn this long means the loop's behind: it holds its rooms' hosts back, not reading what they send, until a
/// turn's this short again. Their TCP windows close, so they send no faster than the loop can pass changes on, rather
/// than the loop's queues, memory and latency growing without bound.
const behind_ns = 20 * std.time.ns_per_ms;
const caught_up_ns = 5 * std.time.ns_per_ms;
/// A connection gets this long to finish its HTTP request.
const request_ms = 10_000;

/// Loop `index`, on `listener`; loop 0 answers scrapes on `metrics_listener` too. Then each needs `loops` set.
pub fn init(server: *Server, io: Io, gpa: Allocator, config: Relay.Config, index: u8, listener: c.fd_t, metrics_listener: c.fd_t) !void {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    var wake: [2]c.fd_t = undefined;
    if (c.pipe(&wake) < 0) return error.SystemResources;
    for (wake) |fd| try setNonblocking(fd);
    server.* = .{
        .io = io,
        .gpa = gpa,
        .index = index,
        .wake = wake,
        .limits = config.limits,
        .csprng = .init(seed),
        .relay = undefined,
        .poller = try .init(),
        .listener = listener,
        .metrics_listener = metrics_listener,
        .started = @divFloor(Io.Clock.real.now(io).toMilliseconds(), 1000),
    };
    var relay_config = config;
    relay_config.shard = index;
    server.relay = .init(gpa, server.csprng.random(), .{ .ptr = server, .vtable = &.{ .send = relaySend, .close = close } }, relay_config);
    try server.poller.addListener(listener, listener_tag);
    if (index == 0) try server.poller.add(metrics_listener, metrics_tag);
    try server.poller.add(wake[0], wake_tag);
}

pub fn deinit(server: *Server) void {
    server.relay.deinit();
    server.dirty.deinit(server.gpa);
    server.done.deinit(server.gpa);
    server.leaving.deinit(server.gpa);
    server.held_back.deinit(server.gpa);
}

/// What the poller hands back for the listeners and the wake pipe; connections are their own addresses.
const listener_tag: usize = 1;
const metrics_tag: usize = 2;
const wake_tag: usize = 3;

/// Runs until something's badly wrong with the event queue.
pub fn run(server: *Server) !void {
    var events: [256]Event = undefined;
    var next_tick = server.now() + tick_ms;
    while (true) {
        const ready = try server.poller.wait(&events, @intCast(@max(next_tick - server.now(), 0)));
        const turn_start = Io.Clock.boot.now(server.io).nanoseconds;
        server.time = @intCast(@divFloor(turn_start, std.time.ns_per_ms));
        for (ready) |event| switch (event.tag) {
            listener_tag => server.accept(server.listener, .http),
            metrics_tag => server.accept(server.metrics_listener, .metrics),
            wake_tag => server.takeHandedOver(),
            else => {
                const conn: *Conn = @ptrFromInt(event.tag);
                if (conn.hot.state == .gone) continue;
                if (event.readable) server.read(conn);
                if (event.writable) server.markDirty(conn);
            },
        };
        const time = server.time;
        if (time >= next_tick) {
            next_tick = time + tick_ms;
            server.relay.tick(time);
            server.expire(time);
            server.publish();
        }
        server.finishTurn();
        server.regulate(@intCast(Io.Clock.boot.now(server.io).nanoseconds - turn_start));
    }
}

/// Holds this loop's hosts back if that turn showed it's behind, or lets them go if it's caught up.
fn regulate(server: *Server, turn_ns: i64) void {
    if (server.held_back.items.len == 0 and turn_ns > behind_ns) {
        var next = server.conns.first;
        while (next) |node| : (next = node.next) {
            const conn: *Conn = @fieldParentPtr("node", node);
            const room = conn.link.room orelse continue;
            if (room.host != &conn.link or conn.hot.state != .open) continue;
            server.poller.wantRead(conn.fd, @intFromPtr(conn), false, conn.hot.wants_write) catch continue;
            conn.held_back = true;
            server.held_back.appendAssumeCapacity(conn);
        }
        server.counts.hold_backs += 1;
        server.counts.hosts_held_back = server.held_back.items.len;
        log.info("loop {d} is behind ({d} ms a turn): holding {d} hosts back", .{ server.index, @divFloor(turn_ns, std.time.ns_per_ms), server.held_back.items.len });
    } else if (server.held_back.items.len > 0 and turn_ns < caught_up_ns) {
        for (server.held_back.items) |conn| {
            conn.held_back = false;
            server.poller.wantRead(conn.fd, @intFromPtr(conn), true, conn.hot.wants_write) catch server.lose(conn, null);
        }
        server.held_back.clearRetainingCapacity();
        server.counts.hosts_held_back = 0;
        log.info("loop {d} has caught up: reading its hosts again", .{server.index});
    }
}

fn now(server: *const Server) i64 {
    return Io.Clock.boot.now(server.io).toMilliseconds();
}

// Connections

const Conn = struct {
    /// What every send to it touches, together: 48 bytes, so usually one cache line, two at most. Not aligned to one:
    /// the allocator gives over-aligned things a page each.
    hot: Hot,
    link: Relay.Link,
    fd: c.fd_t,
    kind: enum { http, websocket, metrics },
    /// A host not being read while its loop catches up.
    held_back: bool = false,
    /// While it's being handed to another loop, the next in that loop's inbox, and which loop.
    next_handed: ?*Conn = null,
    owner: u8 = 0,
    /// Whether the relay knows it: from its upgrade to a WebSocket, until it's closed.
    in_relay: bool = false,
    in: []u8,
    in_len: usize = 0,
    /// When it was accepted, or when the relay closed it.
    since: i64,
    /// The newest pointer update from each person, waiting for the queue to go: made on the first one, as some
    /// connections never get any.
    pointers: ?*Pointers = null,
    node: std.DoublyLinkedList.Node = .{},

    const Hot = struct {
        /// What's queued to send, `out[out_start..out_end]`.
        out: []u8,
        out_start: usize = 0,
        out_end: usize = 0,
        state: enum {
            open,
            /// The relay's closed it: what's queued goes, then the socket.
            closing,
            /// Too far behind: closed, and the relay told at the end of the turn.
            lagging,
            /// Closed; let go of at the end of the turn.
            gone,
            /// For another loop, whose room it's joining: handed to it at the end of the turn.
            leaving,
        } = .open,
        is_dirty: bool = false,
        wants_write: bool = false,

        comptime {
            assert(@sizeOf(Hot) <= std.atomic.cache_line);
        }
    };
};

/// A connection's newest pointer update from each person, while its queue goes: `count` of them, each in its slot.
/// Apart from the connection, which every send touches; this is touched only for pointer updates.
const Pointers = struct {
    count: usize,
    peers: [pointer_slots]u32,
    lens: [pointer_slots]u16,
    bytes: [pointer_slots * pointer_slot_size]u8,

    /// Holds the newest pointer update from `peer`, in place of any held already.
    fn hold(pointers: *Pointers, peer: u32, frame: []const u8) enum { held, replaced, full } {
        var result: @TypeOf(pointers.hold(peer, frame)) = .held;
        const slot = for (pointers.peers[0..pointers.count], 0..) |p, i| {
            if (p == peer) {
                result = .replaced;
                break i;
            }
        } else slot: {
            if (pointers.count == pointer_slots) return .full;
            pointers.count += 1;
            break :slot pointers.count - 1;
        };
        pointers.peers[slot] = peer;
        pointers.lens[slot] = @intCast(frame.len);
        @memcpy(pointers.bytes[slot * pointer_slot_size ..][0..frame.len], frame);
        return result;
    }

    fn held(pointers: *const Pointers, slot: usize) []const u8 {
        return pointers.bytes[slot * pointer_slot_size ..][0..pointers.lens[slot]];
    }

    fn drop(pointers: *Pointers, peer: u32) void {
        for (pointers.peers[0..pointers.count], 0..) |p, i| {
            if (p != peer) continue;
            // The last slot fills the gap.
            const last = pointers.count - 1;
            if (i != last) {
                pointers.peers[i] = pointers.peers[last];
                pointers.lens[i] = pointers.lens[last];
                @memcpy(pointers.bytes[i * pointer_slot_size ..][0..pointers.lens[last]], pointers.bytes[last * pointer_slot_size ..][0..pointers.lens[last]]);
            }
            pointers.count = last;
            return;
        }
    }
};

/// Pointer updates held, at most, per connection: one per person, as many as a room holds.
const pointer_slots = 32;
/// A pointer update bigger than this (a big selection) is queued like anything else.
const pointer_slot_size = 1024;

/// The largest message, the snapshot, with its WebSocket header, and room for the HTTP request before it.
fn inSize(limits: wire.Limits) usize {
    return @as(usize, limits.max_snapshot) + 14 + 8192;
}

/// The most a connection can have queued: a joiner's catch-up, the snapshot and the whole log, with each frame's
/// WebSocket header. The memory's only touched as it's used.
fn outSize(limits: wire.Limits) usize {
    // ponytail: twice what the frames take covers the headers of the smallest frames; per-frame cursors into the log
    // would make this zero, as docs/relay.md has it.
    return 2 * (@as(usize, limits.max_snapshot) + limits.log_bytes);
}

fn accept(server: *Server, listener: c.fd_t, kind: @FieldType(Conn, "kind")) void {
    // As many as are waiting.
    while (true) {
        const fd = c.accept(listener, null, null);
        if (fd < 0) return;
        server.adopt(fd, kind) catch {
            _ = c.close(fd);
            log.warn("turned a connection away: out of memory", .{});
        };
    }
}

fn adopt(server: *Server, fd: c.fd_t, kind: @FieldType(Conn, "kind")) !void {
    try setNonblocking(fd);
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &one, @sizeOf(c_int));
    if (builtin.os.tag.isDarwin()) _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    // Little that isn't on its way yet waits in the kernel: what a slow connection is behind on waits here, where
    // pointer updates can be replaced by newer ones. What's in flight isn't limited, so fast links stay fast.
    const unsent: c_int = unsent_limit;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, tcp_notsent_lowat, &unsent, @sizeOf(c_int));
    const pages = std.heap.page_allocator;
    const conn = try server.gpa.create(Conn);
    errdefer server.gpa.destroy(conn);
    const in = try Relay.reserve(u8, pages, if (kind == .metrics) 8192 else inSize(server.limits));
    errdefer Relay.release(pages, in);
    const out = try Relay.reserve(u8, pages, if (kind == .metrics) 32 * 1024 else outSize(server.limits));
    errdefer Relay.release(pages, out);
    // IDs unique across loops: each loop counts in its own lane.
    const id = server.next_id * server.loops.len + server.index;
    conn.* = .{ .hot = .{ .out = out }, .link = .{ .id = id }, .fd = fd, .kind = kind, .in = in, .since = server.time };
    try server.watch(conn);
    server.next_id += 1;
}

/// Takes a connection into this loop's event queue and lists.
fn watch(server: *Server, conn: *Conn) !void {
    // Room for every connection in a turn's lists, so adding to them in a turn never allocates or fails.
    try server.dirty.ensureTotalCapacity(server.gpa, server.conn_count + 1);
    try server.done.ensureTotalCapacity(server.gpa, server.conn_count + 1);
    try server.leaving.ensureTotalCapacity(server.gpa, server.conn_count + 1);
    try server.held_back.ensureTotalCapacity(server.gpa, server.conn_count + 1);
    try server.poller.add(conn.fd, @intFromPtr(conn));
    server.conn_count += 1;
    server.conns.append(&conn.node);
}

fn setNonblocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.Unexpected;
    var o: c.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    if (c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(o))))) < 0) return error.Unexpected;
}

/// Reads all that's come in, handling each whole message as it's complete.
fn read(server: *Server, conn: *Conn) void {
    while (conn.hot.state == .open) {
        if (conn.in_len == conn.in.len) return server.lose(conn, "a message too big to take");
        const space = conn.in.len - conn.in_len;
        const n = c.recv(conn.fd, conn.in[conn.in_len..].ptr, space, 0);
        if (n == 0) return server.lose(conn, null);
        if (n < 0) return if (c.errno(n) == .AGAIN) {} else server.lose(conn, null);
        conn.in_len += @intCast(n);
        const used = switch (conn.kind) {
            .http, .metrics => server.request(conn),
            .websocket => server.messages(conn),
        };
        // What's left is the start of what's next.
        @memmove(conn.in[0 .. conn.in_len - used], conn.in[used..conn.in_len]);
        conn.in_len -= used;
        // Short of the space: that was all there was. Asking again would only be told so, a system call for nothing;
        // if more comes, the event queue says.
        if (@as(usize, @intCast(n)) < space) return;
    }
}

/// The HTTP request a connection starts with, once it's whole: a WebSocket's, a link opened in a browser, or a
/// scrape of the metrics. Returns the bytes it took.
fn request(server: *Server, conn: *Conn) usize {
    const end = std.mem.indexOf(u8, conn.in[0..conn.in_len], "\r\n\r\n") orelse return 0;
    const head = conn.in[0 .. end + 4];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    var words = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
    _ = words.next();
    const target = words.next() orelse "";
    var key: ?[]const u8 = null;
    var upgrade = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) key = value;
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
    }
    if (conn.kind == .metrics) {
        server.respondMetrics(conn, std.mem.eql(u8, target, "/metrics"));
    } else if (upgrade and key != null) {
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        var sha1: std.crypto.hash.Sha1 = .init(.{});
        sha1.update(key.?);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        sha1.final(&digest);
        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &digest);
        server.queue(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
        server.queue(conn, &accept_key);
        server.queue(conn, "\r\n\r\n");
        conn.kind = .websocket;
        conn.in_relay = true;
        server.counts.connections += 1;
        server.counts.connections_open += 1;
        server.relay.opened(&conn.link, server.time);
        const used = head.len;
        // Anything after it is the first messages.
        @memmove(conn.in[0 .. conn.in_len - used], conn.in[used..conn.in_len]);
        conn.in_len -= used;
        return server.messages(conn);
    } else {
        // A link opened in a browser is told where it goes.
        const share_link = std.mem.startsWith(u8, target, "/r/");
        server.respondText(conn, if (share_link) "200 OK" else "404 Not Found", if (share_link)
            "This is a Joinery share link. Copy it, and paste it into Join in Joinery's library.\n"
        else
            "This is a Joinery relay. Share from Joinery to use it.\n");
    }
    return head.len;
}

fn respondText(server: *Server, conn: *Conn, status: []const u8, body: []const u8) void {
    var head: [160]u8 = undefined;
    server.queue(conn, std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ status, body.len }) catch unreachable);
    server.queue(conn, body);
    server.closeAfterSending(conn);
}

/// Every whole WebSocket message in what's come in. Returns the bytes they took.
fn messages(server: *Server, conn: *Conn) usize {
    var at: usize = 0;
    while (conn.hot.state == .open) {
        const bytes = conn.in[at..conn.in_len];
        if (bytes.len < 2) break;
        const fin = bytes[0] & 0x80 != 0;
        const opcode = bytes[0] & 0x0f;
        const masked = bytes[1] & 0x80 != 0;
        var length: u64 = bytes[1] & 0x7f;
        var head: usize = 2;
        if (length == 126) {
            if (bytes.len < 4) break;
            length = std.mem.readInt(u16, bytes[2..4], .big);
            head = 4;
        } else if (length == 127) {
            if (bytes.len < 10) break;
            length = std.mem.readInt(u64, bytes[2..10], .big);
            head = 10;
        }
        // Clients mask everything, and the relay takes only whole messages.
        if (!masked or !fin) {
            server.lose(conn, if (!masked) "an unmasked message" else "a message in pieces");
            break;
        }
        if (length > conn.in.len) {
            server.lose(conn, "a message too big to take");
            break;
        }
        const total = head + 4 + @as(usize, @intCast(length));
        if (bytes.len < total) break;
        const mask = bytes[head..][0..4].*;
        const payload = bytes[head + 4 .. total];
        unmask(payload, mask);
        // A hello for a room another loop has: that loop takes the connection, this message and all after it, as
        // they came.
        if (opcode == 0x2 and conn.link.room == null and server.loops.len > 1) {
            if (server.ownerOf(payload)) |owner| if (owner != server.index) {
                unmask(payload, mask);
                conn.owner = owner;
                conn.hot.state = .leaving;
                server.leaving.appendAssumeCapacity(conn);
                break;
            };
        }
        at += total;
        switch (opcode) {
            0x2 => {
                server.counts.frames_in += 1;
                server.counts.bytes_in += payload.len;
                server.relay.received(&conn.link, payload, server.time);
            },
            0x8 => server.lose(conn, null),
            0x9 => server.queueFrame(conn, 0xA, payload),
            else => {},
        }
    }
    return at;
}

/// Unmasks a client's message in place: the one pass the relay makes over a body. Sixteen bytes at a time, the mask
/// repeated across a vector: byte by byte, it was four instructions a byte, a millisecond for a 1 MiB snapshot.
pub fn unmask(payload: []u8, mask: [4]u8) void {
    const V = @Vector(16, u8);
    const repeated: V = @bitCast(@as(@Vector(4, u32), @splat(@bitCast(mask))));
    var i: usize = 0;
    while (i + 16 <= payload.len) : (i += 16) {
        const chunk: V = payload[i..][0..16].*;
        payload[i..][0..16].* = chunk ^ repeated;
    }
    // The rest; `i` is a multiple of 16, so the mask lines up.
    for (payload[i..], i..) |*b, j| b.* ^= mask[j % 4];
}

/// A connection's gone, or is no use: closed now, and the relay told, unless it's the one that closed it.
fn lose(server: *Server, conn: *Conn, why: ?[]const u8) void {
    if (conn.hot.state == .gone) return;
    if (why) |w| log.info("connection {d} closed: {s}", .{ conn.link.id, w });
    const tell = conn.in_relay and (conn.hot.state == .open or conn.hot.state == .lagging);
    server.shut(conn);
    if (tell) server.relay.closed(&conn.link, server.time);
}

fn shut(server: *Server, conn: *Conn) void {
    if (conn.in_relay) server.counts.connections_open -= 1;
    conn.in_relay = false;
    conn.hot.state = .gone;
    if (conn.held_back) {
        conn.held_back = false;
        const i = std.mem.indexOfScalar(*Conn, server.held_back.items, conn).?;
        _ = server.held_back.swapRemove(i);
        server.counts.hosts_held_back = server.held_back.items.len;
    }
    _ = c.close(conn.fd);
    server.conns.remove(&conn.node);
    server.conn_count -= 1;
    server.done.appendAssumeCapacity(conn);
}

/// Once what's queued is sent, the connection's closed.
fn closeAfterSending(server: *Server, conn: *Conn) void {
    conn.hot.state = .closing;
    conn.since = server.time;
    server.markDirty(conn);
}

/// Lets go of connections that never finished asking, or are taking too long to take their goodbye.
fn expire(server: *Server, now_ms: i64) void {
    var next = server.conns.first;
    while (next) |node| {
        next = node.next;
        const conn: *Conn = @fieldParentPtr("node", node);
        const late = switch (conn.hot.state) {
            .closing => now_ms - conn.since > closing_grace_ms,
            .open => conn.kind != .websocket and now_ms - conn.since > request_ms,
            .lagging, .gone, .leaving => false,
        };
        if (late) server.shut(conn);
    }
}

// Sending

fn markDirty(server: *Server, conn: *Conn) void {
    if (conn.hot.is_dirty or conn.hot.state == .gone or conn.hot.state == .leaving) return;
    conn.hot.is_dirty = true;
    server.dirty.appendAssumeCapacity(conn);
}

/// Appends bytes to a connection's outbox, or if it's full, gives up on it: it's too far behind.
fn queue(server: *Server, conn: *Conn, bytes: []const u8) void {
    if (conn.hot.state != .open) return;
    if (conn.hot.out_end + bytes.len > conn.hot.out.len) {
        // Room at the start, where what's been sent was.
        @memmove(conn.hot.out[0 .. conn.hot.out_end - conn.hot.out_start], conn.hot.out[conn.hot.out_start..conn.hot.out_end]);
        conn.hot.out_end -= conn.hot.out_start;
        conn.hot.out_start = 0;
        if (conn.hot.out_end + bytes.len > conn.hot.out.len) {
            log.info("connection {d} dropped: its outbox is full, so it's too far behind", .{conn.link.id});
            server.counts.lagging += 1;
            conn.hot.state = .lagging;
            // Told to the relay at the end of the turn: this is inside one of its calls.
            server.markDirty(conn);
            return;
        }
    }
    @memcpy(conn.hot.out[conn.hot.out_end..][0..bytes.len], bytes);
    conn.hot.out_end += bytes.len;
    server.markDirty(conn);
}

fn queueFrame(server: *Server, conn: *Conn, opcode: u8, payload: []const u8) void {
    var header: [10]u8 = undefined;
    server.queue(conn, webSocketHeader(&header, opcode, payload.len));
    server.queue(conn, payload);
}

/// Sends what each connection has queued, in one `send` each, and lets go of what's done with.
fn finishTurn(server: *Server) void {
    // Telling the relay of lagging connections can queue more, for others, so this goes until nothing's new.
    var i: usize = 0;
    while (i < server.dirty.items.len) : (i += 1) {
        const conn = server.dirty.items[i];
        if (conn.hot.state == .lagging) server.lose(conn, null);
    }
    for (server.dirty.items) |conn| {
        if (conn.hot.state == .open or conn.hot.state == .closing) server.flush(conn);
        // After: sending queues what was held, which would list it again.
        conn.hot.is_dirty = false;
    }
    server.dirty.clearRetainingCapacity();
    for (server.leaving.items) |conn| server.handOver(conn);
    server.leaving.clearRetainingCapacity();
    for (server.done.items) |conn| server.free(conn);
    server.done.clearRetainingCapacity();
}

fn flush(server: *Server, conn: *Conn) void {
    while (true) {
        server.send(conn) orelse return;
        // Sent everything: the newest pointer updates go next.
        const pointers = conn.pointers orelse break;
        if (pointers.count == 0) break;
        for (0..pointers.count) |i| server.queueFrame(conn, 0x2, pointers.held(i));
        pointers.count = 0;
    }
    if (conn.hot.wants_write) {
        server.poller.wantWrite(conn.fd, @intFromPtr(conn), false, !conn.held_back) catch {};
        conn.hot.wants_write = false;
    }
    if (conn.hot.state == .closing) server.shut(conn);
}

/// Sends what's queued. Null if it couldn't all go: the socket's full, and the poller will say when it isn't.
fn send(server: *Server, conn: *Conn) ?void {
    while (conn.hot.out_start < conn.hot.out_end) {
        const flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
        const n = c.send(conn.fd, conn.hot.out[conn.hot.out_start..conn.hot.out_end].ptr, conn.hot.out_end - conn.hot.out_start, flags);
        if (n < 0) {
            if (c.errno(n) == .AGAIN) {
                // Told when it can take more.
                if (!conn.hot.wants_write) server.poller.wantWrite(conn.fd, @intFromPtr(conn), true, !conn.held_back) catch {
                    server.lose(conn, null);
                    return null;
                };
                conn.hot.wants_write = true;
                return null;
            }
            server.lose(conn, null);
            return null;
        }
        conn.hot.out_start += @intCast(n);
    }
    conn.hot.out_start = 0;
    conn.hot.out_end = 0;
}

fn free(server: *Server, conn: *Conn) void {
    const pages = std.heap.page_allocator;
    Relay.release(pages, conn.in);
    Relay.release(pages, conn.hot.out);
    if (conn.pointers) |pointers| pages.rawFree(std.mem.asBytes(pointers), .of(Pointers), @returnAddress());
    server.gpa.destroy(conn);
}

// Handing connections between loops

/// The loop a guest's hello says has its room; none for anything else, which this loop's relay answers.
fn ownerOf(server: *const Server, message: []const u8) ?u8 {
    const header = wire.Header.ofFrame(message) catch return null;
    if (header.kind != .hello) return null;
    const hello = wire.Hello.parse(message[wire.header_size..]) catch return null;
    if (hello.role == .host) return null;
    const shard = Relay.shardOf(hello.room) orelse return null;
    return @intCast(shard % server.loops.len);
}

/// Gives a connection to the loop that has its room. From here on, this loop doesn't touch it.
fn handOver(server: *Server, conn: *Conn) void {
    server.poller.remove(conn.fd, conn.hot.wants_write);
    conn.hot.wants_write = false;
    // Out of this relay's lobby, quietly: it hasn't joined anything here.
    server.relay.closed(&conn.link, server.time);
    server.counts.connections_open -= 1;
    server.conns.remove(&conn.node);
    server.conn_count -= 1;
    const owner = server.loops[conn.owner];
    var head = owner.inbox.load(.monotonic);
    while (true) {
        conn.next_handed = head;
        head = owner.inbox.cmpxchgWeak(head, conn, .release, .monotonic) orelse break;
    }
    _ = c.write(owner.wake[1], "x", 1);
}

/// Takes the connections other loops have handed this one, and handles what each has sent.
fn takeHandedOver(server: *Server) void {
    var drain: [64]u8 = undefined;
    while (c.read(server.wake[0], &drain, drain.len) > 0) {}
    var next = server.inbox.swap(null, .acquire);
    while (next) |conn| {
        next = conn.next_handed;
        conn.hot.state = .open;
        conn.hot.is_dirty = false;
        conn.link.room = null;
        conn.link.node = .{};
        server.watch(conn) catch {
            _ = c.close(conn.fd);
            server.free(conn);
            continue;
        };
        server.counts.connections_open += 1;
        server.relay.opened(&conn.link, server.time);
        const used = server.messages(conn);
        @memmove(conn.in[0 .. conn.in_len - used], conn.in[used..conn.in_len]);
        conn.in_len -= used;
        if (conn.hot.out_end > conn.hot.out_start) server.markDirty(conn);
    }
}

// What the relay does.

fn relaySend(ptr: *anyopaque, link: *Relay.Link, frame: []const u8) void {
    const server: *Server = @ptrCast(@alignCast(ptr));
    const conn: *Conn = @fieldParentPtr("link", link);
    if (conn.hot.state != .open) return;
    server.counts.frames_out += 1;
    server.counts.bytes_out += frame.len;
    const kind = frame[1];
    const peer = std.mem.readInt(u32, frame[16..20], .little);
    if (kind == @backingInt(wire.Kind.presence) and frame.len <= pointer_slot_size) {
        return server.holdPointer(conn, peer, frame);
    }
    // Gone: an update from before can't follow it, or they'd seem to be back.
    if (kind == @backingInt(wire.Kind.left)) if (conn.pointers) |pointers| pointers.drop(peer);
    server.queueFrame(conn, 0x2, frame);
}

fn holdPointer(server: *Server, conn: *Conn, peer: u32, frame: []const u8) void {
    const pointers = conn.pointers orelse made: {
        // Taken as it is, unfilled: only its count's written now, and its slots as they're used.
        const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(Pointers), .of(Pointers), @returnAddress()) orelse {
            return server.queueFrame(conn, 0x2, frame);
        };
        const made: *Pointers = @ptrCast(@alignCast(bytes));
        made.count = 0;
        conn.pointers = made;
        break :made made;
    };
    switch (pointers.hold(peer, frame)) {
        .held => {},
        .replaced => server.counts.pointers_replaced += 1,
        // More people than slots: queued like anything else.
        .full => return server.queueFrame(conn, 0x2, frame),
    }
    server.markDirty(conn);
}

fn close(ptr: *anyopaque, link: *Relay.Link) void {
    const server: *Server = @ptrCast(@alignCast(ptr));
    const conn: *Conn = @fieldParentPtr("link", link);
    if (conn.hot.state != .open) return;
    // The relay's let go of it already.
    if (conn.in_relay) server.counts.connections_open -= 1;
    conn.in_relay = false;
    server.closeAfterSending(conn);
}

/// A final, unmasked message's header, as a server sends it.
fn webSocketHeader(buffer: *[10]u8, opcode: u8, length: usize) []const u8 {
    buffer[0] = 0x80 | opcode;
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

// Metrics

/// A loop's metrics, as it last published them.
const Published = struct {
    counts: Counts = .{},
    metrics: Relay.Metrics = .{},
    gauges: Relay.Gauges = .{ .rooms = 0, .peers = 0, .lobby = 0, .log_bytes = 0 },

    /// Adds `other`'s to these.
    fn add(total: *Published, other: Published) void {
        inline for (@typeInfo(Counts).@"struct".field_names) |name| @field(total.counts, name) += @field(other.counts, name);
        inline for (@typeInfo(Relay.Gauges).@"struct".field_names) |name| @field(total.gauges, name) += @field(other.gauges, name);
        inline for (@typeInfo(Relay.Metrics).@"struct".field_names) |name| {
            if (@TypeOf(@field(total.metrics, name)) == u64) @field(total.metrics, name) += @field(other.metrics, name);
        }
        for (other.metrics.drops[0..other.metrics.reasons]) |reason| total.metrics.droppedBy(reason.why, reason.count);
    }
};

/// Copies this loop's metrics where the loop answering scrapes can add them up. Once a tick, so they're up to a
/// second old.
fn publish(server: *Server) void {
    server.published_lock.lockUncancelable(server.io);
    defer server.published_lock.unlock(server.io);
    server.published = .{ .counts = server.counts, .metrics = server.relay.metrics, .gauges = server.relay.gauges() };
}

fn respondMetrics(server: *Server, conn: *Conn, found: bool) void {
    if (!found) return server.respondText(conn, "404 Not Found", "Not found.\n");
    server.publish();
    var total: Published = .{};
    for (server.loops) |loop| {
        loop.published_lock.lockUncancelable(server.io);
        defer loop.published_lock.unlock(server.io);
        total.add(loop.published);
    }
    var body_buffer: [16 * 1024]u8 = undefined;
    var body: Io.Writer = .fixed(&body_buffer);
    writeMetrics(&body, total, server.loops.len, server.started) catch {};
    var head: [160]u8 = undefined;
    server.queue(conn, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\ncontent-type: text/plain; version=0.0.4; charset=utf-8\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.buffered().len}) catch unreachable);
    server.queue(conn, body.buffered());
    server.closeAfterSending(conn);
}

/// The metrics, in Prometheus's text format.
fn writeMetrics(w: *Io.Writer, total: Published, loops: usize, started: i64) Io.Writer.Error!void {
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
    try writeMetrics(&w, total, 2, 1700000000);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE joinery_relay_rooms gauge\njoinery_relay_rooms 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "joinery_relay_connections 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "joinery_relay_dropped_total{reason=\"something other than hello first\"} 2\n") != null);
}

// The event queue

/// The OS's event queue: kqueue, or epoll on Linux. Level-triggered: a socket with something left to read is
/// reported again.
const Poller = switch (builtin.os.tag) {
    .linux => Epoll,
    else => Kqueue,
};

const Event = struct { tag: usize, readable: bool, writable: bool };

const Kqueue = struct {
    fd: c.fd_t,
    raw: [256]c.Kevent = undefined,

    fn init() !Kqueue {
        const fd = c.kqueue();
        if (fd < 0) return error.SystemResources;
        return .{ .fd = fd };
    }

    fn change(k: *Kqueue, fd: c.fd_t, filter: i16, flags: u16, tag: usize) !void {
        const ev: c.Kevent = .{ .ident = @intCast(fd), .filter = filter, .flags = flags, .fflags = 0, .data = 0, .udata = tag };
        if (c.kevent(k.fd, (&ev)[0..1], 1, &k.raw, 0, null) < 0) return error.SystemResources;
    }

    fn add(k: *Kqueue, fd: c.fd_t, tag: usize) !void {
        try k.change(fd, c.EVFILT.READ, c.EV.ADD, tag);
    }

    /// A listening socket every loop watches: each is woken, and whichever accepts first has the connection.
    fn addListener(k: *Kqueue, fd: c.fd_t, tag: usize) !void {
        try k.add(fd, tag);
    }

    fn remove(k: *Kqueue, fd: c.fd_t, writing: bool) void {
        k.change(fd, c.EVFILT.READ, c.EV.DELETE, 0) catch {};
        if (writing) k.change(fd, c.EVFILT.WRITE, c.EV.DELETE, 0) catch {};
    }

    /// Whether the socket's reported readable; writable stays as it is.
    fn wantRead(k: *Kqueue, fd: c.fd_t, tag: usize, on: bool, writing: bool) !void {
        _ = writing;
        try k.change(fd, c.EVFILT.READ, if (on) c.EV.ENABLE else c.EV.DISABLE, tag);
    }

    fn wantWrite(k: *Kqueue, fd: c.fd_t, tag: usize, on: bool, reading: bool) !void {
        _ = reading;
        try k.change(fd, c.EVFILT.WRITE, if (on) c.EV.ADD | c.EV.ENABLE else c.EV.DELETE, tag);
    }

    fn wait(k: *Kqueue, events: []Server.Event, timeout_ms: u64) ![]Server.Event {
        const timeout: c.timespec = .{ .sec = @intCast(timeout_ms / 1000), .nsec = @intCast(timeout_ms % 1000 * std.time.ns_per_ms) };
        const n = c.kevent(k.fd, &k.raw, 0, &k.raw, @intCast(@min(events.len, k.raw.len)), &timeout);
        if (n < 0) return if (c.errno(n) == .INTR) events[0..0] else error.SystemResources;
        for (k.raw[0..@intCast(n)], events[0..@intCast(n)]) |raw, *event| {
            // An end of file or error is reported as readable: reading finds it.
            event.* = .{ .tag = raw.udata, .readable = raw.filter == c.EVFILT.READ, .writable = raw.filter == c.EVFILT.WRITE };
        }
        return events[0..@intCast(n)];
    }
};

const Epoll = struct {
    fd: c.fd_t,
    raw: [256]c.epoll_event = undefined,

    fn init() !Epoll {
        const fd = c.epoll_create1(0);
        if (fd < 0) return error.SystemResources;
        return .{ .fd = fd };
    }

    fn control(e: *Epoll, op: u32, fd: c.fd_t, events: u32, tag: usize) !void {
        var ev: c.epoll_event = .{ .events = events, .data = .{ .ptr = tag } };
        if (c.epoll_ctl(e.fd, op, fd, &ev) < 0) return error.SystemResources;
    }

    fn add(e: *Epoll, fd: c.fd_t, tag: usize) !void {
        try e.control(std.os.linux.EPOLL.CTL_ADD, fd, std.os.linux.EPOLL.IN, tag);
    }

    /// A listening socket every loop watches: one is woken for each connection, not all.
    fn addListener(e: *Epoll, fd: c.fd_t, tag: usize) !void {
        const linux = std.os.linux;
        try e.control(linux.EPOLL.CTL_ADD, fd, linux.EPOLL.IN | linux.EPOLL.EXCLUSIVE, tag);
    }

    fn remove(e: *Epoll, fd: c.fd_t, writing: bool) void {
        _ = writing;
        e.control(std.os.linux.EPOLL.CTL_DEL, fd, 0, 0) catch {};
    }

    /// What the socket's reported for: epoll sets both at once.
    fn watchFor(e: *Epoll, fd: c.fd_t, tag: usize, reading: bool, writing: bool) !void {
        const linux = std.os.linux;
        const in: u32 = if (reading) linux.EPOLL.IN else 0;
        const out: u32 = if (writing) linux.EPOLL.OUT else 0;
        try e.control(linux.EPOLL.CTL_MOD, fd, in | out, tag);
    }

    fn wantRead(e: *Epoll, fd: c.fd_t, tag: usize, on: bool, writing: bool) !void {
        try e.watchFor(fd, tag, on, writing);
    }

    fn wantWrite(e: *Epoll, fd: c.fd_t, tag: usize, on: bool, reading: bool) !void {
        try e.watchFor(fd, tag, reading, on);
    }

    fn wait(e: *Epoll, events: []Server.Event, timeout_ms: u64) ![]Server.Event {
        const linux = std.os.linux;
        const n = c.epoll_wait(e.fd, &e.raw, @intCast(@min(events.len, e.raw.len)), @intCast(timeout_ms));
        if (n < 0) return if (c.errno(n) == .INTR) events[0..0] else error.SystemResources;
        for (e.raw[0..@intCast(n)], events[0..@intCast(n)]) |raw, *event| {
            event.* = .{
                .tag = raw.data.ptr,
                .readable = raw.events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0,
                .writable = raw.events & linux.EPOLL.OUT != 0,
            };
        }
        return events[0..@intCast(n)];
    }
};

test "WebSocket headers" {
    var buffer: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0 }, webSocketHeader(&buffer, 2, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 125 }, webSocketHeader(&buffer, 2, 125));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0, 126 }, webSocketHeader(&buffer, 2, 126));
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 126, 0xff, 0xff }, webSocketHeader(&buffer, 0xA, 0xffff));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0 }, webSocketHeader(&buffer, 2, 0x10000));
}

test "unmasking, sixteen at a time, matches byte by byte" {
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    for ([_]usize{ 0, 1, 15, 16, 17, 100, 1000 }) |len| {
        var bytes: [1000]u8 = undefined;
        for (&bytes, 0..) |*b, i| b.* = @truncate(i * 7);
        var expected = bytes;
        for (expected[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
        unmask(bytes[0..len], mask);
        try std.testing.expectEqualSlices(u8, expected[0..len], bytes[0..len]);
    }
}

test "a connection that's behind holds only the newest pointer update from each person" {
    const pointers = try std.testing.allocator.create(Pointers);
    defer std.testing.allocator.destroy(pointers);
    pointers.count = 0;
    try std.testing.expectEqual(.held, pointers.hold(2, "ann at 1"));
    try std.testing.expectEqual(.held, pointers.hold(3, "bob at 1"));
    try std.testing.expectEqual(.replaced, pointers.hold(2, "ann at 2"));
    try std.testing.expectEqual(@as(usize, 2), pointers.count);
    try std.testing.expectEqualStrings("ann at 2", pointers.held(0));
    // Ann leaves: her update goes, and Bob's fills the gap.
    pointers.drop(2);
    try std.testing.expectEqual(@as(usize, 1), pointers.count);
    try std.testing.expectEqualStrings("bob at 1", pointers.held(0));
    for (0..pointer_slots - 1) |peer| _ = pointers.hold(@intCast(100 + peer), "x");
    try std.testing.expectEqual(.full, pointers.hold(999, "y"));
}
