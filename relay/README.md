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

Prometheus metrics are at `http://127.0.0.1:9187/metrics`, on a port of their own that only this machine can reach
(`--metrics-address` and `--metrics-port` change that): rooms, peers and connections open, bytes held in logs, frames
and bytes in and out, rooms made and ended, joins, decisions, guests' changes, snapshots, connections closed for
falling behind, and every connection let go of or turned away, by why (`joinery_relay_dropped_total{reason=…}`). The
relay's own memory is left to the process exporter of wherever it runs.

**How much one relay holds.** One relay on a 16-core Arm VM with 64 GB (Azure D16ps_v6, Neoverse-N2), with the
defaults (8 loops, 5 ms batching) and `--pin 0`. Every host sends a change a second, and every guest five pointer
updates a second:

| Rooms | People | Delivered a second | Latency | Relay used |
| --- | --- | --- | --- | --- |
| 1,000 full rooms (32 people) | 32,000 | 2.3M pointer updates, 97–100% of them | p50 19 ms | 4 cores, 0.55 GB at peak |
| 20,000 rooms of 4 | 80,000 | 0.6M | p50 7–9 ms | under 2 cores, 1.4 GB at peak |

At most it delivers **9.6 million messages a second** (3,200 rooms whose hosts send 1,000 changes a second each), at
p99 under 70 ms, with 4.5 cores busy and 1.7 GB at peak.

These are what the test could show, not the relay's limits. In the rooms of 4 the relay closed nothing and used under
2 of its 16 cores, but one of the two load VMs couldn't keep up (it got 75–77% of its updates, the other 88–100%,
with batching on or off), and at 30,000 rooms the steadier VM still got all of its half at p99 7 ms. Cores busy are
averaged over the whole run, opening the rooms included, so they read low. Rooms hold 32 people; a relay's limit is
messages delivered, not people, so rooms twice the size hold about a quarter as many people.

Details, and how each number was found, are in `bench/load-results.md`.

The code is in two parts: what the relay does, and how it's on the network.

```
src/
  main.zig            the relay's command line: listeners, loops, threads
  load.zig            the load generator (zig build load)
  bench.zig           the micro-benchmarks (zig build bench)
  tests.zig           every test (zig build test)
  relay/              what the relay does, without the network
    Relay.zig         rooms, and who's sent what; a port of RelayCore.swift, the reference
    Log.zig           a room's log: a ring of whole frames, allocated once
    wire.zig          the header, the hello the relay reads, and the frames it writes
    relay_test.zig    the relay's behaviour, connection by connection
    replay_test.zig   replays what RelayCore heard in the app's simulation (testdata/), for the same bytes out
  server/             the relay on the network
    Server.zig        an event loop: reading, handing messages to the relay, sending, handing guests between loops
    Conn.zig          a connection: its socket, what's come in, and its outbox
    Pointers.zig      the newest pointer update from each person, held for a connection that's behind
    poller.zig        the event queue: kqueue, or epoll on Linux
    socket.zig        listeners, and the options each connection gets
    http.zig          the request a connection starts with
    websocket.zig     WebSocket framing: headers, unmasking, the handshake's answer
    metrics.zig       the counts, and Prometheus's text format
```

- **Loops.** There's a loop for every two cores (`--threads`): the kernel's network work needs the other half, and
  more loops deliver less. Each has its own thread, event queue, relay and rooms, non-blocking sockets and no lock.
  On Linux each has its own listener, and the kernel spreads connections evenly. A room's ID names its loop, and a
  guest arriving on another loop is handed to it. Each turn reads what's ready, hands whole messages to the relay,
  then sends each connection's queue in one `send`. On Linux, `--pin 0` pins loop i to CPU i, which halves the tail
  latency. A connection that's behind is sent only the newest pointer update from each person.
- **Traces.** After changing the protocol, run `scripts/record-relay-traces.sh` from the repository root to record
  `src/relay/testdata/` again.
- **`bench/azure.sh`** runs load across a real network: a relay VM and load-generator VMs on Azure (Arm Linux, spot),
  `up`, `push`, `run`, `perf` and `down`. **`bench/load.sh`** runs the standard scenarios on this machine.
  **`bench/load-results.md`** has every step's results side by side, and `bench/profiles/` the profiles behind them.
- **`bench/results.txt`** is the last benchmark run, with its commit.

Each room's memory is allocated when it's made and freed when it ends; nothing allocates in between, which the replay
test and the benchmarks check.
