# Load results

`bench/load.sh` on an Apple M5 Pro, the relay (ReleaseSafe) and the load generator on the same machine, so the
relay's numbers are conservative. Each scenario runs 10 seconds against a fresh relay; CPU is the relay's over the
whole run, RSS and threads at its end, with every room still open.

- **throughput:** 100 rooms, a host and 3 guests each, 1,000 changes a second per room.
- **fan-out:** 10 rooms of 31 guests, 400 changes a second per room.
- **connections:** 1,000 rooms of a host and 3 guests (4,000 connections), 5 changes a second per room.
- **pointers:** 200 rooms of a host and 7 guests, 5 changes a second, every guest's pointer moving 30 times a second
  (asked of the generator: 42,000 pointer updates a second, each to the 6 other guests).
- **slow guests** (step 2 on): 50 rooms of a host and 7 guests, 5 changes a second, pointers at 30 a second, and one
  guest in each room on a slow connection: a 4 KB receive buffer and reading 50 messages a second. Run on Linux in
  Docker: macOS ignores a receive buffer that small, and on loopback the backlog then sits in the slow guest's own
  kernel, out of the relay's reach, which isn't what a slow network does.

From step 2 on, latency percentiles come from buckets 9% apart reaching an hour (before: 10 µs apart, capped at
100 ms, shown as 100,000+).

## Before: a thread pair per connection, one lock (f1de0b2)

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,788 | 4,330 µs | 9,550 µs | 0 | 43.5 | 179 | 803 |
| fan-out | 123,870 | 180 µs | 720 µs | 0 | 22.0 | 39 | 643 |
| connections | 13,665 | 440 µs | 100,000+ µs | 0 | 18.8 | 515 | 8,003 |
| pointers | 6,833 | 3,270 µs | 100,000+ µs | 202,599 | 36.5 | 181 | 3,203 |

## Event loop: one thread, the OS's event queue, no lock

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,701 | 1,830 µs | 5,790 µs | 0 | 9.4 | 140 | 1 |
| fan-out | 123,935 | 200 µs | 3,940 µs | 0 | 4.1 | 8 | 1 |
| connections | 12,995 | 430 µs | 19,650 µs | 0 | 2.1 | 132 | 1 |
| pointers | 6,834 | 5,850 µs | 32,060 µs | 206,907 (100% of what the generator sent) | 7.9 | 28 | 1 |

4.6 to 9 times less CPU for the same work, one thread instead of 800 to 8,000, and a quarter of the memory with
4,000 connections. Fan-out's p99 is worse (0.72 to 3.9 ms): one thread now makes a frame's 31 sends in turn, where 31
writer threads made them at once. In the pointers scenario the relay used 65% of a core; the load generator, with
thousands of threads of its own, couldn't send all 42,000 pointer updates a second (it managed about 34,500), and
the relay delivered every one. (This first said 86%, and the baseline 69%: the generator counted the host as a
recipient of pointer updates but never counted what the host received. Fixed; the absolute numbers stand.)

## Step 2: only the newest pointer update from each person while a connection is behind

Pointer updates wait in a slot per sender, and go when a connection's queue has gone; a newer one from the same
person replaces the one waiting. Sockets are set to hold at most 16 KB not yet on its way (`TCP_NOTSENT_LOWAT`), so a
slow connection's backlog waits in the relay, where this can happen, rather than in the kernel.

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Pointer updates replaced | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,850 | 1,878 µs | 2,656 µs | 0 | 0 | 9.5 | 140 | 1 |
| fan-out | 123,935 | 108 µs | 609 µs | 0 | 0 | 3.5 | 8 | 1 |
| connections | 12,986 | 431 µs | 19,484 µs | 0 | 0 | 2.1 | 132 | 1 |
| pointers | 6,829 | 3,444 µs | 16,384 µs | 207,968 (100%) | 0 | 8.2 | 28 | 1 |

The same as step 1, as it should be: nothing on this Mac is slow enough for a connection to fall behind, so nothing
is replaced. The slow-guest scenario, on Linux:

| Relay | Everyone else: changes p50 / p99 | Slow guests: changes delivered/s | Slow guests: changes p50 / p99 | Pointer updates replaced | Relay CPU s | Relay RSS |
| --- | --- | --- | --- | --- | --- | --- |
| Step 1 | 152 µs / 6.3 ms | 65 | 8.4 s / 16.8 s | 0 | 6.3 | 6.8 MB |
| Step 2 | 152 µs / 4.9 ms | 198 | 5.0 s / 5.9 s | 129,820 | 6.8 | 7.3 MB |

Slow guests get three times the changes, sooner, because they're no longer behind a queue of pointer positions
already out of date. What's left of their 5 seconds is what the kernel still holds: 16 KB unsent is over 3 seconds
for a guest reading 50 messages a second. A smaller limit would cut it, for more wakeups on fast connections.

