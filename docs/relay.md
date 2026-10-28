# Hosted sharing: a relay that never reads the model

Status: proposal. Nothing here is built yet.

We will replace local sharing and tunnels with a hosted relay, so anyone can share with one click. The sharing Mac stays the authority on the data model,
exactly as in [collaboration.md](collaboration.md). The relay forwards guests' changes to the host, keeps the host's
published changes in a bounded log, and sends those same bytes to every guest. It never decodes a change: bodies are
end-to-end encrypted with a key the relay never sees, and the relay reads only a fixed 24-byte header. Because it reads
nothing else, it can be written in Zig with each room's memory allocated once, when the room is made.

This supersedes the transport in collaboration.md: the Mac no longer listens on a port, and nobody runs a tunnel. The
rules that make every copy right, a single authority that numbers changes and guests that resync on any gap, carry over
unchanged. What's new is the hop through the relay, a binary framing, encryption, and compaction of the log.

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

**The host starts every connection with a snapshot.** Its `hello`, asking for a room or for its room back, is followed
at once by the document as it is now, numbered with its latest decision. So a host that loses its connection never has
to work out which of its decisions reached the relay: it carries on numbering while away, and the snapshot it sends on
coming back covers everything. If the snapshot is past what the relay has, the relay can't catch anyone up across the
gap, so it starts its log again from the snapshot and sends the snapshot to every guest.

**Guests send their pending changes again** after every `welcome`, and whenever the host comes back (`joined` from
peer 1). While the host's away, the relay drops guests' changes. The host takes a change only when its `cseq` is one
past the last it took from that guest, and ignores anything else: a change it's taken already, or one after a gap,
which the guest will send again in order. Snapshots carry the last change taken from each guest, so a guest catching
up from one drops its pending changes the snapshot already covers.

Presence (pointers and selections) isn't logged. The relay keeps the latest presence per peer in a fixed slot,
overwrites it on each update, and sends it on when the socket has room. A dropped pointer update costs nothing; the
next one replaces it.

## Limits

The relay's limits are part of the protocol. Its reply to `hello` carries them: the largest frame, the largest
snapshot, the log size and the most people in a room. Clients check against them before sending, so a change the relay
would refuse never leaves the Mac:

- **The host** won't start sharing a model whose encrypted snapshot is over the snapshot limit, and says why.
- **Anyone editing** gets a change refused locally if its encrypted frame would be over the frame limit, with the same
  message the host would give for any other change it turns down. The editor takes it back, as it does now.
- **The relay** still enforces every limit, and closes a connection that sends past one. A client that checks first
  never sees that.

Encryption adds 28 bytes and the header 24, so clients check the size of the finished frame, not of the ops.

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

Sealed bodies are those only clients read: `ops`, `reject`, `change`, `snapshot` and `presence`. `hello`, `ping`,
`pong`, `joined`, `left` and `bye` stay plain, as the relay reads or writes them. Nonces are random, which is safe far
past any room's life. `Joinery/Collaboration/Protocol/Seal.swift` implements it. A frame that doesn't open is treated
like one that doesn't parse: the host turns the change down, and a guest reconnects. A snapshot that doesn't open
means the link's key is wrong, so the guest stops and says to check the link, instead of retrying forever.

Inside the encryption, a change is a list of ops in a compact binary form: entity IDs as 16 raw bytes, field names as
one-byte codes, values tagged by type, strings length-prefixed. The appendix has the exact encoding;
`Joinery/Collaboration/Protocol/Wire.swift` implements it. Measured on the examples, a whole model is 34–35% of its JSON
size (Sakila: 26,719 bytes as JSON, 9,475 binary), and renaming a table is 28 bytes against 90. Encryption adds 28
bytes, the header 24 and WebSocket framing 2 to 4, so on small frames the framing outweighs the ops.

### Zero copy on the relay

Server-to-client WebSocket frames aren't masked, so the relay stores each host frame in the log with its WebSocket
header already built. Sending a frame to a guest is a write of bytes already in the log, with no copy per guest. A
guest catching up is the same write starting further back.

