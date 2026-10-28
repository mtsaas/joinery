# Live sessions: the protocol

> **The messages and transport here are gone.** Sessions now go through a relay, in binary and end-to-end encrypted:
> see [relay.md](relay.md). What still holds is the model as a replicated state machine, the ops, the digest, and why
> every copy comes back to the host's, which relay.md builds on.

Joinery shares a data model live through a **session**:
- **Host:** one person's Mac. It holds the true copy and saves it.
- **Guests:** everyone else. A guest can be another Joinery, or a browser running the built-in web client.

This document is enough to write a client in any language.

## The model as a replicated state machine

A data model is a flat map of **entities**, keyed by ID. Each entity is a JSON object with:
- `id`: an uppercase UUID string.
- `kind`: what sort of entity it is (see the table below).
- `order`: where it sorts among others of its kind.
- The fields it's saved with.

A change is a list of **ops** on entities. Every client applies the same ops in the same order, so every copy ends up the same.

| `kind` | Fields besides `id`, `kind`, `order` |
| --- | --- |
| `table` | `name`, `position` `[x, y]`, `color`, `group` (a group's ID, or absent), `notes`, `samples` |
| `column` | `table` (its table's ID), `name`, `type`, `isPrimaryKey`, `isNullable`, `isUnique` |
| `relationship` | `from` and `to` (column IDs: `from` holds values of `to`), `zipTies` (tie IDs, in order) |
| `zipTie` | `position`, `direction`, `heldDirection`, `relationships` |
| `group` | `name`, `color` |
| `port` | `group` (its group's ID), `column`, `side`, `along`, `zipTies` |

- **Values:**
  - `color` is one of blue, purple, pink, red, orange, yellow, green, teal, indigo, mint, cyan, brown.
  - `type` is one of uuid, integer, bigint, numeric, text, varchar, boolean, date, timestamp, json, bytea.
  - Positions are canvas points, with y growing downward.
- **Table geometry:** a table is 236 points wide. Its header is 30 points tall, plus 22 points per column.
- **Unknown fields:** keep them as they are. Later versions may add fields.

### Order

Things in order carry an `order` key. Sort ascending by `order`, then by `id`. That covers tables (bottom to top), a table's columns, wires, ties, groups, and a group's ports.

Keys are strings made of the characters `0`–`9` and `a`–`z`, compared character by character, never ending in `0`. To insert between keys `a` and `b`, make a key that sorts between them. Because each new key fits in the gap, two people inserting at once both keep their item.

The algorithm, where `""` means "before everything" and `null` means "after everything":

```
between(low, high):
  key = ""; bounded = high != null; i = 0
  loop:
    a = digit(low[i]) or 0
    b = bounded ? digit(high[i]) or 36 : 36
    if b - a > 1: return key + char((a + b) / 2)
    key += char(a)
    if b - a == 1: bounded = false
    i += 1
```

### Ops

```json
{"op": "put",    "entity": {"id": "…", "kind": "table", …}}
{"op": "set",    "id": "…", "field": "name", "value": "orders"}
{"op": "delete", "id": "…"}
```

- **`put`** adds an entity, or replaces the one with that ID.
- **`set`** changes one field. A `null` value removes the field.
- **`delete`** removes an entity.
- **Conflicts:** two `set`s on the same field: the one the host applied last wins. Sets on different fields of the same entity both stay.

Higher-level actions run on the client that does them, and only their resulting ops are sent:
- **Deleting a table:** delete the table, its columns, and the relationships to and from them.
- **Laying out tables:** a `set` of `position` for each table moved.
- **Undo:** the opposite ops of the change being undone, which only touch what that change touched.

## Transport

The host listens on one port, on its own machine only (`127.0.0.1`), and exposes it through a tunnel. On that port:
- **`GET /`** returns the web client.
- **`GET /` with `Upgrade: websocket`** opens a WebSocket.

Each WebSocket text message is one JSON object with a `type`.

**Links** look like `https://tunnel.example/#token=…`:
- Clients connect to the same host with `wss://` (or `ws://` for `http://`).
- They send the token in `hello`.
- The token sits after `#`, so it never travels in an HTTP request.
- A link may also carry `&name=…`, which the web client uses instead of asking for a name.

## Messages

| Type | From | Fields | Meaning |
| --- | --- | --- | --- |
| `hello` | client | `protocol: 1`, `token`, `name`, `client` | Must be first on every connection. `client` is a random ID the client keeps for as long as it's in the session, through every reconnection. A wrong token or protocol gets a `reject` without `cseq`, which ends the session for that client. Anything else first, or anything that isn't JSON, just closes the connection. |
| `welcome` | host | `protocol`, `you`, `seq`, `acked`, `hash`, `title`, `entities`, `peers` | The host's whole document as of change `seq`, and its digest. `acked` is the last of this client's changes the host has taken, whether made or turned down. `you` is this client's peer ID, the same through reconnections. |
| `ops` | client | `cseq`, `ops` | One change, made all-or-nothing. A client numbers its changes 1, 2, 3 and so on. |
| `ops` | host | `seq`, `author`, `cseq`?, `ops`, `hash` | A change made to the document, sent to everyone, its author included. `seq` counts up by one. `hash` is the document's digest after it. `author` is a peer ID, or `"host"`. |
| `reject` | host | `cseq`, `reason` | That change was taken but not made. |
| `ping` | client | | Sent every 10 seconds. |
| `pong` | host | `seq`, `acked`, `hash` | The host's latest change, the last of this client's changes it has taken, and the digest. |
| `presence` | client | `cursor` (`[x, y]` or absent), `selection` (IDs) | Where this client's pointer is on the canvas, and what it has selected. Send at most about 20 a second. |
| `presence` | host | `peer` | Someone's presence. |
| `joined`, `left` | host | `peer` | Someone has joined, or left. For `left`, the peer has only its `id`. |
| `bye` | host | `reason` | The host has stopped sharing. Don't reconnect. |

A **peer** is `{"id", "name", "color", "cursor"?, "selection"?}`. The host's own peer ID is `"host"`.

Unknown message types and fields are ignored, so later versions can add them.

### Digests

The `hash` of a document is a checksum of all its entities, written as 16 hex digits. It's built like this:
1. Write each entity as **canonical JSON**: what JavaScript's `JSON.stringify` writes, with every object's keys sorted by UTF-16 code units.
2. Take the UTF-8 bytes of that text, and hash them with **32-bit FNV-1a** twice. Both use the prime 16777619. One starts from 2166136261, the other from 3735928559.
3. Sum each of the two hashes over all entities, wrapping at 2³².
4. Write the first sum, then the second, each as 8 hex digits.

Because it's a sum, an op only subtracts the old entity's hash and adds the new one's, so it stays cheap to update.

If the digest in a `welcome` doesn't match the copy it came with, the client and host write JSON differently. The client then stops checking digests for the session instead of resyncing forever.

### The client

A client keeps four things:
- **`confirmed`:** the host's document as of change `seq`, with its digest.
- **`pending`:** its own changes the host hasn't taken yet, in order.
- **`sentThrough`:** the last change it sent on the current connection.
- **What it shows:** `confirmed` with every pending change applied on top. Work it out again after anything changes either one.

What it does:

- **On connecting:** send `hello`.
- **On `welcome`:**
  1. Set `confirmed` and `seq` from it.
  2. Drop the pending changes numbered `acked` or lower.
  3. Send the rest again, in order.
- **When the user changes something:** add the change to `pending` with the next number, and send it if connected.
- **On `ops`:**
  1. It must be `seq + 1`.
  2. Apply its ops to `confirmed`.
  3. If it's your own change, it must answer your oldest pending change, which you then drop.
  4. The digest must match.
- **On a `reject` with `cseq`:** it must answer your oldest pending change, which you drop.
- **On `pong`:** its `seq` must equal yours, its `acked` must be at least `sentThrough` as it was when you sent the ping, your oldest pending change must be numbered above its `acked`, and the digest must match.
- **When a check fails** (an `ops` out of order, a reply to the wrong change, a digest or `pong` that doesn't match, a message that won't parse): **resync**. Close the connection and connect again at once.
- **When the connection drops:** connect again after 0.25 s, doubling each time up to 10 s.
- **Giving up:** a client that has never been let in gives up after 4 failed tries. One that has, keeps trying.
- **Silence:** if nothing has come from the host for 25 seconds, resync.

### The host

The host numbers each change to the document `seq` 1, 2, 3 and so on, and sends it to everyone, in order, on every connection.

It remembers, per `client` ID, the last change number it has taken. When a client sends a change:
- **At or below that number:** the change has already been taken (it was sent again after a reconnect), so it's ignored.
- **More than one past it:** a change went missing, so the host closes the connection, and the client reconnects and sends it again.
- **One past it:** the host takes it. It records the number, then either makes the change or turns it down, never both.

A new connection from a client that's already connected closes the old one. Connections silent for 30 seconds are closed.

## Why every copy is right

The host makes every change to its document itself, in one order. So the argument is about guests only: each guest's copy is always exactly the host's document at some step, and once the network has been working for a while, it is the latest step, and every edit the guest made has been dealt with exactly once.

Let `D(n)` be the host's document after its `n`th change. `D(0)` is the document when sharing started, and `D(n)` is `D(n-1)` with the `n`th published change applied. Applying ops is deterministic, so the same ops on the same state always give the same result.

**1. A guest's confirmed copy is always `D(seq)`.**
- A `welcome` sets `confirmed` to `D(seq)`, because the host sends the document as it is after its latest change.
- After that, a guest only applies the `ops` message numbered `seq + 1`. That message carries exactly the ops that turned `D(seq)` into `D(seq + 1)`.
- Any other message makes the guest resync, which leads to a new `welcome`.
- So by induction `confirmed` is always `D(seq)`.
- The digest is a separate check: a guest that drifted anyway would detect it and resync, which sets it back to `D(seq)`.

**2. Each of a guest's edits is dealt with at most once, in order.**
- The host takes a guest's change only when its number is one past the last it took from that guest, and records that number before making or turning down the change.
- Numbers only go up, so no change is taken twice.
- They go up one at a time, so changes are taken in order with none skipped.

**3. Each of a guest's edits is dealt with at least once.**
- A pending change stays pending until the guest hears it was taken: its own `ops` echoed back, a `reject`, or a `welcome` whose `acked` covers it.
- While pending, the guest sends it on every new connection, after the `welcome`.
- A connection can drop partway, losing a change or its answer. The guest then reconnects, and the `welcome` says, through `acked`, whether the host took it. Taken: the guest drops it, and its result, made or turned down, is already in `D(seq)`. Not taken: the guest sends it again.
- If a change is lost while the connection stays up (TCP rules this out, but the protocol doesn't rely on that), the host sees the next change's number skip and closes the connection. If nothing follows it, the next `pong`'s `acked` falls short of what was sent before the ping, and the guest resyncs. If a change's answer is the thing lost, the next `pong`'s `acked` covers a change still pending. Every answer the host sent before that `pong` would already have arrived, so none is coming, and the guest resyncs. The simulation found this case.
- So, as long as connections work some of the time, every change is eventually taken.

**4. The copy shown is always well defined.** What a guest shows is `D(seq)` with its pending changes on top. Applying an op to something that has since been deleted does nothing. That's the same thing the host would decide, because the host turns such a change down.

**5. Once the network settles, everyone has the same thing.**
- Let the host and guests stop editing, and the network deliver.
- Every guest reconnects, by its back-off, and gets a `welcome`.
- Each pending change is then taken (point 3), and its echo or `reject` arrives in order.
- Each guest's `seq` catches up to the host's latest, and the next `pong` confirms it.
- Then every guest has no pending changes and `confirmed = D(latest)`, which is the host's document. What each shows is that same document.

**Tested by simulation.** `JoineryTests/SessionSimulation.swift` runs the real `HostCore` and `ClientCore` together over a simulated network:
- It delivers messages in any order across connections, and cuts connections partway through.
- In half the runs it also loses, repeats, swaps and garbles messages, things TCP never does.
- Everyone makes random edits throughout.

After every step it checks point 1 for every guest. At the end, it checks point 5 and that every guest's changes were each taken exactly once. 600 runs go with every test run. While developing it, 3,000 longer runs were made as well.

## Limits

- **Message size:** messages over 16 MB close the connection.
- **Reconnecting sends the whole document again**, not just what was missed. It's simpler, and it can't go wrong.
- **One level of access:** the token gives full editing. There are no view-only links yet.
- **Drags:** tables move for others when they're dropped, not while they're dragged.
