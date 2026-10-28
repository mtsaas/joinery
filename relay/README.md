# Joinery relay

The server Joinery's live sessions will go through (`docs/relay.md`). A host shares a data model through it and
guests join with a link. Everything they send is end-to-end encrypted, and the relay never reads it: it reads a 24-byte
header, keeps each room's recent frames and latest snapshot, and catches joiners up. It needs Zig 0.17.

```sh
zig build run -- --port 8787          # relay on 127.0.0.1:8787; --address 0.0.0.0 for others
zig build test                        # the tests, the replay of the Swift relay's traces among them
zig build bench                       # time per frame for each step, and allocations, which must be none
zig build -Doptimize=ReleaseSafe      # zig-out/bin/joinery-relay
```

- **`src/Relay.zig`** is the relay, without the network. It's a port of `RelayCore.swift`, which is the reference.
  `src/replay_test.zig` replays what that one heard in the app's simulation (`src/testdata/`) and checks this one sends
  the same bytes on every connection. After changing the protocol, run `scripts/record-relay-traces.sh` from the
  repository root to record the traces again.
- **`src/Log.zig`** is a room's log: a ring of whole frames, allocated once.
- **`src/wire.zig`** is the header, the `hello` the relay reads, and the frames it writes.
- **`src/Server.zig`** puts it on the network: WebSockets, a reader and a writer task per connection, one lock around
  the relay. Sends only append to a connection's outbox, so a slow connection holds up no one. A link opened in a
  browser (`/r/<room>`) is told to paste it into Join in Joinery.
- **`bench/results.txt`** is the last benchmark run, with its commit.

Each room's memory is allocated when it's made and freed when it ends; nothing allocates in between, which the replay
test and the benchmarks check.