Client-to-server frames are masked, as browsers require. The relay unmasks each one once, in place, as it's read: host
frames straight into the log, guest frames into the room's inbox for the host. That's the only pass the relay makes
over a body.

On Linux the relay sends with io_uring and zero-copy sends. Each room's block is registered with io_uring when the
room is made, so every send is a pointer into memory that's already registered.

**As built in step 4, the relay is one step short of this.** Each connection has an outbox, and the relay's sends append
to it, a copy per guest, which the connection's writer task then sends. That keeps the relay simple and a slow
connection from holding up anyone else: the relay never waits on a socket, and a connection whose outbox fills is too
far behind and is closed, to come back by the snapshot route. The outbox holds a joiner's whole catch-up (snapshot and
log, twice over for WebSocket headers); its memory is only touched as it's used. Per-guest cursors into the log, as
above, would remove the copy and the outbox, and are the next step if the copy shows up in measurements. Guest frames
go straight to the host's outbox, so there's no inbox. The std library's WebSocket unmasks each frame in place as it's
read, the one pass over a body.

## The log and compaction

Each room's log is a ring buffer of frames, ready to send, plus a snapshot: the whole model as of some change N,
encrypted by the host like any body.

**Every connected guest is a cursor into the ring.** Its cursor is the next byte to send it. Sending live changes and
catching up are the same operation, so there are no per-guest queues.

**The ring keeps everything back to the older of two points:**
- the latest snapshot, so a new joiner can load it and replay from there;
- the oldest connected guest's last applied change, from its pings.

**When a new frame doesn't fit,** the relay drops the guest holding the tail back and trims. If what's left is all past
the snapshot, nothing can go, so the relay drops the host instead, which comes straight back with a new snapshot. That guest reconnects and
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

## Memory: allocated once per room

Each room's memory is allocated in one block when the room is made, and freed when it ends. Nothing inside a room
allocates after that: its log, snapshots, inbox and people all live in that block, and when one is full the relay
applies the rules above (drop the lagging guest, stop reading, turn the newcomer away) instead of growing. With no
rooms, the relay holds only its listening socket. The number of rooms is limited only by the machine, plus an optional
cap in configuration.

Every room's block is the same size, so a freed block is reused for the next room as is, and memory doesn't fragment
however rooms come and go.

As built, a room is a few allocations made together, not one block: the log ring, which is the log limit plus the
largest frame (3 MiB) so a frame always fits whole without splitting at the ring's end (`relay/src/Log.zig` has the
proof); one snapshot slot (1 MiB), since sends copy the snapshot out at once and no guest is ever partway through
reading it; 31 guest slots; and 1,024 remembered clients (72 KiB), each keeping its peer for the room's life, after
which new clients are turned away as if the room were full. The large buffers (a room's log and snapshot, a connection's read
buffer and outbox) are taken without Zig's fill: in Debug and ReleaseSafe builds `Allocator.alloc` writes a pattern
over new memory, which made every buffer resident at once, about 13 MiB a connection. Measured on a ReleaseSafe build
with one room, a host and a guest, a 10 KB snapshot and 199 changes, the whole relay is 2.0 MB. A room's ID and secrets are kept as they are, not hashed,
because the host gets its secrets back when it resumes. They're compared in constant time.

Per room, with the defaults we'd start from:

| Part | Size |
| --- | --- |
| Log ring | 2 MiB |
| Snapshot slots | 2 × 1 MiB |
| Inbox, guest changes waiting for the host | 256 KiB |
| Peers, 32 × (connection state, presence slot) | 32 × 2 KiB = 64 KiB |
| Total | about 4.3 MiB |

1,024 rooms at once is about 4.4 GiB, which fits a modest server. The largest frame is 1 MiB, which a single paste of a few
hundred tables stays well under. The largest model is the snapshot slot, 1 MiB encrypted, which holds Sakila, the
largest example at 24 KB, about 40 times over.

Frames are read straight into the room's block, with no buffer in between. A frame's header gives its length, so the
relay reserves that much in the ring (from the host) or the inbox (from a guest) and reads the body into it, unmasking
as it goes. Two guests sending at once get two reservations. A connection that hasn't joined a room yet has only a 4 KiB
buffer for its `hello`, freed once it joins.

