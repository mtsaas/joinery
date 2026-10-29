# Load results

`bench/load.sh` on an Apple M5 Pro, the relay (ReleaseSafe) and the load generator on the same machine, so the
relay's numbers are conservative. Each scenario runs 10 seconds against a fresh relay; CPU is the relay's over the
whole run, RSS and threads at its end, with every room still open.

- **throughput:** 100 rooms, a host and 3 guests each, 1,000 changes a second per room.
- **fan-out:** 10 rooms of 31 guests, 400 changes a second per room.
- **connections:** 1,000 rooms of a host and 3 guests (4,000 connections), 5 changes a second per room.
- **pointers:** 200 rooms of a host and 7 guests, 5 changes a second, every guest's pointer moving 30 times a second
  (294,000 pointer updates a second to deliver).

## Before: a thread pair per connection, one lock (f1de0b2)

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,788 | 4,330 µs | 9,550 µs | 0 | 43.5 | 179 | 803 |
| fan-out | 123,870 | 180 µs | 720 µs | 0 | 22.0 | 39 | 643 |
| connections | 13,665 | 440 µs | 100,000+ µs | 0 | 18.8 | 515 | 8,003 |
| pointers | 6,833 | 3,270 µs | 100,000+ µs | 202,599 (69%) | 36.5 | 181 | 3,203 |

## Event loop: one thread, the OS's event queue, no lock

| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Relay CPU s | Relay RSS MB | Threads |
| --- | --- | --- | --- | --- | --- | --- | --- |
| throughput | 298,701 | 1,830 µs | 5,790 µs | 0 | 9.4 | 140 | 1 |
| fan-out | 123,935 | 200 µs | 3,940 µs | 0 | 4.1 | 8 | 1 |
| connections | 12,995 | 430 µs | 19,650 µs | 0 | 2.1 | 132 | 1 |
| pointers | 6,834 | 5,850 µs | 32,060 µs | 206,907 (86% of what the generator sent) | 7.9 | 28 | 1 |

4.6 to 9 times less CPU for the same work, one thread instead of 800 to 8,000, and a quarter of the memory with
4,000 connections. Fan-out's p99 is worse (0.72 to 3.9 ms): one thread now makes a frame's 31 sends in turn, where 31
writer threads made them at once. In the pointers scenario the relay used 65% of a core; the load generator, with
thousands of threads of its own, couldn't send all 42,000 pointer updates a second (it managed about 34,500) or read
what came back fast enough, so pointer updates queued up in the relay.
