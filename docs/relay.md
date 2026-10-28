# Hosted sharing: a relay that never reads the model

Status: proposal. Nothing here is built yet.

We will add a hosted relay so anyone can share without a tunnel. The sharing Mac stays the authority on the data model,
exactly as in [collaboration.md](collaboration.md). The relay forwards guests' changes to the host, keeps the host's
published changes in a bounded log, and sends those same bytes to every guest. It never decodes a change: bodies are
end-to-end encrypted with a key the relay never sees, and the relay reads only a fixed 24-byte header. Because it reads
nothing else, it can be written in Zig with every byte of memory allocated at startup.

This extends the protocol in collaboration.md rather than replacing it. The rules that make every copy right, a single
authority that numbers changes and guests that resync on any gap, carry over unchanged. What's new is the hop through
the relay, a binary framing, encryption, and compaction of the log.

## Why the host stays the authority

The alternative is a relay that orders changes itself, with every client applying the same checks in the same order.
We're not doing that, for three reasons:

- **Sharing is remote access.** A session exists while its host is sharing, and the host's copy is the one that's
  saved. A relay that could carry on without the host would make the host's copy one copy among many.
- **The rules stay in one place.** Turning a change down (one that touches something just deleted, say) is decided by
  `Replica.receive`, in Swift, on the host. Without a host, every client, the web client included, would have to
  reach the same decision for every change forever, and any difference would fork the copies.
- **The proof carries over.** "Why every copy is right" in collaboration.md depends on one numbering authority. With
  the host still numbering, the relay is just a network between host and guests, one that can delay, cut and
  reorder connections, which the simulation already covers.

The cost is one extra trip. A guest's change goes guest → relay → host → relay → everyone, where a relay that decided
for itself would answer from the middle. The author doesn't feel it, because guests show their own changes as soon as
they make them. Everyone else sees them about one round trip later than they could have.

## Roles and flow

```
 guest ──change──▶ relay ──change, stamped with sender──▶ host
                                                          │ checks it, numbers it
 guest ◀──ops (same bytes to all)── relay ◀──ops, seq N───┘
                                    │
                                    └─ appends to the room's log
```

- **The host** connects with the room's host secret. Only this connection may publish numbered frames.
- **Guests** connect with a guest secret, or a view secret that the relay doesn't let send changes.
- **The relay** checks secrets, stamps each guest frame with its sender's peer ID, passes it to the host, and appends
  each host frame to the log and sends it on.

The host now publishes its rejections as numbered frames too, not as replies to one guest. Every decision the host
makes is then in the ordered log, so a guest learns what happened to its change by reading the log, the same way
whether it was connected, reconnecting, or catching up from a snapshot. This replaces `welcome`'s `acked` field and the
pong check for lost answers: a lost answer is now a gap in the numbering, which guests already detect. A rejection
changes nothing in the model, so its digest is the one before it.

Presence (pointers and selections) isn't logged. The relay keeps the latest presence per peer in a fixed slot,
overwrites it on each update, and sends it on when the socket has room. A dropped pointer update costs nothing; the
next one replaces it.

## Frames

Every message is one WebSocket binary message. Browsers can only speak WebSocket, so the relay speaks it too.

```
offset size  field
0      1     version     1
1      1     type        hello, ops, reject, change, snapshot, snapshot-request, presence, ping, pong, joined, left, bye
2      2     flags
4      4     body length bytes after the header, at most the relay's maximum frame
8      8     seq         host frames: this change's number. ping: the sender's last applied change. change: its cseq.
16     4     peer        guest frames: the sender, stamped by the relay. 0 otherwise.
20     4     reserved    0
24     …     body        12-byte nonce, AES-256-GCM ciphertext, 16-byte tag
```

All integers are little-endian. The header is 8-byte aligned, so the relay reads it in place.