When the inbox can't fit a guest's next frame, the relay stops reading from that guest until the host catches up. TCP
then slows the guest down, and nothing grows.

## Why every copy is right

The argument in [collaboration.md](collaboration.md#why-every-copy-is-right) carries over, with the host's decisions in
place of its changes: a guest's copy is always `D(seq)`, each of its changes is decided at most once (the host takes
`cseq` only one past the last), and at least once (it's sent again on every `welcome` and every return of the host,
until a decision on it arrives, by the log or covered by a snapshot). The relay only delays, drops and replays the
host's frames in order, which is what a network does.

`JoineryTests/RelaySimulation.swift` checks it the same way, with a real `RelayCore` between the host and guests. It
cuts connections partway, the host's included, and most runs use logs of 1.5 to 6 KB, so snapshots, dropped guests and
dropped hosts happen constantly: across 60 runs, 183 snapshot requests, 92 guests dropped for lagging, 39 hosts dropped
for a full log, 300 catch-ups from a snapshot and 42 from the log. 400 runs go with every test run; 3,000 longer ones
passed while it was written. Unlike the first simulation, nothing is lost, repeated or garbled on a connection that
stays up: TCP rules that out, and encryption turns a garbled frame into a refused one, which ends the connection like
a cut. The simulation runs with encryption on, so every frame in it is sealed and opened.

The simulation found one bug, in both protocols: a change that leaves something dangling was published with the
digest from after the host's tidying, not before it. Locally, guests fetched the whole model again each time and
recovered; through the relay they caught up from the same frame forever. Each decision now carries the digest right
after it.

## Versions

There are two version numbers, because there are two readers.

**The wire version** is the header's first byte, and it's the only one the relay reads. It covers the header's layout
and the kinds of message. The relay accepts every wire version it knows and treats bodies the same in all of them, so
a relay doesn't change when the app does. If the relay doesn't know a client's wire version, its `hello` reply says
which ones it speaks, and the app says that relay needs updating.

**The room version** covers everything inside the encryption: the ops encoding, the model's fields and what they
mean. A room's version is its host's, because the host is the authority. The host puts it in the room's info, which
the relay stores without reading and hands to each guest with its limits. Then:

- **A guest that knows the room's version joins,** and reads and writes that version's bytes, even if it knows newer
  ones. Each app speaks its own version and the ones before it, back to a floor we raise rarely.
- **A guest older than the room** can't join, and says "This session needs a newer Joinery". Sparkle makes updating one
  click, and released copies usually update before it matters.
- **A guest newer than the room but past its floor** can't join either, and says the host needs a newer Joinery.

Most changes don't need a new room version:

- **A new field** is written by name (field code 0), which every version already reads and keeps, until the room
  version that gives it a code. An old client keeps a field it doesn't understand, and since edits are per field, it
  doesn't drop the field when it changes another one. This is why each room version has its own field table: an
  encoder uses only the codes its room's version knows, because an older reader can't turn a code it's never seen
  back into a name.
- **A new kind of entity, a changed meaning, or a changed encoding** needs a new room version.

(There was a web client, served by the relay, which would have had to speak every room version hosts still use. It's
gone: every guest is a Joinery.)



Sharing starts with the host's `hello` asking for a room. The relay makes one and replies with its ID, its limits, and
the host, guest and view secrets. The host makes the room key itself and never sends it to
the relay. The links it hands out look like this:

```
https://<relay>/r/<room>#key=<room key>&token=<guest secret>
```

- **The room key** (256 bits) encrypts bodies. It's after the `#`, so browsers never send it, and the relay never
  learns it.
- **The guest secret** (128 bits) lets the relay admit a connection. It's also after the `#`, and the client sends it in
  `hello` over the WebSocket, so it never appears in a URL the server logs.
- **The host secret** never leaves the host. Neither does the room key, except in the links the host hands out.
- **A view link** carries a view secret instead of the guest secret. The relay accepts its connections but refuses
  their `change` frames.