## Step 3: what a profile says, and the layout and instructions in the hot paths

**First, a profile** (`sample`, throughput scenario, 5 s; `bench/profiles/`). Of the relay's ~3,100 samples, 71% were
in `sendto`, 25% in `recvfrom` and 2% in `kevent`, all in the kernel; all of the relay's own code together was 1.2%,
reading the clock 0.4%, `memmove` 0.3%. So layout and instruction-level work can buy at most a percent or two of the
relay's CPU end to end; system calls are the cost. What was done, and what it measured:

| Change | Why | Measured |
| --- | --- | --- |
| One `recv` per readable socket unless it filled the buffer | Reading until "nothing left" is always one more call that returns nothing | `recvfrom` samples 773 → 524; relay CPU on throughput 9.35–9.40 s → 9.06–9.08 s against the step-2 build, back to back (~3%) |
| The clock read once per turn, not per message | 0.4% of samples, for millisecond timestamps | Folded into the above |
| Unmasking 16 bytes at a time | The disassembly showed a byte loop, unrolled 6×, reloading the mask byte from the stack each time: ~4 instructions a byte. Now `eor.16b`. | 124 bytes: 19.4 → 5.4 ns. A 1 MiB snapshot: 163 → 15 µs (ReleaseSafe) |
| `@memmove` for buffer compaction | `std.mem.copyForwards` compiled to a scalar byte loop | Not measurable at this load (`memmove` was 0.3%) |
| Guests 112 → 32 bytes (name moved to the client table) | Fan-out reads every guest; 31 went from 55 cache lines to 16 | 1 room, in cache: 34.5–36 ns (was 34.4–54); 2,000 rooms: 134–138 ns (was 143–144), ~6% |
| A connection's send-side fields grouped, pointer slots moved out and made on first use | What every send touches in one place; 192 bytes of slot bookkeeping out of the connection | Not measurable at this load (`queue` was 0.2%) |
| The client table reserved, not filled | `alloc` in ReleaseSafe writes every one of a room's 1,024 entries: 72 KB a room, resident whether used or not | 4,000 connections: 132 → 82 MB |

Tried and undone: the guests as a `MultiArrayList` (a struct of arrays). Fetching its arrays costs a fixed amount per
change: 34.5 → 45 ns in cache, and no clear win across 2,000 rooms. Aligning the hot fields to a cache line: the
allocator gives over-aligned objects a page each, ~16 KB a connection.

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Pointer updates replaced | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,777 | 1,878 µs | 2,656 µs | 0 | 0 | 9.4 | 135 | 1 |
| fan-out | 123,941 | 128 µs | 664 µs | 0 | 0 | 3.8 | 8 | 1 |
| connections | 13,020 | 470 µs | 17,867 µs | 0 | 0 | 2.1 | 82 | 1 |
| pointers | 6,860 | 32,768 µs | 220,436 µs | 191,999 (93%) | 199,271 | 6.9 | 18 | 1 |

