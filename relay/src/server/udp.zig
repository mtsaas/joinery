//! Presence over UDP, beside each connection's WebSocket (docs/relay.md, "Presence over UDP"). After its welcome, a
//! connection is sent a ticket: an ID and keys. Then each datagram, either way, is
//!
//!     id (8)  counter (8, masked)  tag (16)  header (24, sealed)  body (as it came: sealed by the clients)
//!
//! The header is sealed with AES-128-GCM under the connection's key, the body authenticated with it, the counter in the
//! nonce. The counter is masked with an AES block of the sealed header, as QUIC protects its packet numbers. A receiver
//! drops any counter it's taken, or one more than 64 behind the newest. The ID's last byte names the relay's loop, so the
//! kernel can send each datagram to the loop that has its connection.
//!
//! Each connection's keys are expanded once, when its ticket's made: a datagram costs four AES-128 blocks and GHASH over
//! what it carries, and allocates nothing. (AES-128, as QUIC and TLS use by default: presence is already sealed with the
//! room's AES-256 key, and this only keeps its header private and everything together.) GHASH takes up to 8 blocks to a reduction, with the
//! powers of its key worked out ahead, so a pointer update's 9 blocks are 2 reductions, not the 7 that feeding std's
//! GHASH its pieces made. Build for the CPU's AES and carry-less multiplication (`-Dcpu=generic+aes` on Arm,
//! `x86_64_v3+aes+pclmul`): without them std's software AES runs, several times slower.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Aes128 = std.crypto.core.aes.Aes128;
const AesCtx = std.crypto.core.aes.AesEncryptCtx;
const Ghash = std.crypto.onetimeauth.Ghash;
const header_size = @import("../relay/wire.zig").header_size;

/// Before the sealed header: the ID, the counter and the tag.
pub const prefix = 32;
/// The largest datagram either side sends or takes: a pointer update fits many times over, and it fits any path's MTU.
pub const max_datagram = 1400;
/// The ticket's body, as the WebSocket carries it, before the host (if there is one), which runs to the body's end.
pub const ticket_size = 42;
/// The longest host a ticket names: a DNS name's most.
pub const max_host = 253;
/// Times, in ms (docs/relay.md): the relay sends by WebSocket once it's heard nothing by UDP for this long.
pub const silence_ms = 20_000;

pub const Direction = enum(u8) { to_relay, to_client };

/// A connection's ID and keys, and the port to send to.
pub const Ticket = struct {
    id: u64,
    key: [16]u8,
    mask_key: [16]u8,
    port: u16,

    /// A new connection's: random keys, and an ID naming `loop` and `slot`, with 24 random bits between so a slot used
    /// again doesn't take an old connection's datagrams.
    pub fn random(io: std.Io, loop: u8, slot: u32, port: u16) !Ticket {
        var bytes: [8 + 16 + 16]u8 = undefined;
        try io.randomSecure(&bytes);
        const salt = std.mem.readInt(u64, bytes[0..8], .little);
        return .{
            .id = @as(u64, loop) << 56 | (salt & 0x00ff_ffff_0000_0000) | slot,
            .key = bytes[8..24].*,
            .mask_key = bytes[24..40].*,
            .port = port,
        };
    }

    pub fn write(t: Ticket, out: *[ticket_size]u8) void {
        std.mem.writeInt(u64, out[0..8], t.id, .little);
        out[8..24].* = t.key;
        out[24..40].* = t.mask_key;
        std.mem.writeInt(u16, out[40..42], t.port, .little);
    }

    pub fn read(bytes: *const [ticket_size]u8) Ticket {
        return .{
            .id = std.mem.readInt(u64, bytes[0..8], .little),
            .key = bytes[8..24].*,
            .mask_key = bytes[24..40].*,
            .port = std.mem.readInt(u16, bytes[40..42], .little),
        };
    }
};