Anyone with a link can read and edit for as long as the room lasts. There's no revoking one link. To cut someone off,
the host stops sharing and shares again, which makes a new room with new secrets.

## Abuse

Out of scope for now. Cloudflare, in front of the relay, rate-limits by IP. Encryption means the relay can't see what's
stored, so if abuse needs more than rate limits it will be by volume, not content.

TLS ends at Cloudflare; Zig's standard library has no TLS server. Cloudflare sees only the encrypted bodies.

## What happens to local sharing

It goes. The relay replaces the Mac's listening port, the tunnel and the share panel's address field: Share connects
out to a relay and gets links back. The app keeps one session protocol.

`RelayCore`, a Swift version of the relay that's pure like `HostCore` and `ClientCore`, still gets written. It's what
the simulation runs and what the Zig relay is checked against byte for byte, but it doesn't ship.

As of step 5, it's gone: `HostCore`, `ClientCore`, the JSON messages, the Mac's port and the tunnel instructions are
removed. `RelayCore` also serves the app's own tests, behind real sockets in the test process (`JoineryTests/TestRelay.swift`),
so the app's sessions are tested end to end without the Zig binary.

### Bringing your own relay

Settings has a Relay field: our hosted relay by default, or the address of one you run. Share, and the MCP
`start_sharing` tool, use whichever is set. Links name their relay, so guests reach the right one without setting
anything.

The relay ships as one static binary with no configuration it can't start without. Running your own isn't about
privacy, since no relay can read a model, but about control: keeping sessions on your own network, sharing between Macs
with no internet, or not depending on our server. It also takes back the main cost of dropping local sharing.

The relay's `hello` reply carries the protocol version it speaks. If it doesn't speak the app's, Share says so and
names both versions, rather than failing partway through a session.

## Measuring the relay

The relay is only worth writing in Zig if it stays small and fast, so it's measured from its first commit, not tuned at
the end. Three tools, all in the relay's repository, all run by one command:

- **Micro-benchmarks** (`zig build bench`) for each step a frame takes: reading a header, unmasking, reserving and
  appending to the log, building the sends for a room. Each reports time per frame and bytes allocated, which must be
  zero.
- **A load generator** that runs thousands of simulated rooms against a real relay, each with a host and guests
  editing at a set rate, and reports the time from the host's send to each guest's receive (median and 99th
  percentile), frames per second, CPU time per frame, system calls per frame, and the relay's memory against rooms ×
  block size.
- **A no-allocation check.** Tests run the relay with an allocator that fails on any allocation after a room's block,
  so a stray allocation fails the build instead of showing up later as a slow percentile.

Results go in the repository with the commit that produced them, and the bench command compares against the last
ones. A change that makes the median or the 99th percentile more than 10% worse, or adds an allocation, a copy or a
system call per frame, has to say why in its commit. Timing is only compared on one machine; the counts (allocations,
copies, system calls) are compared everywhere.

We don't have targets yet beyond the counts: zero allocations and one pass over each body (the unmask) per frame. The
first load runs set the timing baseline, and we'll write targets down then rather than guess them now.

As of step 4, two of the three exist. `zig build bench` times reading a header, appending to the log, a host's change
going to 31 guests and a guest's change going to the host, and fails if any of them allocates; `relay/bench/results.txt`
has the numbers with the commit they're from (the relay handles a host's change for 31 guests in about 44 ns on an
M-series Mac, before the copies into their outboxes). The no-allocation check is in the replay test: the relay
allocates on an event only when the event makes a room.
The load generator, and comparing against the last results automatically, come with step 5, when there's an app to
generate load from.

## Downsides

- **The host must stay online.** That's the design, but it rules out sharing a model and closing the laptop.
- **Guests' changes take one more trip** than a relay that decided for itself.
- **The relay can't help with anything that needs the model:** history, search, previews, checking changes. All of it
  has to happen on clients.
- **Fixed room sizes mean hard limits.** A model bigger than the snapshot slot can't be shared at all, and with local
  sharing gone there's no other way to share it. The host checks before sharing and says so plainly.