Run with the machine busy (load average 58 at the start, from macOS's malware scanners, set off by every new build),
so CPU here reads a few percent high; the back-to-back comparisons above are the fair ones. The pointers scenario is
the one that suffers: its generator runs 1,600 connections and 1,400 pointer tasks, and on a busy machine its guests
read late, so the relay rightly holds them to the newest pointer updates (the replacements); the step-2 build did the
same under the same conditions.

Microbenchmarks, best of five (`zig build bench`, ReleaseFast):

| Step | Before step 3 | After |
| --- | --- | --- |
| read a header | 0.7 ns | 0.8 ns |
| append to the log | 1.5–1.6 ns | 1.6 ns |
| a host's change, to 31 guests | 34.4–54.6 ns | 34.5–36.2 ns |
| a host's change, to 31 guests, across 2,000 rooms | 143–144 ns | 134–141 ns |
| a guest's change, to the host | 6.8 ns | 6.9 ns |
| unmask a 1 MiB snapshot (ReleaseSafe) | 163 µs | 15 µs |

## All steps, side by side

The stable scenarios, the same on every run that wasn't disturbed:

| Scenario | Measure | Threads + lock | Event loop | Newest pointers only | Layout, SIMD, fewer calls |
| --- | --- | --- | --- | --- | --- |
| throughput (300k/s delivered) | relay CPU | 43.5 s | 9.4 s | 9.5 s | 9.1 s (back to back) |
| | p50 / p99 | 4.3 / 9.6 ms | 1.8 / 5.8 ms | 1.9 / 2.7 ms | 1.9 / 2.7 ms |
| | memory, threads | 179 MB, 803 | 140 MB, 1 | 140 MB, 1 | 135 MB, 1 |
| fan-out (124k/s delivered) | relay CPU | 22.0 s | 4.1 s | 3.5 s | 3.5–3.8 s |
| | p50 / p99 | 0.18 / 0.72 ms | 0.20 / 3.9 ms | 0.11 / 0.61 ms | 0.11–0.13 / 0.61–0.66 ms |
| connections (4,000) | relay CPU | 18.8 s | 2.1 s | 2.1 s | 1.8–2.1 s |
| | p99 | 100+ ms | 19.7 ms | 19.5 ms | 2.4–17.9 ms |
| | memory, threads | 515 MB, 8,003 | 132 MB, 1 | 132 MB, 1 | 82 MB, 1 |
| slow guests (Linux) | their changes delivered/s, p99 | | 65, 16.8 s | 198, 5.9 s | (unchanged) |

What moved the numbers: the event loop (4.6 to 9 times less CPU, a thread instead of thousands, a quarter of the
memory); holding only the newest pointer updates (slow guests get three times the changes); reserving instead of
filling (memory). What didn't, measurably: layout and SIMD, because 98% of the relay's time is in the kernel; they
pay off per snapshot (unmasking) and per cache miss across many rooms (6%), and will matter more once system calls
are fewer.

**Next, by the profile:** fewer system calls. On Linux, io_uring submits a frame's sends to all its guests in one
call, and receives likewise; macOS has nothing like it. Short of that, coalescing a connection's frames for a fraction
of a millisecond trades a little latency for fewer `send`s.

## A loop per core

Each loop has its own thread, event queue, relay and rooms, sharing nothing as it runs. All watch the one listening
socket; a room's ID names its loop, and a guest's connection that comes in on another loop is handed to that one,
hello and all, through a lock-free queue and a pipe to wake it. Metrics are each loop's, copied out once a second and
added up on scrape.

**One loop versus 18** (this Mac's cores), at rising load, back to back:

| Load | Loops | Changes delivered/s | p50 / p99 | Relay CPU s |
| --- | --- | --- | --- | --- |
| 100 rooms × 1,000/s | 1 | 298,851 | 1.9 / 2.7 ms | 9.1 |
| | 18 | 298,972 | 2.0 / 2.9 ms | 11.1 |
| 200 rooms × 1,000/s | 1 | 595,424 | 4.5 / 6.3 ms | 8.9 |
| | 18 | 595,946 | 4.9 / 6.9 ms | 11.3 |
| 400 rooms × 1,000/s | 1 | 1,178,681 | 16.4 / 30.0 ms | 8.3 |
| | 18 | 1,178,359 | 17.9 / 27.6 ms | 11.5 |

One loop didn't run out: at 1.18 million deliveries a second it used 73% of a core, and less CPU than at a quarter of
the load, because the busier it is the more frames each connection gathers between turns, so each `send` carries
several. What ran out was the machine: 75% of all 18 cores busy, 69% of it in the kernel, mostly the loopback work
of the load generator's 1,600 connections and of the relay's sends, which on loopback do the receiving side's work
too. So more loops can't be shown to help here; that wants load from other machines, at deployment. What can be shown
is their cost when one loop would do: work spread thin, so fewer frames to a `send`, and on macOS every loop woken for
every new connection (on Linux, `EPOLLEXCLUSIVE` wakes one).

The standard scenarios with 18 loops:

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Pointer updates replaced | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,708 | 2,048 µs | 2,896 µs | 0 | 0 | 11.5 | 137 | 18 |
| fan-out | 123,949 | 117 µs | 609 µs | 0 | 0 | 4.6 | 9 | 18 |
| connections | 12,896 | 362 µs | 17,867 µs | 0 | 0 | 4.4 | 85 | 18 |
| pointers | 6,868 | 38,968 µs | 285,870 µs | 177,941 (86%) | 356,808 | 11.6 | 20 | 18 |

Same results, 20% to twice the CPU. `--threads` sets the loops; it defaults to one per core.

## On Linux, across a real network (Azure)

`bench/azure.sh`: the relay on a D8ps v6 (8 Arm cores, 32 GB) and the load generator on a D16ps v6 (16 cores), spot
VMs in one proximity placement group in Central US with accelerated networking, Ubuntu 24.04 (kernel 7.0). So the
generator isn't on the relay's cores, and the network isn't loopback. Generator sockets set `TCP_NODELAY`, as the
app's do: without it the kernel held back clients' small frames and merged them, which flattered the relay (a quarter
of the CPU at 100 rooms) and added ~5 ms of latency.

| Load (host + 3 guests a room) | Loops | Changes delivered/s | p50 / p99 | Relay CPU (of 8 cores) |
| --- | --- | --- | --- | --- |
| 100 rooms × 1,000/s | 1 | 299,515 | 1.45 / 2.9 ms | 11.1 s: one core, near full |
| | 8 | 299,618 | 0.17 / 0.47 ms | 22.5 s |
| 400 rooms × 1,000/s | 1 | 1,191,911 | 5.8 / 10.6 ms | 11.4 s: one core, full |
| | 8 | 1,186,138 | 0.30 / 1.7 ms | 78.2 s, 71.6 s untracked (below) |
| 800 rooms × 1,000/s | 8 | 2,246,977 | 2.4 / 3.8 ms | 92.6 s: all eight, full |
| 1,600 rooms × 1,000/s | 1 or 8 | collapsed | | full |

Here, unlike on the Mac, one loop is the limit: it fills a core at about 300,000 deliveries a second and only keeps up
past that by queuing. Eight loops carry 2.25 million a second on 8 cores, about 280,000 a core, and at the same load
cut latency 9 to 20 times. They spend more CPU a message than one loop (each batches less), which is the price of
not queuing. So `--threads` stays at one per core.

**Where the time goes** (`perf`, 8 loops, 400 rooms): the relay's own code is under 5% (`memcpy` 1.7%, the loop
1.3%). The rest is the kernel: about 10% in the firewall's connection tracking (`__nf_conntrack_find_get` 7.6%,
`nf_conntrack_in`, `nft_do_chain`), which the Azure agent's firewall rules turn on and the relay gains nothing from;
about 10% in locks (`_raw_spin_lock` and friends: sockets and network interrupts); 6 to 7% the cost of each system
call itself (`el0_svc` entering the kernel, `__fget_files` looking up the socket, `sock_poll`); about 2% AppArmor
checking each send; and the TCP stack, spread thin.