/// AES-128-GCM for a 24-byte plaintext, the header, with the key's schedule and GHASH's powers worked out once. The
/// same bytes as `std.crypto.aead.aes_gcm.Aes128Gcm` (tested below).
const Gcm = struct {
    aes: AesCtx(Aes128),
    ghash: Hash,

    fn init(key: [16]u8) Gcm {
        const aes = Aes128.initEnc(key);
        var h: [16]u8 = undefined;
        aes.encrypt(&h, &@splat(0));
        return .{ .aes = aes, .ghash = .init(&h) };
    }

    /// Seals `plain` into `sealed`, returning the tag; `ad` is authenticated too.
    fn seal(g: *const Gcm, sealed: *[header_size]u8, plain: *const [header_size]u8, ad: []const u8, nonce: [12]u8) [16]u8 {
        var blocks = g.keystream(nonce);
        for (sealed, plain, blocks[16..40]) |*c, p, k| c.* = p ^ k;
        return g.tagOf(blocks[0..16], sealed, ad);
    }

    /// Opens `sealed` into `plain` if `tag` is right, in constant time; `plain` is untouched if not.
    fn open(g: *const Gcm, plain: *[header_size]u8, sealed: *const [header_size]u8, given: [16]u8, ad: []const u8, nonce: [12]u8) error{AuthenticationFailed}!void {
        var blocks = g.keystream(nonce);
        const expected = g.tagOf(blocks[0..16], sealed, ad);
        if (!std.crypto.timing_safe.eql([16]u8, expected, given)) return error.AuthenticationFailed;
        for (plain, sealed, blocks[16..40]) |*p, c, k| p.* = c ^ k;
    }

    /// The counter blocks GCM uses for 24 bytes: J0 (for the tag), then J0+1 and J0+2, encrypted, three at once.
    pub fn keystream(g: *const Gcm, nonce: [12]u8) [48]u8 {
        var counters: [48]u8 = undefined;
        inline for (0..3) |i| {
            counters[i * 16 ..][0..12].* = nonce;
            std.mem.writeInt(u32, counters[i * 16 + 12 ..][0..4], i + 1, .big);
        }
        var out: [48]u8 = undefined;
        g.aes.encryptWide(3, &out, &counters);
        return out;
    }

    /// GCM's tag: GHASH over the body, padded, the sealed header, padded, and their lengths in bits, then XORed with
    /// the first counter block. The body's whole blocks are read where they are; the rest (its last part-block, the
    /// header, the lengths) is at most 4 blocks, put together here.
    pub fn tagOf(g: *const Gcm, j0: *const [16]u8, sealed: *const [header_size]u8, ad: []const u8) [16]u8 {
        assert(ad.len <= max_datagram);
        // Checked once, above: the per-byte and per-block checks below were a third of the time in safe builds.
        @setRuntimeSafety(false);
        const whole = ad.len & ~@as(usize, 15);
        var tail: [64]u8 = @splat(0);
        // The part-block a byte at a time: a variable-length copy would be a call into libc.
        for (ad[whole..], tail[0 .. ad.len - whole]) |b, *t| t.* = b;
        const at: usize = if (ad.len > whole) 16 else 0;
        tail[at..][0..header_size].* = sealed.*;
        std.mem.writeInt(u64, tail[at + 32 ..][0..8], @as(u64, ad.len) * 8, .big);
        std.mem.writeInt(u64, tail[at + 40 ..][0..8], header_size * 8, .big);
        var out = g.ghash.hash(ad[0..whole], tail[0 .. at + 48]);
        for (&out, j0) |*o, j| o.* ^= j;
        return out;
    }
};

/// GHASH over a run of whole blocks, up to 8 to a reduction: the multiplications in a run don't wait on each other, so
/// they overlap. The arithmetic is std's (`std.crypto.ghash_polyval`): its key, shifted for GCM, its schoolbook 128-bit
/// carry-less product and its reduction. On Arm it's kept in vector registers throughout, as moving 128-bit integers
/// between them and general registers was most of the work; elsewhere it's std's own functions' shape, and without a
/// carry-less multiply instruction, std's GHASH itself.
const Hash = if (builtin.cpu.arch == .aarch64 and fast_clmul) NeonHash else if (fast_clmul) WideHash else StdHash;

/// Block `i` of `first` then `second`.
inline fn blockOf(first: []const u8, second: []const u8, i: usize) *const [16]u8 {
    @setRuntimeSafety(false);
    return if (i * 16 < first.len) first[i * 16 ..][0..16] else second[i * 16 - first.len ..][0..16];
}

/// The key H as std keeps it for GCM: read big-endian, shifted left one bit, reduced.
fn shiftedKey(key: *const [16]u8) u128 {
    const h = std.mem.readInt(u128, key, .big);
    const carry = ((@as(u128, 0xc2) << 120) | 1) & (@as(u128, 0) -% (h >> 127));
    return (h << 1) ^ carry;
}

