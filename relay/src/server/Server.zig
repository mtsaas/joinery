//! The relay on the network: an event loop, on its own thread with its own event queue (kqueue, or epoll on Linux),
//! its own relay and its own rooms, sharing nothing with the others as they run. On Linux each loop has its own
//! listening socket on the port, and the kernel spreads new connections across them; elsewhere they share one, and
//! whichever's free takes a new connection. A room's ID says which loop has it, so a guest's connection that
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
const Relay = @import("../relay/Relay.zig");
const wire = @import("../relay/wire.zig");
const Conn = @import("Conn.zig");
const Pointers = @import("Pointers.zig");
const http = @import("http.zig");
const metrics = @import("metrics.zig");
const socket = @import("socket.zig");
const websocket = @import("websocket.zig");
const Poller = @import("poller.zig").Poller;
const Event = @import("poller.zig").Event;

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
published: metrics.Published = .{},
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
counts: metrics.Counts = .{},
/// When it started, in seconds since 1970, for monitoring.
started: i64,

/// Lets go of silent connections, and ends rooms whose host has gone, this often.
const tick_ms = 1000;
/// A connection the relay has closed gets this long to take what's queued for it, its goodbye say.
const closing_grace_ms = 5000;
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
    for (wake) |fd| try socket.setNonblocking(fd);
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
        // A loop busy with guests alone has no hosts to hold back.
        if (server.held_back.items.len == 0) return;
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

fn accept(server: *Server, listener: c.fd_t, kind: Conn.Kind) void {
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

fn adopt(server: *Server, fd: c.fd_t, kind: Conn.Kind) !void {
    try socket.configure(fd);
    const pages = std.heap.page_allocator;
    const conn = try server.gpa.create(Conn);
    errdefer server.gpa.destroy(conn);
    const in = try Relay.reserve(u8, pages, if (kind == .metrics) 8192 else Conn.inSize(server.limits));
    errdefer Relay.release(pages, in);
    const out = try Relay.reserve(u8, pages, if (kind == .metrics) 32 * 1024 else Conn.outSize(server.limits));
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
        conn.consume(used);
        // Short of the space: that was all there was. Asking again would only be told so, a system call for nothing;
        // if more comes, the event queue says.
        if (@as(usize, @intCast(n)) < space) return;
    }
}

/// The HTTP request a connection starts with, once it's whole: a WebSocket's, a link opened in a browser, or a
/// scrape of the metrics. Returns the bytes it took.
fn request(server: *Server, conn: *Conn) usize {
    const req = http.Request.parse(conn.in[0..conn.in_len]) orelse return 0;
    if (conn.kind == .metrics) {
        server.respondMetrics(conn, std.mem.eql(u8, req.target, "/metrics"));
    } else if (req.upgrade and req.key != null) {
        server.queue(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
        server.queue(conn, &websocket.acceptKey(req.key.?));
        server.queue(conn, "\r\n\r\n");
        conn.kind = .websocket;
        conn.in_relay = true;
        server.counts.connections += 1;
        server.counts.connections_open += 1;
        server.relay.opened(&conn.link, server.time);
        // Anything after it is the first messages.
        conn.consume(req.len);
        return server.messages(conn);
    } else {
        // A link opened in a browser is told where it goes.
        const share_link = std.mem.startsWith(u8, req.target, "/r/");
        server.respondText(conn, if (share_link) "200 OK" else "404 Not Found", if (share_link)
            "This is a Joinery share link. Copy it, and paste it into Join in Joinery's library.\n"
        else
            "This is a Joinery relay. Share from Joinery to use it.\n");
    }
    return req.len;
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
        const head = websocket.Head.parse(bytes) orelse break;
        // Clients mask everything, and the relay takes only whole messages.
        if (!head.masked or !head.fin) {
            server.lose(conn, if (!head.masked) "an unmasked message" else "a message in pieces");
            break;
        }
        if (head.length > conn.in.len) {
            server.lose(conn, "a message too big to take");
            break;
        }
        const total = head.size + 4 + @as(usize, @intCast(head.length));
        if (bytes.len < total) break;
        const mask = bytes[head.size..][0..4].*;
        const payload = bytes[head.size + 4 .. total];
        websocket.unmask(payload, mask);
        // A hello for a room another loop has: that loop takes the connection, this message and all after it, as
        // they came.
        if (head.opcode == websocket.Opcode.binary and conn.link.room == null and server.loops.len > 1) {
            if (server.ownerOf(payload)) |owner| if (owner != server.index) {
                websocket.unmask(payload, mask);
                conn.owner = owner;
                conn.hot.state = .leaving;
                server.leaving.appendAssumeCapacity(conn);
                break;
            };
        }
        at += total;
        switch (head.opcode) {
            websocket.Opcode.binary => {
                server.counts.frames_in += 1;
                server.counts.bytes_in += payload.len;
                server.relay.received(&conn.link, payload, server.time);
            },
            websocket.Opcode.close => server.lose(conn, null),
            websocket.Opcode.ping => server.queueFrame(conn, websocket.Opcode.pong, payload),
            else => {},
        }
    }
    return at;
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
    server.queue(conn, websocket.header(&header, opcode, payload.len));
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
        for (0..pointers.count) |i| server.queueFrame(conn, websocket.Opcode.binary, pointers.held(i));
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
        conn.consume(server.messages(conn));
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
    if (kind == @backingInt(wire.Kind.presence) and frame.len <= Pointers.slot_size) {
        return server.holdPointer(conn, peer, frame);
    }
    // Gone: an update from before can't follow it, or they'd seem to be back.
    if (kind == @backingInt(wire.Kind.left)) if (conn.pointers) |pointers| pointers.drop(peer);
    server.queueFrame(conn, websocket.Opcode.binary, frame);
}

fn holdPointer(server: *Server, conn: *Conn, peer: u32, frame: []const u8) void {
    const pointers = conn.pointers orelse made: {
        // Taken as it is, unfilled: only its count's written now, and its slots as they're used.
        const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(Pointers), .of(Pointers), @returnAddress()) orelse {
            return server.queueFrame(conn, websocket.Opcode.binary, frame);
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
        .full => return server.queueFrame(conn, websocket.Opcode.binary, frame),
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

// Metrics

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
    var total: metrics.Published = .{};
    for (server.loops) |loop| {
        loop.published_lock.lockUncancelable(server.io);
        defer loop.published_lock.unlock(server.io);
        total.add(loop.published);
    }
    var body_buffer: [16 * 1024]u8 = undefined;
    var body: Io.Writer = .fixed(&body_buffer);
    metrics.write(&body, total, server.loops.len, server.started) catch {};
    var head: [160]u8 = undefined;
    server.queue(conn, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\ncontent-type: text/plain; version=0.0.4; charset=utf-8\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.buffered().len}) catch unreachable);
    server.queue(conn, body.buffered());
    server.closeAfterSending(conn);
}