The body is encrypted with the room key, using the header as additional authenticated data with `peer` zeroed (the
relay writes `peer`). So the relay can't read bodies, can't move a body to a different `seq` without the guest
noticing, and can't forge a change from the host. It can still withhold or delay frames. Guests detect withholding as a
gap or a stale `pong`, as they do now.

Inside the encryption, a change is a list of ops in a compact binary form: entity IDs as 16 raw bytes, field names as
one-byte codes, values tagged by type, strings length-prefixed. Clients read strings where they lie in the buffer. The
exact encoding goes in an appendix once the Swift side settles it. To give a sense of size: renaming a table is about
75 bytes of JSON today and about 30 bytes of ops in binary, plus 28 bytes of nonce and tag, 24 of header and 2 to 4 of
WebSocket framing. On small frames the framing outweighs the ops.

### Zero copy on the relay

Server-to-client WebSocket frames aren't masked, so the relay stores each host frame in the log with its WebSocket
header already built. Sending a frame to a guest is a write of bytes already in the log, with no copy per guest. A
guest catching up is the same write starting further back.

Client-to-server frames are masked, as browsers require. The relay unmasks each one once, in place, as it's read: host
frames straight into the log, guest frames into the room's inbox for the host. That's the only pass the relay makes
over a body.

On Linux the relay sends with io_uring and zero-copy sends from registered buffers. Every send is a pointer into
memory that was allocated at startup.

## The log and compaction

Each room's log is a ring buffer of frames, ready to send, plus a snapshot: the whole model as of some change N,
encrypted by the host like any body.

**Every connected guest is a cursor into the ring.** Its cursor is the next byte to send it. Sending live changes and
catching up are the same operation, so there are no per-guest queues.

**The ring keeps everything back to the older of two points:**
- the latest snapshot, so a new joiner can load it and replay from there;
- the oldest connected guest's last applied change, from its pings.

**When a new frame doesn't fit,** the relay drops the guest holding the tail back and trims. That guest reconnects and
catches up from the snapshot, like a new joiner. A guest on a slow network falls behind, becomes the oldest, and is
dropped, so one slow guest can't make the relay buffer without limit. The ring has to hold more than one ping interval
(10 s) of changes, or a healthy guest could be dropped between two of its own pings; ring size is set in bytes, which
covers that with room to spare.

**Snapshots come from the host.** When the ring is half full, the relay sends `snapshot-request`. The host replies with
the model as of its latest change, numbered and with its digest. The relay keeps two snapshot slots: guests still
reading the old one finish it while the new one is written. When the new one is complete, frames before it can go once
no cursor needs them.

**Joining is:** the latest snapshot, then the ring from the change after it. **Reconnecting is:** the ring from the
guest's last change if that's still kept, the snapshot route if not. Either way the guest checks the digest at the
end, as `welcome` is checked today.

## Memory: allocated once

The relay allocates everything at startup and never again. Limits come from configuration, and when a pool is
exhausted the relay turns the newcomer away instead of growing.

Per room, with the defaults we'd start from:

| Part | Size |
| --- | --- |
| Log ring | 2 MiB |
| Snapshot slots | 2 × 1 MiB |
| Inbox, guest changes waiting for the host | 256 KiB |
| Peers, 32 × (connection state, presence slot) | 32 × 2 KiB = 64 KiB |
| Total | about 4.3 MiB |

1,024 rooms is about 4.4 GiB, which fits a modest server. The largest frame is 1 MiB, which a single paste of a few
hundred tables stays well under. The largest model is the snapshot slot, 1 MiB encrypted, which holds Sakila, the
largest example at 24 KB, about 40 times over.

Connections are a fixed pool across rooms, each with a fixed receive buffer that only holds a frame until it's
unmasked into the ring or the inbox. When the inbox is full, the relay stops reading from that room's guests until the
host catches up. TCP then slows the guests down, and nothing grows.

## Links and secrets

```
https://<relay>/r/<room>#key=<room key>&token=<guest secret>
```

- **The room key** (256 bits) encrypts bodies. It's after the `#`, so browsers never send it, and the relay never
  learns it.