const NeonHash = struct {
    /// H, H², … H⁸: 128-bit values as two lanes, low then high.
    powers: [8]V,

    const V = @Vector(2, u64);
    const zero: V = @splat(0);
    /// The reduction's constant: std's `p64`.
    const p64: V = .{ 0xc200000000000000, 0 };
    const I256 = struct { hi: V, lo: V, mid: V };

    fn init(key: *const [16]u8) NeonHash {
        const h: V = @bitCast(shiftedKey(key));
        var g: NeonHash = .{ .powers = undefined };
        g.powers[0] = h;
        for (1..8) |k| g.powers[k] = reduce(mul(g.powers[k - 1], h));
        return g;
    }

    /// GHASH over `first` then `second`, both whole blocks, as one run.
    pub fn hash(g: *const NeonHash, first: []const u8, second: []const u8) [16]u8 {
        assert(first.len % 16 == 0 and second.len % 16 == 0);
        @setRuntimeSafety(false);
        const blocks = (first.len + second.len) / 16;
        var acc = zero;
        var i: usize = 0;
        while (i < blocks) {
            const n: usize = @min(8, blocks - i);
            var u = mul(acc ^ load(blockOf(first, second, i)), g.powers[n - 1]);
            for (1..n) |j| {
                const p = mul(load(blockOf(first, second, i + j)), g.powers[n - 1 - j]);
                u = .{ .hi = u.hi ^ p.hi, .lo = u.lo ^ p.lo, .mid = u.mid ^ p.mid };
            }
            acc = reduce(u);
            i += n;
        }
        return store(acc);
    }

    /// A block as std's `readInt(u128, block, .big)`: its bytes reversed.
    fn load(block: *const [16]u8) V {
        const bytes: @Vector(16, u8) = block.*;
        return @bitCast(@shuffle(u8, bytes, undefined, [16]i32{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }));
    }

    fn store(x: V) [16]u8 {
        const bytes: @Vector(16, u8) = @bitCast(x);
        return @shuffle(u8, bytes, undefined, [16]i32{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 });
    }

    fn swap(x: V) V {
        return @shuffle(u64, x, undefined, [2]i32{ 1, 0 });
    }

    /// std's `clmul128`: low, high, and middle (high·low ^ low·high, from the other operand's lanes swapped).
    fn mul(x: V, y: V) I256 {
        const ys = swap(y);
        return .{ .hi = pmull2(x, y), .lo = pmull(x, y), .mid = pmull2(x, ys) ^ pmull(x, ys) };
    }

    /// std's `reduce`, its 64-bit shifts as lane moves.
    fn reduce(x: I256) V {
        const hi = x.hi ^ @shuffle(u64, x.mid, zero, [2]i32{ 1, ~@as(i32, 0) });
        const lo = x.lo ^ @shuffle(u64, x.mid, zero, [2]i32{ ~@as(i32, 0), 0 });
        const b = swap(lo) ^ pmull(lo, p64);
        return swap(b) ^ pmull(b, p64) ^ hi;
    }

    /// The low lanes multiplied carry-less.
    fn pmull(x: V, y: V) V {
        return asm ("pmull %[out].1q, %[x].1d, %[y].1d"
            : [out] "=w" (-> V),
            : [x] "w" (x),
              [y] "w" (y),
        );
    }

    /// The high lanes.
    fn pmull2(x: V, y: V) V {
        return asm ("pmull2 %[out].1q, %[x].2d, %[y].2d"
            : [out] "=w" (-> V),
            : [x] "w" (x),
              [y] "w" (y),
        );
    }
};

