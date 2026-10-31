# Live sessions: the relay protocol

Joinery shares a data model live through a relay. One Mac, the **host**, holds the true copy and decides every change.
**Guests** send their changes through the relay to the host, and everyone gets the host's decisions back, in order. The
relay passes on bytes it can't read: bodies are end-to-end encrypted with a key only the links carry, and the relay
reads nothing but a fixed 24-byte header.

The app implements the clients (`Joinery/Collaboration/Protocol`), and `relay/` is the relay, in Zig. `RelayCore.swift`
is a Swift relay that doesn't ship: the app's simulation runs it, and the Zig relay must send the same bytes on every
connection when it replays what `RelayCore` heard (`relay/src/relay/replay_test.zig`).

## Why the host decides

A relay could order changes itself, with every client applying the same checks. It doesn't, for three reasons:

- **The host's copy is the one that's saved.** A session exists while its host shares; a relay that carried on without
  it would make the host's copy one among many.
- **The rules stay in one place.** Turning a change down (one touching something just deleted, say) is decided by
  `Replica.receive` on the host. Without a host, every client would have to reach the same decision forever, and any
  difference would fork the copies.
- **The proof is simpler.** With one numbering authority, the relay is only a network that can delay, cut and replay,
  and the argument below covers that.

It costs a trip: a guest's change goes guest → relay → host → relay → everyone. The author doesn't feel it, since a guest
shows its own changes at once; everyone else sees them a round trip later than they might.

## Links

Sharing starts with the host's `hello` asking for a room. The relay makes one and replies with its ID, its limits, and
the host, guest and view secrets. The host makes the room key itself and never sends it to the relay.

```
https://<relay>/r/<room>#key=<room key>&token=<guest secret>
```

- **The room key** (256 bits) encrypts bodies. It's after the `#`, so browsers never send it and the relay never sees it.
- **The guest secret** (128 bits) admits a connection. It's sent in `hello`, over the WebSocket, never in a URL a server
  logs.
- **A view link** carries `view=<view secret>` instead. The relay admits it but refuses its changes, and the app takes
  back a change made on one before sending it.
- **The host secret** never leaves the host. The relay compares secrets in constant time.

Anyone with a link can read, and edit unless it's a view link, for as long as the room lasts. There's no revoking one
link: to cut someone off, the host stops sharing and shares again, which makes a new room with new secrets.

## Roles and flow

```
 guest ──change──▶ relay ──change, stamped with sender──▶ host
                                                          │ checks it, numbers it
 guest ◀──ops (same bytes to all)── relay ◀──ops, seq N───┘
                                    │
                                    └─ appends to the room's log
```

- **The relay** checks secrets, stamps each guest frame with its sender's peer number, passes it to the host, and
  appends each host frame to the log and sends it on.
- **The host publishes every decision as a numbered frame:** a change made (`ops`) or turned down (`reject`), each with
  the digest of its copy after it. A guest learns what happened to its change by reading the log, the same way whether
  it was connected, reconnecting or catching up. A lost answer is a gap in the numbering, which guests detect.
- **The host starts every connection with a snapshot,** right after its `hello`, numbered with its latest decision. A host
  that loses its connection keeps numbering while away, and the snapshot it sends on coming back covers everything. If
  the snapshot is past what the relay has, the relay starts its log again from it and sends it to every guest.
- **Guests send their pending changes again** after every `welcome`, and whenever the host comes back. The host takes a
  change only when its `cseq` is one past the last it took from that guest; anything else is already taken, or comes
  after a gap and will be sent again in order. A snapshot carries the last change taken from each guest, so a guest
  catching up from one drops what it covers. While the host is away, the relay drops guests' changes.
- **Presence** (a pointer, a selection, a drag or a marquee) is a sealed `presence` frame, not logged. A connection
  that's behind holds only the newest from each person until its queue has gone, so it's sent where pointers are, not
  where they were. Names come from `joined`; colors come from the peer number, with the host (peer 1) blue.

The host has 30 seconds to come back before the room ends. A connection silent for 30 seconds is let go; clients ping
every 10.

## Frames

Every message is one binary WebSocket message: browsers speak only WebSocket, so the relay does too.