- **The guest secret** (128 bits) lets the relay admit a connection. It's also after the `#`, and the client sends it in
  `hello` over the WebSocket, so it never appears in a URL the server logs. The relay stores only a hash of it.
- **The host secret** never leaves the host. Neither does the room key, except in the links the host hands out.
- **A view link** carries a view secret instead of the guest secret. The relay accepts its connections but refuses
  their `change` frames.

Anyone with a link can read and edit for as long as the room lasts. There's no revoking one link. To cut someone off,
the host stops sharing and shares again, which makes a new room with new secrets.

## Abuse

Anyone can create a room, which is the main abuse risk. To start with, the relay limits rooms per IP, connections per
IP and room, frames per second per connection, and frame size, and closes rooms whose host has been gone for 30
seconds. Encryption means the relay can't see what's being stored. That's the point, but it also means abuse can't be
filtered by content, only by volume.

TLS ends at Cloudflare in front of the relay; Zig's standard library has no TLS server. Cloudflare sees only the
encrypted bodies.

## Local sharing

The Mac's own sharing moves to the same protocol: the app runs a Swift version of the relay (`RelayCore`, pure like
`HostCore` and `ClientCore`) on the local port, with the host as a client of it. There's then one protocol, one web
client and one simulation, whether a session is hosted or tunneled. The Swift relay doesn't need static allocation;
it's the reference the Zig one is tested against.

## Downsides

- **The host must stay online.** That's the design, but it rules out sharing a model and closing the laptop.
- **Guests' changes take one more trip** than a relay that decided for itself.
- **The relay can't help with anything that needs the model:** history, search, previews, checking changes. All of it
  has to happen on clients.
- **Static allocation means hard limits.** A model bigger than the snapshot slot can't be shared through the hosted
  relay at all, and the error has to say so plainly.
- **Zig hasn't reached 1.0.** Each new version can break the build, and we'll pay for that in small rewrites. If it
  costs more than it saves, Rust is the fallback; the protocol doesn't depend on the language.

## What this doesn't do

- No accounts. A link is the only credential.
- Nothing persists after the host stops sharing: the room, its log and snapshot are dropped.
- No offline editing beyond what guests do today (pending changes resent on reconnect).
- No change to the data model or to how the host checks changes.

## Plan

Each step ends with tests passing, and nothing goes in front of the Zig work that isn't proven in Swift first.

1. **Binary frames and op encoding in Swift,** with round-trip tests against the JSON form, and the web client
   decoding the same bytes.
2. **`RelayCore` and the host's side of it,** with rejections in the log. Prove it in `SessionSimulation`: the same
   faults as now, plus host disconnects, compaction under load, guests dropped for lagging, and joins from snapshots
   mid-stream. The invariants are the same: every guest's confirmed copy is `D(seq)` after every step; at the end,
   everyone has the host's copy and every change was taken exactly once.
3. **Encryption,** in Swift (CryptoKit) and the web client (WebCrypto), with each side decrypting the other's frames.
4. **Local sharing on `RelayCore`,** replacing the v1 path once the simulation and the two-app checks pass.
5. **The Zig relay,** checked by replaying frames recorded from the Swift simulation and comparing what it sends,
   byte for byte, with what `RelayCore` sent.
6. **Deployment** behind Cloudflare, with the limits above.

## Open questions

- **How big can a model get?** We haven't measured an encrypted snapshot of a 1,000-table model. If it's over 1 MiB,
  the snapshot slot grows or snapshots go in chunks; we'll measure in step 1.
- **Should room creation need sign-in?** Rate limits are enough until someone abuses them. If they do, rooms need an
  owner.
- **How long should a host's absence last before the room ends?** 30 seconds covers a network change, but not a laptop
  lid closing. We'll revisit this after using it.
- **Is a 2 MiB ring the right default?** It's sized by guessing at heavy editing. Step 2's simulation should tell us how
  often guests get dropped at that size.