const WideHash = struct {
    /// H, H², … H⁸, as std keeps H.
    powers: [8]u128,

    fn init(key: *const [16]u8) WideHash {
        const h = shiftedKey(key);
        var g: WideHash = .{ .powers = undefined };
        g.powers[0] = h;
        for (1..8) |k| g.powers[k] = reduce(clmul128(g.powers[k - 1], h));
        return g;
    }

    pub fn hash(g: *const WideHash, first: []const u8, second: []const u8) [16]u8 {
        assert(first.len % 16 == 0 and second.len % 16 == 0);
        @setRuntimeSafety(false);
        const blocks = (first.len + second.len) / 16;
        var acc: u128 = 0;
        var i: usize = 0;
        while (i < blocks) {
            const n: usize = @min(8, blocks - i);
            var u = clmul128(acc ^ std.mem.readInt(u128, blockOf(first, second, i), .big), g.powers[n - 1]);
            for (1..n) |j| {
                const p = clmul128(std.mem.readInt(u128, blockOf(first, second, i + j), .big), g.powers[n - 1 - j]);
                u = .{ .hi = u.hi ^ p.hi, .lo = u.lo ^ p.lo, .mid = u.mid ^ p.mid };
            }
            acc = reduce(u);
            i += n;
        }
        var out: [16]u8 = undefined;
        std.mem.writeInt(u128, &out, acc, .big);
        return out;
    }

    const I256 = struct { hi: u128, lo: u128, mid: u128 };

    fn clmul128(x: u128, y: u128) I256 {
        return .{ .hi = clmul(x, y, .hi), .lo = clmul(x, y, .lo), .mid = clmul(x, y, .hi_lo) ^ clmul(y, x, .hi_lo) };
    }

    fn reduce(x: I256) u128 {
        const hi = x.hi ^ (x.mid >> 64);
        const lo = x.lo ^ (x.mid << 64);
        const p64 = (((1 << 121) | (1 << 126) | (1 << 127)) >> 64);
        const a = clmul(lo, p64, .lo);
        const b = ((lo << 64) | (lo >> 64)) ^ a;
        const c = clmul(b, p64, .lo);
        const d = ((b << 64) | (b >> 64)) ^ c;
        return d ^ hi;
    }

    /// std's `clmulPclmul`.
    fn clmul(x: u128, y: u128, comptime half: enum { lo, hi, hi_lo }) u128 {
        const V = @Vector(2, u64);
        return @bitCast(switch (half) {
            .hi => asm ("vpclmulqdq $0x11, %[x], %[y], %[out]"
                : [out] "=x" (-> V),
                : [x] "x" (@as(V, @bitCast(x))),
                  [y] "x" (@as(V, @bitCast(y))),
            ),
            .lo => asm ("vpclmulqdq $0x00, %[x], %[y], %[out]"
                : [out] "=x" (-> V),
                : [x] "x" (@as(V, @bitCast(x))),
                  [y] "x" (@as(V, @bitCast(y))),
            ),
            .hi_lo => asm ("vpclmulqdq $0x10, %[x], %[y], %[out]"
                : [out] "=x" (-> V),
                : [x] "x" (@as(V, @bitCast(x))),
                  [y] "x" (@as(V, @bitCast(y))),
            ),
        });
    }
};

const StdHash = struct {
    ghash: Ghash,

    fn init(key: *const [16]u8) StdHash {
        return .{ .ghash = Ghash.init(key) };
    }

    pub fn hash(g: *const StdHash, first: []const u8, second: []const u8) [16]u8 {
        // A copy: `final` wipes the one it's given.
        var mac = g.ghash;
        mac.update(first);
        mac.update(second);
        var out: [16]u8 = undefined;
        mac.final(&out);
        return out;
    }
};

/// Whether the CPU multiplies carry-less in one instruction, as std's GHASH checks.
const fast_clmul = (builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .aes)) or
    (builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .pclmul) and builtin.cpu.has(.x86, .avx));

