#!/bin/bash
# The app's tests against the Zig relay, on this Mac: starts three relays (with presence over UDP, without, and with
# UDP blocked: tickets name a port nothing listens on), runs the tests with their addresses (JoineryTests/UdpTests.swift,
# ZigRelayTests), and stops them. Passes extra arguments to xcodebuild, as -only-testing:JoineryTests/ZigRelayTests.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd relay && zig build -Doptimize=ReleaseSafe)
relay=relay/zig-out/bin/joinery-relay
logs=$(mktemp -d)
$relay --port 18787 --metrics-port 19187 --threads 2 --udp on > "$logs/udp.log" 2>&1 & pids=$!
$relay --port 18788 --metrics-port 19188 --threads 2 > "$logs/tcp.log" 2>&1 & pids="$pids $!"
$relay --port 18789 --metrics-port 19189 --threads 2 --udp on --udp-port 18799 > "$logs/blocked.log" 2>&1 & pids="$pids $!"
trap 'kill $pids 2>/dev/null; echo "relay logs: $logs"' EXIT
sleep 0.5
# xcodebuild hands the tests what's in its environment named TEST_RUNNER_*, without the prefix.
TEST_RUNNER_JOINERY_RELAY_UDP=http://127.0.0.1:18787 TEST_RUNNER_JOINERY_RELAY_UDP_METRICS=http://127.0.0.1:19187 \
TEST_RUNNER_JOINERY_RELAY_TCP=http://127.0.0.1:18788 TEST_RUNNER_JOINERY_RELAY_BLOCKED=http://127.0.0.1:18789 \
xcodebuild -project Joinery.xcodeproj -scheme Joinery test -derivedDataPath /tmp/joinery-tests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.mtsaas.joinery.unittest "$@"