```
offset size  field
0      1     version     1
1      1     kind        hello, ops, reject, change, snapshot, snapshot-request, presence, ping, pong, joined, left, bye,
                         udp-ticket
2      2     flags
4      4     body length bytes after the header, at most the relay's largest frame
8      8     seq         host frames: this decision's number. ping: the sender's last applied. change: its cseq.
16     4     peer        guest frames: the sender, stamped by the relay. 0 otherwise.
20     4     reserved    0
24     …     body
```

Integers are little-endian, and the header is 8-byte aligned so the relay reads it in place.

**Sealed bodies** (`ops`, `reject`, `change`, `snapshot`, `presence`) are a 12-byte random nonce, AES-256-GCM ciphertext
and a 16-byte tag, sealed with the room key and the header as additional data, with `peer` zeroed since the relay
writes it (`Seal.swift`). The relay can't read a body, move it to another `seq`, or forge one; it can only withhold or
delay frames, which guests see as a gap or a stale `pong`. A frame that doesn't open is treated like one that doesn't
parse: the host turns the change down, and a guest reconnects. A snapshot that doesn't open means the link's key is
wrong, so the guest stops and says so. `hello`, `ping`, `pong`, `joined`, `left` and `bye` are plain, because the relay
reads or writes them.

**Presence carries its own order.** A `presence` frame's `seq` is the sender's count of the presence frames it has sent,
from 1, which receivers keep per peer, dropping any at or below the newest they've shown. Presence can reach a client by
two paths (below), so an older update can arrive after a newer one. A `seq` of 0 is always taken, as older clients send.

## Presence over UDP

Presence is nearly all of a session's traffic: in a room of four, each change is 3 frames out, and each second of
pointers moving is 45. TCP's work on every packet, much of it acknowledgements, is most of what a relay costs, and
presence doesn't need what TCP gives: a lost pointer update is replaced by the next. So a relay can carry presence as UDP
datagrams beside each connection's WebSocket. Everything else stays on the WebSocket, which is always there: where UDP
doesn't get through, as on many company networks, nothing changes.

**The ticket.** A relay started with `--udp on` sends each connection a `udp-ticket` frame after its welcome:

```
offset size  field
0      8     id          the connection's ID, which the relay finds it by; its last byte names the relay's loop
8      16    key         AES-128-GCM key for this connection's datagrams, both ways
24     16    mask key    AES-128 key that masks each datagram's counter
40     2     port        the relay's UDP port
42     …     host        where to send to, UTF-8, to the body's end: empty for the WebSocket's host
```

A client that doesn't want UDP ignores it, and the relay never sends one a datagram.

**A datagram**, either way, is a frame with its header sealed:

```
offset size  field
0      8     id          from the ticket
8      8     counter     masked
16     16    tag         AES-128-GCM's
32     24    header      the frame's header, sealed
56     …     body        the frame's body as it is (presence is already sealed with the room key)
```

