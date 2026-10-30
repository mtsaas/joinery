#!/bin/bash
# Runs the load scenarios, each against a fresh ReleaseSafe relay, and prints a row for each: what was delivered, how
# fast, and what it cost the relay. Usage: bench/load.sh [label]    (from relay/)
set -e
zig build -Doptimize=ReleaseSafe
zig build load -- --port 1 --rooms 0 > /dev/null 2>&1 || true   # built before timing anything
scenarios=(
  "throughput|--rooms 100 --guests 3 --rate 1000"
  "fan-out|--rooms 10 --guests 31 --rate 400"
  "connections|--rooms 1000 --guests 3 --rate 5"
  "pointers|--rooms 200 --guests 7 --rate 5 --presence 30"
)
echo "## ${1:-run} ($(git rev-parse --short HEAD), $(date +%Y-%m-%d))"
echo
echo "| Scenario | Changes delivered/s | p50 | p99 | Pointer updates/s | Pointer updates replaced | Relay CPU s | Relay RSS MB | Threads |"
echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
for scenario in "${scenarios[@]}"; do
  name=${scenario%%|*}; args=${scenario#*|}
  ./zig-out/bin/joinery-relay --port 8796 --metrics-port 9196 --max-rooms 100000 --max-connections 100000 > /tmp/load-relay.log 2>&1 &
  relay=$!
  sleep 0.5
  out=$(zig build load -- --port 8796 $args --seconds 10 2>&1)
  # Peak memory isn't kept by ps; this is what it holds at the end, with every room still open.
  read cpu rss <<< "$(ps -o cputime=,rss= -p $relay)"
  threads=$(ps -M -p $relay | tail -n +2 | wc -l | tr -d ' ')
  replaced=$(curl -s http://127.0.0.1:9196/metrics | sed -n 's/^joinery_relay_pointers_replaced_total //p')
  kill $relay; wait $relay 2>/dev/null || true
  delivered=$(echo "$out" | sed -n 's/^published.*delivered \([0-9]*\)\/s.*/\1/p')
  p50=$(echo "$out" | sed -n 's/.*p50 \([0-9]*\) µs.*/\1/p'); p99=$(echo "$out" | sed -n 's/.*p99 \([0-9]*\) µs.*/\1/p')
  pointers=$(echo "$out" | sed -n 's/pointer updates delivered \([0-9]*\)\/s (\([0-9]*\)% .*/\1 (\2%)/p')
  echo "| $name | $delivered | ${p50} µs | ${p99} µs | $pointers | ${replaced:-0} | $cpu | $((rss / 1024)) | $threads |"
done
