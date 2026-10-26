#!/bin/sh
# How dragging a table holds up as schemas grow: for each size, a made-up schema (the same every run) is opened and a
# table in its middle dragged about for three seconds, with wires running under tables and then avoiding them.
# Prints frames per second, our own work per frame (routing and drawing wires) and the whole update a move causes,
# SwiftUI included. 120 fps is the display's limit; a whole update over 8.3 ms misses a 120 Hz frame.
# Usage: scripts/scale-test.sh [derived-data-dir] ["tables:keys ..."]
set -e
cd "$(dirname "$0")/.."
derived=${1:-/tmp/joinery-scale}
sizes=${2:-"10:12 25:35 50:75 100:150 200:300"}
scripts/build.sh "$derived"
app="$derived/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery"

echo "| tables | keys | avoid | fps | work/frame (median, worst) | whole update (median, worst) |"
echo "| ---: | ---: | :---: | ---: | --- | --- |"
for size in $sizes; do
  tables=${size%%:*} keys=${size##*:}
  for avoid in NO YES; do
    # A folder that doesn't exist yet, so the library starts with the examples to open.
    scratch=$(mktemp -d) library="$scratch/library"
    line=$(JOINERY_NO_SIDEBAR=1 JOINERY_LIBRARY="$library" JOINERY_OPEN=Storefront \
      JOINERY_SCRIPT="generate $tables $keys;wait 1.5;shake t$((tables / 2)) 3;quit" \
      "$app" -ApplePersistenceIgnoreState YES -wiresAvoidTables $avoid 2>&1 | grep '^shake:' || echo "shake: failed")
    rm -rf "$scratch"
    echo "$line" | sed -E "s/^shake: ([0-9]+) fps, work per frame ([0-9.]+) ms median, ([0-9.]+) ms worst \| whole update ([0-9.]+) ms median \(layout [0-9.]+\), ([0-9.]+) ms worst$/| $tables | $keys | $([ $avoid = YES ] && echo yes || echo no) | \1 | \2, \3 ms | \4, \5 ms |/"
  done
done