The header is sealed with the ticket's key (AES-128, as QUIC and TLS use by default: presence is already sealed with the
room's AES-256 key, and this only keeps the header private and the datagram whole), the body authenticated alongside, with the nonce `direction, 0, 0, 0,
counter` (`direction` 0 to the relay, 1 to the client, the counter 8 bytes little-endian). Each side counts the datagrams
it sends from 1. The counter is masked as QUIC masks packet numbers: the first 8 bytes of AES-128 of the sealed header's
first 16, under the mask key, XORed over it. A receiver drops a datagram that doesn't open, one whose counter it has
taken, and one more than 64 behind the newest it has taken; only one that opens can move that window. A datagram is at
most 1,400 bytes.

**What goes over UDP:** `presence` both ways, and `udp-ticket` with an empty body as a probe. The relay answers each
probe with one of its own, the same size, so a probe proves the way back too and no one can make the relay send more
than it's sent. Anything else is dropped.

**The relay** sends a connection's datagrams to the address of the newest datagram from it that opened and was new, and
to none until one has. It never acts on one that doesn't open: a forgery can't move a connection, cost it anything, or
end it. It sends a connection's presence by WebSocket instead once it hasn't heard from it over UDP for 20 seconds, or
when the client sends `udp-ticket` with an empty body over its WebSocket, which says "send me nothing more by UDP".
Datagrams the socket won't take are dropped, as newer presence follows.

**The client**, for each WebSocket connection:

| State | Presence goes by | Leaves when |
| --- | --- | --- |
| off: no ticket, or UDP turned off here | WebSocket | a ticket comes: probing |
| probing | WebSocket | an answer to a probe comes: up. Probes at 0, 0.25, 0.5, 1, 2 and 4 s get none: down |
| up | UDP | nothing's heard by UDP for 15 s: down, saying so over the WebSocket. Idle 5 s, it probes |
| down | WebSocket | after 30 s, doubling to 5 minutes: probing again, on the same ticket |

A WebSocket that drops takes its ticket with it: the client closes its UDP socket, and the next connection brings a new
ticket. A path that changes address mid-session, as a NAT's can, mends itself: the relay follows the newest genuine
datagram.

**Deploying.** UDP needs to reach the relay itself, not an HTTP ingress: a layer-4 load balancer on the UDP port, which
can be 443 beside HTTPS's. `--udp-port` is the port to put in tickets when it isn't the port the relay listens on, and
`--udp-host` the name, when UDP's load balancer isn't at the WebSocket's address. On
Linux every loop shares the port, and the kernel hands each datagram to its connection's loop by the ID's last byte;
elsewhere (a relay on a Mac, for development) each loop takes a port of its own, the relay's port and those after it,
and its tickets name it.

## The model and its ops

A data model is a flat map of **entities**, keyed by ID. Each has an `id` (an uppercase UUID), a `kind`, an `order`, and
the fields it's saved with:

| `kind` | Fields besides `id`, `kind`, `order` |
| --- | --- |
| `table` | `name`, `position` `[x, y]`, `color`, `group`, `notes`, `samples` |
| `column` | `table`, `name`, `type`, `isPrimaryKey`, `isNullable`, `isUnique` |
| `relationship` | `from` and `to` (column IDs: `from` holds values of `to`), `zipTies` |
| `zipTie` | `position`, `direction`, `heldDirection`, `relationships` |
| `group` | `name`, `color` |
| `port` | `group`, `column`, `side`, `along`, `zipTies` |

Unknown fields are kept as they are, so later versions can add them.

A change is a list of ops, made all or nothing:

- **`put`** adds an entity, or replaces the one with that ID.
- **`set`** changes one field; a null value removes it. Two sets on one field: the one the host applied last wins. Sets
  on different fields of one entity both stay.
- **`delete`** removes an entity.

Bigger actions run on the client that does them, and send only their ops: deleting a table deletes its columns and the
keys to and from them; a layout sets each moved table's `position`; undo is the opposite ops of the change undone,
touching only what it touched.

**Order.** Things in order (tables bottom to top, a table's columns, wires, ties, groups, a group's ports) sort by
`order`, then `id`. Keys are strings of `0`–`9` and `a`–`z`, compared character by character, never ending in `0`.
Inserting between two keys makes one that sorts between them, so two people inserting at once both keep their item:

```
between(low, high):       // "" is before everything, null after everything
  key = ""; bounded = high != null; i = 0
  loop:
    a = digit(low[i]) or 0
    b = bounded ? digit(high[i]) or 36 : 36
    if b - a > 1: return key + char((a + b) / 2)
    key += char(a)
    if b - a == 1: bounded = false
    i += 1