Not tracking the relay's port (`nft ... notrack`, now in `bench/azure.sh up`, and wanted on any relay server) cut CPU
8% at 400 rooms: 78.2 → 71.6 s, same throughput and latency. Next by this profile: io_uring with registered sockets,
which removes most of the per-call cost and lets a frame's sends to all its guests go in one submission.

### How it scales with loops

Each loop count pushed with rising load (host + 3 guests a room, 1,000 changes a second each) until it fell behind;
the generator's CPU too, to know when it was the limit. Runs are 12 s; CPU is over the whole run.

| Loops | Rooms | Delivered/s | p50 / p99 | Relay CPU s | Generator CPU s (16 cores) |
| --- | --- | --- | --- | --- | --- |
| 1 | 200 | 597,837 | 3.2 / 4.9 ms | 11.2 | 55 |
| 1 | 400 | 1,189,654 | 6.3 / 11.6 ms | 11.4 | 86 |
| 1 | 600 | 1,771,255 | 15.0 / 30.0 ms | 11.6 | 109 |
| 1 | 800 | 2,334,529 | 27.6 / 65.5 ms | 11.8 | 135 |
| 1 | 1,000 | 2,797,716 | 85.0 / 572 ms | 12.1 | 170 |
| 2 | 200 | 597,865 | 1.6 / 3.2 ms | 22.3 | 81 |
| 2 | 400 | 1,189,761 | 3.4 / 5.8 ms | 22.7 | 104 |
| 2 | 600 | 1,775,167 | 4.9 / 8.9 ms | 23.1 | 122 |
| 2 | 800 | 2,348,626 | 6.3 / 11.6 ms | 23.5 | 140 |
| 2 | 1,000 | 2,905,469 | 8.9 / 19.5 ms | 23.9 | 155 |
| 4 | 200 | 597,654 | 0.30 / 1.2 ms | 31.9 | 90 |
| 4 | 400 | 1,186,696 | 1.7 / 3.2 ms | 45.1 | 132 |
| 4 | 600 | 1,768,939 | 2.7 / 4.5 ms | 45.9 | 147 |
| 4 | 800 | 2,337,084 | 3.8 / 7.5 ms | 46.6 | 157 |
| 4 | 1,000 | 2,861,412 | 6.3 / 12.6 ms | 47.5 | 174 |
| 8 | 200 | 597,367 | 0.24 / 0.79 ms | 38.4 | 93 |
| 8 | 400 | 1,183,518 | 0.33 / 1.7 ms | 73.5 | 155 |
| 8 | 600 | 1,698,936 | 1.4 / 2.7 ms | 90.7 | 172 |
| 8 | 800 | 1,855,900 | 2.2 / 5.8 ms | 92.2 | 184 |

What it says:

- **A loop never stops delivering; it queues.** One loop reached 2.8 million a second on one core, but at 85 ms p50:
  the more that waits, the more each `send` carries, so its cost per message falls as latency climbs. Capacity has
  to be read at a latency, not as raw throughput.
