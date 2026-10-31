#!/bin/bash
# Smoke test for both apps: builds each, opens Storefront in a throwaway library, has an AI assistant add a table over
# MCP, checks it's in the model and saved to disk, and snapshots the canvas.
# Usage: scripts/smoke.sh [mac|desktop]   (both by default on a Mac, desktop elsewhere) → snapshots in /tmp/joinery-smoke
set -u
cd "$(dirname "$0")/.."
out=${JOINERY_SMOKE_OUT:-/tmp/joinery-smoke}
rm -rf "$out" && mkdir -p "$out"
which=${1:-$([ "$(uname)" = Darwin ] && echo "mac desktop" || echo desktop)}
table='{"tables":[{"name":"smoke_check","columns":[{"name":"id","type":"uuid","primary_key":true},{"name":"user_id","type":"uuid","references":"users"}]}]}'
failures=0

check() { # check <what> <command…>
  if "${@:2}" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi
}

mac() {
  echo "Mac app"
  scripts/build.sh "$out/mac-build" >"$out/mac-build.log" 2>&1 || { echo "  FAIL  build (see $out/mac-build.log)"; failures=$((failures + 1)); return; }
  JOINERY_LIBRARY="$out/mac-library" JOINERY_OPEN=Storefront JOINERY_SNAPSHOT="$out/mac.png" JOINERY_SNAPSHOT_DELAY=4 \
    JOINERY_SCRIPT="mcp create_tables $table;mcp get_model {}" \
    "$out/mac-build/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery" -ApplePersistenceIgnoreState YES \
    >"$out/mac.log" 2>&1
  check "assistant's edit applied" grep -q "^mcp: .*smoke_check" "$out/mac.log"
  check "no failed tool calls" bash -c "! grep -q 'mcp failed' '$out/mac.log'"
  check "saved to disk" grep -rq smoke_check "$out/mac-library"
  check "snapshot" test -s "$out/mac.png"
}

desktop() {
  echo "Windows/Linux app"
  # CI builds the core once, in its own job; JOINERY_SMOKE_CORE=prebuilt uses that.
  (cd desktop && { [ "${JOINERY_SMOKE_CORE:-}" = prebuilt ] || npm run core; } && npx tauri build --debug --no-bundle) >"$out/desktop-build.log" 2>&1 ||
    { echo "  FAIL  build (see $out/desktop-build.log)"; failures=$((failures + 1)); return; }
  bin=desktop/src-tauri/target/debug/joinery
  [ -f "$bin.exe" ] && bin=$bin.exe
  port=8790
  JOINERY_LIBRARY="$out/desktop-library" JOINERY_MCP_PORT=$port JOINERY_OPEN=Storefront \
    JOINERY_SNAPSHOT="$out/desktop.png" JOINERY_SNAPSHOT_DELAY=4 "$bin" >"$out/desktop.log" 2>&1 &
  pid=$!
  mcp() {
    curl -s -m 10 "http://127.0.0.1:$port/mcp" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
  }
  for _ in $(seq 60); do mcp initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}' | grep -q protocolVersion && break; sleep 1; done
  mcp tools/call "{\"name\":\"create_tables\",\"arguments\":$table}" >"$out/desktop-mcp.log"
  mcp tools/call '{"name":"get_model","arguments":{}}' >>"$out/desktop-mcp.log"
  # It quits itself after the snapshot; don't wait forever if it hangs.
  for _ in $(seq 30); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  kill $pid 2>/dev/null
  check "assistant's edit applied" grep -q smoke_check "$out/desktop-mcp.log"
  check "no failed tool calls" bash -c "! grep -q '\"isError\":true' '$out/desktop-mcp.log'"
  check "saved to disk" grep -rq smoke_check "$out/desktop-library"
  check "snapshot" test -s "$out/desktop.png"
  check "no failure shown" bash -c "grep -q '^snapshot: Storefront' '$out/desktop.log' && ! grep -q 'failure:' '$out/desktop.log'"
}

for app in $which; do $app; done
echo "Snapshots and logs: $out"
[ $failures -eq 0 ] && echo "Smoke test passed." || { echo "$failures check(s) failed."; exit 1; }