/// 512 bytes, all of which every datagram reads (Zig lays the fields out, largest alignment first), so a batch asks
/// for all of it ahead (`prefetch`).
pub const Session = struct {
    id: u64,
    /// The counter of the last datagram sent.
    sent: u64 = 0,
    /// The newest counter taken, and which of the 64 before it have been.
    newest: u64 = 0,
    seen: u64 = 0,
    mask: AesCtx(Aes128),
    gcm: Gcm,

    pub fn init(ticket: Ticket) Session {
        return .{ .id = ticket.id, .gcm = .init(ticket.key), .mask = Aes128.initEnc(ticket.mask_key) };
    }

    /// `frame` (a header and its body) as a datagram, written into `out`.
    pub fn seal(s: *Session, direction: Direction, frame: []const u8, out: []u8) []u8 {
        assert(frame.len >= header_size and prefix + frame.len <= @min(out.len, max_datagram));
        @memcpy(out[prefix..][0..frame.len], frame);
        return s.sealInPlace(direction, out[0 .. prefix + frame.len]);
    }

    /// Seals the frame already in `datagram` after its first `prefix` bytes.
    pub fn sealInPlace(s: *Session, direction: Direction, datagram: []u8) []u8 {
        assert(datagram.len >= prefix + header_size and datagram.len <= max_datagram);
        s.sent += 1;
        const header = datagram[prefix..][0..header_size].*;
        std.mem.writeInt(u64, datagram[0..8], s.id, .little);
        datagram[16..32].* = s.gcm.seal(datagram[prefix..][0..header_size], &header, datagram[prefix + header_size ..], nonce(direction, s.sent));
        std.mem.writeInt(u64, datagram[8..16], s.sent ^ s.maskOf(datagram[prefix..][0..16]), .little);
        return datagram;
    }

    /// Asks for the session's memory ahead of its use, as a batch of datagrams does for each of its sessions before
    /// opening or sealing any, so their misses overlap.
    pub fn prefetch(s: *const Session) void {
        const bytes: [*]const u8 = @ptrCast(s);
        comptime var at = 0;
        inline while (at < @sizeOf(Session)) : (at += std.atomic.cache_line) @prefetch(bytes + at, .{});
    }

    /// The frame in `datagram`, opened in place, if it's this session's and not one it's taken already. Nothing about
    /// the session changes for one that isn't.
    pub fn open(s: *Session, direction: Direction, datagram: []u8) ?[]u8 {
        if (datagram.len < prefix + header_size or datagram.len > max_datagram) return null;
        const counter = std.mem.readInt(u64, datagram[8..16], .little) ^ s.maskOf(datagram[prefix..][0..16]);
        if (counter == 0 or counter +| 64 <= s.newest) return null;
        if (counter <= s.newest and s.seen >> @intCast(s.newest - counter) & 1 != 0) return null;
        const frame = datagram[prefix..];
        const sealed = frame[0..header_size].*;
        s.gcm.open(frame[0..header_size], &sealed, datagram[16..32].*, frame[header_size..], nonce(direction, counter)) catch return null;
        if (counter > s.newest) {
            const ahead = counter - s.newest;
            s.seen = if (ahead >= 64) 1 else s.seen << @intCast(ahead) | 1;
            s.newest = counter;
        } else s.seen |= @as(u64, 1) << @intCast(s.newest - counter);
        return frame;
    }

    /// The counter's mask: the start of an AES block of the start of the sealed header.
    pub fn maskOf(s: *const Session, sealed: *const [16]u8) u64 {
        var block: [16]u8 = undefined;
        s.mask.encrypt(&block, sealed);
        return std.mem.readInt(u64, block[0..8], .little);
    }

    fn nonce(direction: Direction, counter: u64) [12]u8 {
        var n: [12]u8 = @splat(0);
        n[0] = @backingInt(direction);
        std.mem.writeInt(u64, n[4..12], counter, .little);
        return n;
    }
};

pub fn idOf(datagram: []const u8) ?u64 {
    return if (datagram.len >= prefix + header_size) std.mem.readInt(u64, datagram[0..8], .little) else null;
}

/// The loop of the connection a datagram's for, from its ID.
pub fn loopOf(id: u64) u8 {
    return @truncate(id >> 56);
}

pub fn slotOf(id: u64) u32 {
    return @truncate(id);
}

const testing = std.testing;

test "the GCM here is the standard library's, byte for byte" {
    var key: [16]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i * 7 + 1);
    const gcm: Gcm = .init(key);
    var plain: [header_size]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @intCast(i);
    // Bodies either side of each run of 8 blocks, up to the largest a datagram carries.
    for ([_]usize{ 0, 1, 15, 16, 64, 80, 81, 92, 96, 97, 112, 113, 333, 1328, 1343, 1344 }) |ad_len| {
        var ad: [1400]u8 = undefined;
        for (ad[0..ad_len], 0..) |*b, i| b.* = @truncate(i * 13);
        const nonce: [12]u8 = .{ 1, 0, 0, 0, 9, 8, 7, 6, 5, 4, 3, 2 };
        var ours: [header_size]u8 = undefined;
        const our_tag = gcm.seal(&ours, &plain, ad[0..ad_len], nonce);
        var theirs: [header_size]u8 = undefined;
        var their_tag: [16]u8 = undefined;
        std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(&theirs, &their_tag, &plain, ad[0..ad_len], nonce, key);
        try testing.expectEqualSlices(u8, &theirs, &ours);
        try testing.expectEqualSlices(u8, &their_tag, &our_tag);
        var back: [header_size]u8 = undefined;
        try gcm.open(&back, &ours, our_tag, ad[0..ad_len], nonce);
        try testing.expectEqualSlices(u8, &plain, &back);
    }
}

