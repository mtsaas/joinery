# Live sessions: the protocol

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
| `hello` | client | `protocol: 1`, `token`, `name` | Must be first. Anything else first, a wrong token, or another protocol: a `reject` without `cseq`, then the connection closes. |
| `welcome` | host | `protocol`, `you`, `seq`, `title`, `entities`, `peers` | Everything there is, and who's here. `you` is this client's peer ID. |
| `ops` | client | `cseq`, `ops` | One change, made all-or-nothing. `cseq` numbers this client's changes 1, 2, 3, and so on. |
| `ops` | host | `seq`, `author`, `cseq`?, `ops` | A change applied, sent to everyone, its author included. `seq` counts up by one. `author` is a peer ID, or `"host"`. |
| `reject` | host | `cseq`, `reason` | That change wasn't made, because something it refers to has gone or it doesn't read. |
| `presence` | client | `cursor` (`[x, y]` or absent), `selection` (IDs) | Where this client's pointer is on the canvas, and what it has selected. Send at most about 20 a second. |
| `presence` | host | `peer` | Someone's presence. |
| `joined` | host | `peer` | Someone has joined. |
| `left` | host | `peer` (`id` only) | Someone has left. |

A **peer** is `{"id", "name", "color", "cursor"?, "selection"?}`. The host's own peer ID is `"host"`.

### Keeping a copy

A client keeps the **confirmed** state (what the host has sent) and a list of its own **pending** changes.

1. **On `welcome`:** confirmed = the entities, and pending is empty.
2. **When the user changes something:** add it to pending with the next `cseq`, and send it.
3. **On `ops` from the host:** apply them to confirmed. If `author` is you and `cseq` is your oldest pending change, drop that one from pending.
4. **On a `reject` with `cseq`:** drop that pending change.
5. **What to show:** confirmed with every pending change applied on top. Work it out again after each of steps 2 to 4.

Your own edits show at once, and everyone's edits end up in the host's order.

### What the host checks

The host applies a client's change only if every op can be made:
- a `set` or `delete` must point at an entity that exists;
- `id` and `kind` can't be changed;
- every entity it leaves must read as its kind;
- order keys must be valid;
- a column or port must name a table or group that exists.

After applying a change, the host tidies up and sends the clean-up as ops from `"host"`. For example, it drops a key whose column is gone, or a group left empty.

## Limits

- **Message size:** messages over 16 MB close the connection.
- **No resuming:** a guest who disconnects joins again and gets a fresh `welcome`.
- **One level of access:** the token gives full editing. There are no view-only links yet.
- **Drags:** tables move for others when they're dropped, not while they're dragged.