```

Inside the encryption, ops are binary (the appendix has the encoding; `Wire.swift` implements it). A whole model is
about a third of its JSON size (Sakila: 26,719 bytes as JSON, 9,475 binary), and renaming a table is 28 bytes.

## Digests

Each decision carries a digest of the host's copy after it: a checksum of all its entities as 16 hex digits.

1. Write each entity as canonical JSON: what JavaScript's `JSON.stringify` writes, with every object's keys sorted by
   UTF-16 code units.
2. Hash its UTF-8 bytes with 32-bit FNV-1a twice, both with the prime 16777619, one starting from 2166136261, the other
   from 3735928559.
3. Sum each over all entities, wrapping at 2³².
4. Write the first sum, then the second, each as 8 hex digits.

Being a sum, an op only subtracts the old entity's hash and adds the new one's. A guest whose copy doesn't match
reconnects and catches up afresh.

## The log and snapshots

Each room keeps a log, a ring of the host's frames ready to send with their WebSocket headers, and a snapshot: the
whole model as of some decision, sealed by the host.

- **The ring keeps everything back to the older of** the latest snapshot and the oldest connected guest's last applied
  change, from its pings.
- **When a frame doesn't fit,** the relay drops the guest holding the oldest end back, which reconnects and catches up
  from the snapshot. One slow guest can't make the relay hold more. If everything left is past the snapshot, the relay
  drops the host instead, which comes straight back with a new one.
- **When the ring is half full,** the relay asks the host for a snapshot (`snapshot-request`).
- **Joining** is the snapshot, then the ring from the decision after it. **Reconnecting** is the ring from the guest's
  last decision if that's still kept, or the snapshot route if not.

A room's memory is allocated when the room is made and freed when it ends; nothing in between allocates.

## Limits

The relay's reply to `hello` carries its limits, and clients check against them before sending, so a change the relay
would refuse never leaves the Mac:

| Limit | Default |
| --- | --- |
| Largest frame, header included | 1 MiB |
| Largest snapshot | 1 MiB |
| Log | 2 MiB |
| People in a room, the host among them | 32 |
| Clients a room remembers, each keeping its peer number | 1,024 |

- A host whose sealed snapshot is over the limit doesn't start sharing, and says why. Sakila, the largest example, is
  24 KB.
- A change whose sealed frame is over the limit is taken back, as if the host had turned it down.
- The relay enforces every limit anyway, and closes a connection that goes past one.

## Versions

- **The wire version** is the header's first byte, and the only one the relay reads. It covers the header and the kinds
  of message. A relay that doesn't know a client's says which it speaks, and the app says the relay needs updating.
- **The room version** covers everything inside the encryption: the ops encoding, the model's fields and what they
  mean. A room's version is its host's, kept in the room's info, which the relay stores without reading. A guest older
  than the room can't join and says it needs a newer Joinery; one newer than the room but past its floor says the host
  does.

A new field doesn't need a new room version: it's written by name (field code 0), which every version reads and keeps.
A new kind of entity, a changed meaning or a changed encoding does.

## Why every copy is right

The host makes every change to its copy itself, in one order, so the argument is about guests. Let `D(n)` be the host's
copy after its `n`th decision; applying ops is deterministic.

1. **A guest's confirmed copy is always `D(seq)`.** A `welcome` or snapshot sets it to the host's copy at that
   decision. After that a guest applies only the frame numbered `seq + 1`, which carries exactly what turned `D(seq)`
   into `D(seq + 1)`. Anything else makes it reconnect. The digest catches a drift anyway.
2. **Each of a guest's changes is decided at most once, in order.** The host takes a change only one past the last it
   took from that guest, and records it before deciding.
3. **And at least once.** A change stays pending until a decision on it arrives, by the log or covered by a snapshot,
   and is sent again on every `welcome` and every return of the host.
4. **Once the network settles, everyone has the same copy.** Every guest reconnects, its pending changes are decided,
   and its `seq` reaches the host's latest.

The relay only delays, drops and replays the host's frames in order, which is what a network does.
`JoineryTests/RelaySimulation.swift` checks it with a real `RelayCore` between the host and guests, encryption on,
cutting connections (the host's included) with logs small enough that snapshots, dropped guests and dropped hosts
happen constantly. After every step it checks point 1 for every guest; at the end, point 4, and that every change was
taken exactly once. 400 runs go with every test run.

## What it doesn't do

- **No accounts.** A link is the only credential: share it as you would a password.
- **Nothing outlasts the host's sharing.** When it stops, the room, its log and snapshot go.
- **The host must stay online.** Closing the laptop ends the session after 30 seconds.
- **No TLS.** Zig's standard library has no TLS server, so the relay runs behind something that ends TLS: an ingress, a
  load balancer or a proxy (see `relay/chart`). Whatever ends it sees only sealed bodies.
- **No abuse controls beyond limits.** Rate limiting belongs in front of the relay, and since it can't read what's
  stored, abuse could only be by volume.

## Appendix: the ops encoding

A *varint* is unsigned LEB128, at most 10 bytes. A *string* is a varint byte count, then UTF-8.

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

So the same ops give the same bytes everywhere:
- A string is tag 5 only if it's exactly an uppercase UUID (`0-9A-F`, in the 8-4-4-4-12 form), so it reads back as the
  same text. Anything else, a lowercase UUID included, is tag 4.
- A put's fields and an object's keys are sorted by UTF-16 code units.
- Numbers are always 8-byte doubles.

Readers check every count against the bytes left, limit nesting to 32 levels, and reject bytes after the last op.