- **At p99 under ~6 ms, scaling is linear to 2 loops and sublinear after:** about 0.6, 1.2, 1.8 to 2.3, and 1.9
  million a second for 1, 2, 4 and 8 loops.
- **Why not linear past that:** each loop's share of the traffic is smaller, so it batches less, and a message costs
  more: 1.6 µs of relay CPU a delivery with 1 or 2 loops, 2.2 µs with 4, 4.1 µs with 8. With 8 loops on 8 cores the
  loops also share every core with the network card's interrupt handling. And by 800 rooms the generator was using
  most of its 16 cores (184 s over 12 s is 15 cores), so it may be part of the limit there.

## Four more ideas, measured (Azure, two load VMs from here on)

**A second load VM.** With one generator, it was part of the limit at 8 loops: two (32 cores between them, each
using about 9) took 800 rooms from 1,855,900 deliveries a second at p99 5.8 ms to 2,377,016 at 3.4 ms, and 1,000 rooms
to 2,961,407 at 4.5 to 4.9 ms. `bench/azure.sh` makes two by default and splits the rooms between them.

**Holding queues back to batch more (tried, removed).** When a loop was busy, a connection's queue waited up to a set
time (100 to 500 µs) for more before it was sent. No gain at any load, saturated or not: CPU the same or higher,
latency the same. Each guest here gets a frame every millisecond, so a wait under one rarely catches a second; real
sessions are sparser still. The batching one loop gets comes from queuing for milliseconds, which is what more loops
are for avoiding.

**Pinning, and where the network card's interrupts go** (8 loops unless said; 400 / 800 rooms):