test "a datagram opens once, for its own session, unaltered" {
    var ticket: Ticket = .{ .id = 7, .key = @splat(1), .mask_key = @splat(2), .port = 8787 };
    var client: Session = .init(ticket);
    var relay: Session = .init(ticket);
    var frame: [header_size + 5]u8 = @splat(9);
    @memcpy(frame[header_size..], "hello");
    var out: [max_datagram]u8 = undefined;
    const datagram = client.seal(.to_relay, &frame, &out);
    var copy: [max_datagram]u8 = undefined;
    @memcpy(copy[0..datagram.len], datagram);
    try testing.expectEqualSlices(u8, &frame, relay.open(.to_relay, datagram).?);
    // The same again is a replay.
    try testing.expectEqual(null, relay.open(.to_relay, copy[0..datagram.len]));
    // Altered in its counter, tag, header or body, or for the other direction, or another key: dropped, and the
    // window doesn't move. (The ID isn't sealed: it only finds the session, and another's key won't open it.)
    for ([_]usize{ 9, 20, prefix + 3, prefix + header_size + 2 }) |at| {
        const altered = client.seal(.to_relay, &frame, &out);
        altered[at] ^= 1;
        const newest = relay.newest;
        try testing.expectEqual(null, relay.open(.to_relay, altered));
        try testing.expectEqual(newest, relay.newest);
    }
    try testing.expectEqual(null, relay.open(.to_client, client.seal(.to_relay, &frame, &out)));
    ticket.key[0] = 0;
    var stranger: Session = .init(ticket);
    try testing.expectEqual(null, stranger.open(.to_relay, client.seal(.to_relay, &frame, &out)));
    // Out of order within the window is fine, once; too far behind isn't.
    var a: [max_datagram]u8 = undefined;
    var b: [max_datagram]u8 = undefined;
    const first = client.seal(.to_relay, &frame, &a);
    for (0..10) |_| _ = client.seal(.to_relay, &frame, &out);
    const later = client.seal(.to_relay, &frame, &b);
    try testing.expect(relay.open(.to_relay, later) != null);
    try testing.expect(relay.open(.to_relay, first) != null);
    var old: [max_datagram]u8 = undefined;
    const stale = client.seal(.to_relay, &frame, &old);
    for (0..70) |_| _ = relay.open(.to_relay, client.seal(.to_relay, &frame, &out));
    try testing.expectEqual(null, relay.open(.to_relay, stale));
}

test "a ticket reads back as written" {
    const ticket: Ticket = .{ .id = 0x0300_00ab_0000_0042, .key = @splat(5), .mask_key = @splat(6), .port = 443 };
    var bytes: [ticket_size]u8 = undefined;
    ticket.write(&bytes);
    try testing.expectEqualDeep(ticket, Ticket.read(&bytes));
    try testing.expectEqual(3, loopOf(ticket.id));
    try testing.expectEqual(0x42, slotOf(ticket.id));
}

/// The datagram the Swift client's tests check against (JoineryTests, "a datagram matches the relay's").
pub const vector = struct {
    pub const ticket: Ticket = .{ .id = 0x0100_0000_1234_0005, .key = blk: {
        var k: [16]u8 = undefined;
        for (&k, 0..) |*b, i| b.* = @intCast(i);
        break :blk k;
    }, .mask_key = blk: {
        var k: [16]u8 = undefined;
        for (&k, 0..) |*b, i| b.* = @intCast(0xf0 + i);
        break :blk k;
    }, .port = 8787 };
    /// A presence frame: kind 7, a 4-byte body, seq 3, peer 2.
    pub const frame = [_]u8{ 1, 7, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef };
};

test "the shared vector, sealed to the client, as the second datagram" {
    var s: Session = .init(vector.ticket);
    var out: [max_datagram]u8 = undefined;
    _ = s.seal(.to_client, &vector.frame, &out);
    const datagram = s.seal(.to_client, &vector.frame, &out);
    var hex: [2 * (prefix + vector.frame.len)]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{datagram}) catch unreachable;
    // Printed for the Swift test to hold; it must never change, or old clients and new relays stop agreeing.
    try testing.expectEqualStrings(expected_vector_hex, &hex);
}

const expected_vector_hex = "0500341200000001ac37f6a85e0d947a594da54bf1364c12336faebebc052a7c13b0cb923de3bbe9f3ebd7e80706174b5c90772267329bdadeadbeef";
