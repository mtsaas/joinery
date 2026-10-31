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
cores), `--batch-ms` (how long a queue waits for more before it's sent: 5), `--max-rooms` (256), `--max-connections` (768)
and `--outbox-mib` (what connections that are behind hold between them, before the one behind longest is closed: 128),
which keep what anyone can make it hold under 2 GiB at worst (raise them with its memory), and on Linux `--pin <cpu>` (loop i on CPU
pin + i, which halves the tail latency). `--udp on` carries presence as UDP datagrams beside each WebSocket, on the same
port number (docs/relay.md, "Presence over UDP"), with `--udp-port` and `--udp-host` for where clients send them when a
load balancer's in front. Prometheus metrics are at `/metrics` on their own port, which only this machine can reach
unless `--metrics-address` says otherwise.

Build for the CPU's AES and carry-less multiplication, as the container does (`-Dcpu=generic+aes` on Arm,
`-Dcpu=x86_64_v3+aes+pclmul` on x86): presence over UDP seals every datagram, and without them Zig's software AES runs,
several times slower.

## How much one relay holds

Two tests, both run by `bench/azure.sh` on Azure Arm VMs, with load from two other VMs that start counting at the same
moment. A run counts when every change arrives and p99 latency stays within 50 ms. Each test raises the number of
rooms until a run fails.

**On a small host** (`bench/azure.sh small`): 2 cores, with the relay held to 2 GB by a cgroup that counts its socket
buffers too, and run with `--threads 2`. Rooms of four; each host sends a change a second and each guest five pointer
updates a second:

| Presence goes by | Rooms | People | Latency: changes, presence | Relay used |
| --- | --- | --- | --- | --- |
| UDP (`--udp on`) | **13,000** | 52,000 | p99 16 ms, 1.7 ms | 1.5 cores, 1.5 GB |
| WebSocket | 5,500 | 22,000 | p99 11 ms, 12 ms | 1.5 cores, 685 MB |

CPU runs out first, not memory. Set `--threads 2` on 2 cores (the default, half the cores, leaves one idle), and raise
`--max-rooms` and `--max-connections` to match, because the defaults stop at 256 rooms.

**Flat out, by machine size** (`bench/azure.sh throughput`): rooms of four, each host sending 1,000 changes a second,
with half the cores as loops, run long enough that rooms' logs fill and the relay asks hosts for snapshots:

| Cores | Rooms | Delivered a second | vs. 2 cores | p99 | Memory |
| --- | --- | --- | --- | --- | --- |
| 2 | 500 | 1.5M | 1.0× | 39 ms | 490 MB |
| 4 | 850 | 2.5M | 1.7× | 39 ms | 900 MB |
| 8 | 1,600 | 4.8M | 3.2× | 36 ms | 1.9 GB |
| 16 | 1,800 | 5.4M | 3.6× | 13 ms | 3.3 GB |

Up to 8 cores each doubling gives 1.7 to 1.9×; 8 to 16 gives 1.1×, the loops full while half the machine idles. This
load is a worst case for the network stack, all changes and no presence, and it's what makes memory: a room's log
fills toward its 2 MiB. The small-host test is what typical use looks like.
[bench/load-results.md](bench/load-results.md) has every measurement and how it was found, and `bench/profiles/` the
profiles behind them.

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
