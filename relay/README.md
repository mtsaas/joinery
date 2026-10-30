# Joinery relay

The server Joinery's live sessions go through ([docs/relay.md](../docs/relay.md)). A host shares a data model through it
and guests join with a link. Everything they send is end-to-end encrypted, and the relay never reads it: it reads a
24-byte header, keeps each room's recent frames and latest snapshot, and catches joiners up.

**Run it** from the container image, `ghcr.io/mtsaas/joinery-relay` (about 450 KB, for amd64 and arm64), or with the
Helm chart, `oci://ghcr.io/mtsaas/charts/joinery-relay` ([its README](chart/README.md)). Either way, put something that
ends TLS in front: the relay speaks plain WebSockets.

```sh
docker run -p 8787:8787 -p 9187:9187 ghcr.io/mtsaas/joinery-relay
```

**Build it** with Zig 0.17:

```sh
zig build run -- --port 8787          # on 127.0.0.1:8787; --address 0.0.0.0 for others
zig build test                        # the tests, the replay of the Swift relay's traces among them
zig build bench                       # time per frame for each step, and allocations, which must be none
zig build load -- --rooms 100         # load a running relay, and report throughput and latency
zig build -Doptimize=ReleaseSafe      # zig-out/bin/joinery-relay
```

Flags: `--address`, `--port` (8787), `--metrics-address`, `--metrics-port` (9187), `--threads` (event loops: half the
cores), `--batch-ms` (how long a queue waits for more before it's sent: 5), `--max-rooms` (256), `--max-connections`
(768) and `--max-outbox-mib` (128: what's queued for connections that don't read, all together), which keep what anyone
can make it hold under 2 GiB at worst (raise them with its memory), and on Linux `--pin <cpu>` (loop i on CPU pin + i,
which halves the tail latency). Prometheus metrics are at `/metrics` on their own port, which only this machine
can reach unless `--metrics-address` says otherwise.

## How much one relay holds

On a 16-core Arm VM with 64 GB (Azure D16ps_v6), with the defaults but `--max-rooms`, `--max-connections` and `--max-outbox-mib` raised, and `--pin 0`. Every host sends a change a second
and every guest five pointer updates a second:

| Rooms | People | Delivered a second | Latency | Relay used |
| --- | --- | --- | --- | --- |
| 1,000 full rooms (32 people) | 32,000 | 2.3M pointer updates | p50 19 ms | 4 cores, 0.55 GB |
| 20,000 rooms of 4 | 80,000 | 0.6M | p50 7–9 ms | under 2 cores, 1.4 GB |

At most it delivers 9.6 million messages a second, at p99 under 70 ms. Past that, the kernel's work on each packet fills
the machine, not the relay's code. These are what the test rig could show, not the relay's limits: in rooms of 4 the
relay used under 2 of its 16 cores. [bench/load-results.md](bench/load-results.md) has every measurement and how it
was found, and `bench/profiles/` the profiles behind them.

## The code

```
src/
  main.zig            the command line: listeners, loops, threads
  load.zig            the load generator
  bench.zig           the micro-benchmarks
  tests.zig           every test
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
chart/                the Helm chart
```

Each loop has its own thread, event queue, relay and rooms, with no lock. On Linux each has its own listener, and the
kernel spreads connections evenly across them. A room's ID names its loop, and a guest arriving on another is handed to
it. Each turn reads what's ready, hands whole messages to the relay, then sends each connection's queue in one `send`.
A room's memory is allocated when it's made and freed when it ends; nothing allocates in between, which the replay test
and the benchmarks check.

After changing the protocol, run `scripts/record-relay-traces.sh` from the repository root to record
`src/relay/testdata/` again.
