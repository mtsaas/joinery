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
