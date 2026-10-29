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