| Arrangement | 400 rooms p50 / p99 / p99.9 | 800 rooms p99 | Relay CPU at 400 |
| --- | --- | --- | --- |
| Loops unpinned, interrupts one per core (Azure's default) | 0.26 / 1.45 / 1.9 ms | 2.9 ms | 70.8 s |
| Loops pinned one per core (`--pin 0`) | 0.26 / 0.51 / 0.94 ms | 2.9 ms | 70.1 s |
| 6 loops on cores 2 to 7, interrupts on 0 and 1 | 66 / 143 / 185 ms | 524 ms | 15.5 s |
| The same, with RFS steering receives to the reading core | 1.6 / 55 / 85 ms | 60 ms | 55.6 s |

Pinning halves the tail. Giving interrupts cores of their own is a disaster: the kernel's per-packet work is most of
the work (what's counted as the relay's CPU is mostly that, done on its cores), and two cores can't do it. So:
interrupts spread over every core, as Azure sets them, and loops pinned, one to a core.

**io_uring (tried, removed).** Reads and sends batched, a submission for all of a turn's, to sockets registered once
(`IOSQE_FIXED_FILE`). It did what it's for: in a profile at 400 rooms, entering the kernel fell from 3.7% to 0.95%, and
`__fget_files` (2.3%) and `__sys_sendto` went. But the relay's CPU didn't move (83.2 s with epoll, 84.2 s with
io_uring), nor did throughput or latency:

| Rooms | epoll p50 / p99 | io_uring p50 / p99 | Relay CPU, epoll / io_uring |
| --- | --- | --- | --- |
| 400 | 0.24 / 0.43 ms | 0.22 / 0.40 ms | 70.7 / 72.3 s |
| 800 | 1.9 / 3.4 ms | 1.9 / 3.4 ms | 90.3 / 90.4 s |
| 1,000 | 2.4 / 4.1 ms | 2.4 / 3.8 ms | 92.1 / 93.5 s |

Its own submission and completion work took the place of the system calls'. For many small messages over many
sockets, the cost is TCP's per-message work, not the calls into it.

## Faster runs

`bench/azure.sh` looks the VMs' addresses up once (each Azure lookup took ~2 s, five a run), keeps one SSH connection
to each VM open between commands, and reports the relay's CPU as cores busy, so runs of any length compare. Three
seconds of load gives what ten did (two load VMs, `--pin 0`):

| Point | Delivered/s, 10 s / 3 s | p50 / p99, 10 s / 3 s | Cores busy, 10 s / 3 s |
| --- | --- | --- | --- |
| 8 loops, 1,000 rooms | 2,963,985 / 2,881,982 | 2.4, 4.1 / 2.4–2.7, 4.1 ms | 6.9 / 6.9 |
| 1 loop, 200 rooms | 599,298 / 597,993 | 2.9–3.2, 4.9 / same | 1.0 / 0.9 |
| 2 loops, 400 rooms | 1,196,587 / 1,188,060 | 3.2, 4.9–5.3 / same | 1.9 / 1.8 |

A run is now 6 to 7 seconds end to end, from 23.5. Memory is the exception: logs fill through a run, so it wants the
longer one.

## Backpressure under overload

Past what a loop can deliver, its queues grew without bound: at 1,600 rooms on one loop, ten seconds of load took
the relay to 2.6 GB, p50 to 1.4 s and p99 to 4.2 s, and the metrics endpoint stopped answering. Now a loop that takes
more than 20 ms over a turn stops reading its rooms' hosts until a turn takes under 5 ms again. Guests are still
read. The hosts' TCP windows close, so the changes wait in their sockets, not in the relay
(`hold_backs_total`, `hosts_held_back`).

One loop, two load VMs, 3 s, `--rate 1000`:

| Rooms | Hold-backs | Delivered/s, before / after | p50, before / after | p99, before / after | Memory, before / after |
| --- | --- | --- | --- | --- | --- |
| 1,000 | 0 | — / 2,915,521 | — / 36 ms | — / 78 ms | — / 497 MB |
| 1,600 | 53 | 2,197,252 / 2,987,701 | 0.81–1.05 / 0.48–0.57 s | 2.3 / 3.0–3.2 s | 766 / 590 MB |

Under capacity it never triggers. Over it, the loop delivers 36% more and holds less, because it stops spending turns
reading changes it can't yet pass on. The tail gets worse: a held host's changes wait out the hold in its socket
buffer, so p99 rises. Overload still means latency; what this bounds is the relay's memory and its time.

## Saturation by loop count, and the link

Each loop count pushed past its limit (two load VMs, `--pin 0`, `--rate 1000`, 3 s). The relay's network is now in
every run's report.

| Loops | Rooms | Delivered/s | p50 / p99 | Cores busy | Relay network in / out |
| --- | --- | --- | --- | --- | --- |
| 1 | 600 | 1,772,910 | 11 / 23–28 ms | 0.9 | 0.76 / 1.56 Gbit/s |
| 1 | 1,000 | 2,734,100 | 0.10 / 2.1–2.3 s | 0.9 | 1.10 / 2.24 Gbit/s |
| 1 | 1,400 | 2,656,621 | 0.12–0.14 / 2.3–2.5 s | 0.9 | 1.06 / 2.03 Gbit/s |
| 2 | 1,000 | 2,895,200 | 14 / 28 ms | 1.7 | 1.22 / 2.51 Gbit/s |
| 2 | 1,600 | 4,180,931 | 0.14–0.37 / 1.6–2.5 s | 1.7 | 1.60 / 3.46 Gbit/s |
| 2 | 2,200 | 4,014,043 | 0.22–0.26 / 3.0 s | 1.7 | 1.74 / 3.23 Gbit/s |
| 4 | 1,600 | 4,490,800 | 15 / 30 ms | 3.4 | 1.85 / 3.80 Gbit/s |
| 4 | 2,400 | 4,130,697 | 0.44–0.62 / 2.7 s | 3.1 | 2.00 / 4.47 Gbit/s |

One loop saturates at about 2.7M deliveries/s; two at about 4.2M (1.55×). Four loops weren't saturated at 1,600
rooms, and past that the generators were the limit: above about 1,200 rooms each they report nothing (4 loops at
3,200 rooms, all 8-loop runs), and their CPU is near full from 1,400 rooms in all. The thread-per-connection
generator tops out near 1.5M changes/s from two VMs, so scaling past two loops isn't measured yet.

The link isn't the limit. One saturated loop sent 2.0–2.2 Gbit/s, less than four loops did (3.8–4.5), and packets
stayed under 1.5M/s in. An earlier result, 8 loops at 1,000 rooms delivering the same 2.96M/s as 1 loop at
1,000 rooms, was the offered load, not either relay's limit.

## Event-loop generator, and capacity by loop count

The generator now runs as the relay does, an event loop a core with its share of the rooms. At 1,600 rooms it uses
about 4 of a load VM's 16 cores, where the thread-per-connection one used nearly all of them, and it reports rooms
that didn't open and connections that closed rather than going silent.

Saturated runs turned out a poor measure: hold-backs cycle on and off, and the warm-up's backlog lands in the window,
so they varied by a third run to run. Capacity is now the most a loop count sustains with every change delivered
and p99 within about 50 ms. Two load VMs, `--pin 0`, `--rate 1000`, 3 s. The relay machine's CPU is in cores, over
the whole run (opening the rooms included, so idle reads high).

| Loops | Rooms | Delivered/s | p50 / p99 | Packets in / out | Relay machine: user / system / interrupts / idle |
| --- | --- | --- | --- | --- | --- |
| 1 | 600 | 1,802,923 | 14–15 / 30–33 ms | 522k / 141k | 0.1 / 0.6 / 0.5 / 6.9 |
| 1 | 800 | 2,432,368 | 39–46 / 185–524 ms | 607k / 130k | 0.1 / 0.6 / 0.6 / 6.6 |
| 2 | 1,100 | 3,308,266 | 16–18 / 39–46 ms | 922k / 227k | 0.2 / 1.1 / 1.0 / 5.4 |
| 2 | 1,400 | 4,212,559 | 71–93 ms / 1.0–2.7 s | 971k / 189k | 0.2 / 1.0 / 1.4 / 5.3 |
| 4 | 1,600 | 4,810,924 | 16–18 / 36–85 ms | 1,378k / 368k | 0.3 / 1.7 / 2.5 / 3.6 |
| 4 | 2,000 | 6,041,279 | 51–60 ms / 0.4–3.0 s | 1,512k / 301k | 0.3 / 1.6 / 2.9 / 3.3 |
| 8 | 1,600 | 4,776,222 | 9 / 33 ms | 1,677k / 785k | 0.5 / 2.8 / 3.7 / 1.4 |
| 8 | 2,000 | 5,931,665 | 18–21 ms / 1.0–1.2 s | 1,829k / 532k | 0.4 / 2.3 / 4.1 / 1.6 |

| Loops | Capacity, deliveries/s | vs. one loop |
| --- | --- | --- |
| 1 | 1.8M | 1.0× |
| 2 | 3.3M | 1.8× |
| 4 | ~4.8M | 2.7× |
| 8 | ~4.8M | 2.7× |

Near linear to two loops; past four, nothing. The relay's own code isn't what fills the machine: at 8 loops it's half
a core of user time. The rest is the kernel: 2.8 cores of system calls and 3.7 of interrupts, the network's
receive work, at 1.7M packets a second in. With four loops the interrupts run on the four cores the loops leave;
with eight there are none to leave, so the loops and the kernel share the same eight cores, and the total is the
same.

The link isn't the limit: at most 5.4 Gbit/s out. Packets are. Every change is its own packet in, because each of
these hosts sends 1,000 a second with no delay. Real hosts send a few a second, so a real relay is limited first by
connections and their memory, not packets; this benchmark is a worst case for the network stack, and what it shows
is the stack's cost, not the relay's.

## Sixteen cores

The relay VM resized to a D16ps_v6 (16 cores, 16 network queues), same load VMs and method as above.

| Loops | Rooms | Delivered/s | p50 / p99 | Packets in / out | Relay machine: user / system / interrupts / idle |
| --- | --- | --- | --- | --- | --- |
| 4 | 2,000 | 6,006,937 | 9–12 / 28 ms | 1,694k / 620k | 0.4 / 2.2 / 2.3 / 11.2 |
| 8 | 2,000 | 5,966,284 | 5–6 / 14–18 ms | 2,019k / 1,312k | 0.6 / 3.9 / 2.8 / 9.1 |
| 8 | 2,400 | 7,204,240 | 6–10 / 46–156 ms | 2,305k / 1,140k | 0.6 / 3.7 / 3.6 / 8.2 |
| 12 | 2,400 | 7,243,922 | 16–18 ms / 1.5–1.6 s | 2,388k / 1,184k | 0.6 / 4.0 / 5.2 / 7.4 |
| 16 | 2,400 | 7,064,587 | 12–13 ms / 0.7–1.0 s | 2,607k / 1,469k | 0.9 / 5.5 / 6.1 / 4.7 |
| 16 | 4,000 | 10,312,550 | 110–120 ms / 2.5 s | 2,571k / 1,214k | 0.7 / 4.7 / 6.4 / 5.3 |

Capacity is about 7M deliveries/s, with 8 loops: 1.46× the 8-core VM's 4.8M for twice the cores. More loops than half
the cores is worse, not better: 12 and 16 loops miss the latency bound at 2,400 rooms, where 8 meet it, with the
machine still a third idle. Packets in level off near 2.6M a second however many loops there are.

A profile at 16 loops and 3,200 rooms (`profiles/16-loops-3200-rooms.txt`) is nearly all kernel: `_raw_spin_unlock_irqrestore`
8.5% (where the network's deferred work lands when interrupts are allowed again), the established-socket lookup for
each packet in 4.3%, copies 5.5%, spin locks 2.8%. The relay's own code is about 5%. More loops add more threads
contending for the same per-packet work, which is why the curve turns down.

Half the cores is the right number of loops on both machine sizes: on 8 cores, 4 matched 8; on 16, 8 beat 16.

## Uneven loops, and realistic rooms

**Realistic load.** Each host sends a change a second, and each of three guests five pointer updates a second (the
app sends up to 20 while the pointer moves, so a quarter of the time): about 48 deliveries per room a second, nearly
all pointer updates. Each load VM can open about 55k connections to one relay address, so two cap a test at about
27,000 rooms.

**The loops were uneven.** At 20,000 rooms latency jumped to a p99 of 0.3–1.1 s with the relay three-quarters idle.
Turns of 25–75 ms, nearly all of it sending, came from loops doing far more than their share: one VM's load at
10,000 rooms took 6.1, 4.7, 3.2, 2.2, 1.3, 0.8, 0.4 and 0.3 s of CPU on the eight loops. All of them waited on one
listening socket, Linux woke the same few first, and a room lives on the loop that accepted its host. On Linux each
loop now has its own listener on the port (`SO_REUSEPORT`), and the kernel spreads connections across them by
address: the same load took 2.6–2.8 s on every loop, and p99 fell from 46 to 23 ms. (macOS still shares one; its
kqueue wakes every loop.)

Realistic load, 8 loops on the 16-core relay, after the fix:

| Rooms | Connections | p50 / p99, each load VM | Pointer updates delivered | Relay memory | Relay machine: user / system / interrupts / idle |
| --- | --- | --- | --- | --- | --- |
| 10,000 | 40,000 | 8–10 / 12–15 ms | 98–100% | 296 MB | 0.3 / 1.6 / 2.1 / 12.9 |
| 20,000 | 80,000 | 16–21 / 23–30 ms | 87–100% | 659 MB | 0.4 / 2.1 / 2.3 / 11.7 |
| 26,000 | 104,000 | 21–30 ms / 46 ms–1.8 s | 69–100% | 728 MB | 0.4 / 2.2 / 2.2 / 11.6 |

At 26,000 rooms the second load VM gets every update with a p99 of 46 ms, and the first falls behind. Each alone
at its 13,000 rooms gets every update, p99 30–36 ms, and the relay's loops are about 75% busy and even, with no TCP
drops or memory pressure. A limit in the relay would hit both alike, so the first VM or its path is the limit here,
not the relay. Memory is about 7 KB a connection: CPU, not memory, decides how many rooms a relay holds.

The high-rate capacity, rerun with even loops:

| Loops | Rooms | Delivered/s | p99 | Relay machine: user / system / interrupts / idle |
| --- | --- | --- | --- | --- |
| 8 | 2,400 | 7,096,198 | 21 ms (was 46–156) | 0.6 / 3.3 / 4.4 / 8.0 |
| 8 | 3,200 | 9,231,596 | 78–185 ms | 0.6 / 3.2 / 4.7 / 7.6 |
| 16 | 3,200 | 9,603,831 | 78–202 ms | 1.0 / 6.1 / 6.3 / 3.3 |
| 16 | 4,000 | 11,615,448 | 1.5 s | 0.9 / 4.3 / 8.1 / 3.4 |

Capacity at 8 loops is now about 8M deliveries/s. Sixteen loops are no longer worse, but no better, with twice the
cores busy: half the cores stays the default.

## Past 27,000 rooms

Each load VM now has three addresses (`--sources`; `azure.sh` passes them all), about 165,000 connections each, and
a third load VM was added. Three fixes to the generator came out of it, each of which had skewed results:

- **Ports.** Bound to an address with port 0, Linux searched for a free port on every connection, slower as they
  filled: 50,000 rooms took minutes to open, and the first rooms' connections went silent and were dropped before
  the run began. `IP_BIND_ADDRESS_NO_PORT` leaves the port to `connect`.
- **Scanning.** Each loop looked over every connection on every turn, not once a millisecond: at 30,000 rooms a VM,
  that was most of its CPU.
- **Lockstep.** Every room's changes and every guest's pointer updates started in the same millisecond, so they
  came in bursts of all of them at once, five times a second. Each now starts at a random point in its interval,
  as people's do.

And one fix to the relay: **a host held back looked silent**, as nothing's read from it, and was dropped once the
hold outlasted the silence timeout. Held-back hosts now count as heard.

What holds up (8 loops, 16-core relay, two load VMs, 1 change a second per host, 5 pointer updates per guest):

| Rooms | Connections | p99 | Delivered | Relay |
| --- | --- | --- | --- | --- |
| 20,000 | 80,000 | 23–30 ms (three runs, before and after the refactor) | 90–100% | 3.4–3.8 cores busy, 0.5–1 GB |
| 30,000 | 120,000 | 36–71 ms once; 1.4–2.7 s in two later runs | 58–100% | 2.5–4.7 cores busy, 0.7–0.9 GB |
| 40,000+ | 160,000+ | seconds | 60–95% | 4–6 cores busy, 0.9–1.5 GB |

Above 20,000 rooms the runs don't agree with each other, and both sides show strain: the relay's loops take
25–36 ms over some turns (16–133 hold-backs a run) though they're 40% idle on average, and the first load VM falls
further behind than the second every time. The third VM made the other two worse when it joined, at 20,000 rooms
as well, so the measurements above leave it out. The ceiling is somewhere between 20,000 and 40,000 rooms per
16-core relay; the rig doesn't yet say where.