- **Sharing needs a relay,** even between two Macs on one desk. Without the internet, that means running one
  yourself.
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
4. **The Zig relay,** checked by replaying frames recorded from the Swift simulation and comparing what it sends,
   byte for byte, with what `RelayCore` sent. Benchmarks and the no-allocation check land with the first code, and
   every later step runs them. Done: `relay/`, with its own README. `scripts/record-relay-traces.sh` records the traces
   again after a protocol change. Comparing is connection by connection: on each, the same bytes in the same order.
   Across connections, order can't matter to anyone. Porting it changed the Swift reference in three small ways, so
   that fixed space can hold what it keeps: clients, names and titles have length limits, a room remembers at most
   1,024 clients, and a host's goodbye is passed on as its bytes rather than re-read as text.
5. **The app on the relay:** Share connects out to the relay set in Settings, the local port and the tunnel
   instructions go, and two copies of the app plus a browser share through a locally run relay. Done. Details settled
   on the way:
   - **Presence** (pointers and selections) is a sealed `presence` frame: a cursor, if any, as two f64s, then the
     selected IDs. The relay stamps who it's from. Names come from `joined`, and colors from the peer number (the host
     is blue), so neither is sent.
   - **View links** carry `view=` in place of `token=`. A change made on one is taken back at once, with a note, and
     never sent.
   - **Limits** are checked before sending: a host whose snapshot is over the relay's limit stops sharing and says so;
     a guest's change over the frame limit is taken back.
   - **The web client** was ported to the relay (a port of `RelayGuestCore`, with WebCrypto) and then removed: every
     guest is a Joinery. A link opened in a browser is told to paste it into Join. It's in git at `dc52670`, if it comes
     back.
   - **The default relay** is `https://relay.joinery.clarkmccauley.com`, which step 6 deploys. Until then, Settings ▸
     Sharing points the app at another, such as `http://localhost:8787`.
6. **Deployment** behind Cloudflare.

## Open questions

- **How big can a model get?** We haven't measured an encrypted snapshot of a 1,000-table model. If it's over 1 MiB,
  the snapshot slot grows or snapshots go in chunks; we'll measure in step 1.
- **How long should a host's absence last before the room ends?** 30 seconds covers a network change, but not a laptop
  lid closing. We'll revisit this after using it.
- **Is a 2 MiB ring the right default?** It's sized by guessing at heavy editing. Step 2's simulation should tell us how
  often guests get dropped at that size.

## Appendix: the ops encoding

All integers are little-endian. A *varint* is unsigned LEB128, at most 10 bytes. A *string* is a varint byte count
then UTF-8.

```
ops     = varint count, then count × op
op      = 1 (put)    varint field-count, then field-count × (field, value)
        | 2 (set)    value (the ID), field, value
        | 3 (delete) value (the ID)
field   = a byte 1–23, a code from the table below
        | 0, then the name as a string
value   = 0 null | 1 false | 2 true
        | 3, then 8 bytes: an IEEE 754 double
        | 4, then a string
        | 5, then 16 bytes: a UUID, read back as uppercase text
        | 6, then varint count, then count × value          (an array)
        | 7, then varint count, then count × (string, value) (an object)
```

Field codes, never reused or renumbered: 1 id, 2 kind, 3 order, 4 name, 5 position, 6 color, 7 group, 8 notes,
9 samples, 10 table, 11 type, 12 isPrimaryKey, 13 isNullable, 14 isUnique, 15 from, 16 to, 17 zipTies, 18 direction,
19 heldDirection, 20 relationships, 21 column, 22 side, 23 along.

To make the same ops give the same bytes everywhere:
- A string is written as tag 5 only if it's exactly an uppercase UUID, `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` in
  `0-9A-F`, so it reads back as the same text. Anything else, a lowercase UUID included, is tag 4.
- A put's fields and an object's keys are written sorted by UTF-16 code units, as JavaScript's `sort` orders them.
- Numbers are always 8-byte doubles, so they read back exactly.

Readers check every count against the bytes left, limit nesting to 32 levels, and reject bytes after the last op, so
damaged input is refused rather than read past its end.

