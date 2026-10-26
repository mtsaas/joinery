#!/bin/sh
# How dragging a table holds up as schemas grow: for each size, a made-up schema (the same every run) is opened and a
# table in its middle dragged about for three seconds, zoomed to fit (where big schemas are too small for text) and at
# 50% (where dozens of tables show theirs), with wires running under tables and then avoiding them.
# Prints frames per second, our own work per frame (routing, and drawing the wires) and the whole view update each move
# causes, drawing the tables and SwiftUI's own work included. 120 fps is a 120 Hz display's limit; work and update together over 8.3 ms miss a frame.
# Usage: scripts/scale-test.sh [derived-data-dir] ["tables:keys ..."]
set -e
cd "$(dirname "$0")/.."
derived=${1:-/tmp/joinery-scale}
sizes=${2:-"10:12 25:35 50:75 100:150 200:300"}
# Optimized like a release build, with the debug hooks the test drives it by: unoptimized Swift is several times
# slower at the routing and simulation's arithmetic.
scripts/build.sh "$derived" SWIFT_OPTIMIZATION_LEVEL=-O
app="$derived/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery"

echo "| tables | keys | zoom | avoid | fps | work per frame (median, worst) | update (median, worst) |"
echo "| ---: | ---: | ---: | :---: | ---: | --- | --- |"
for size in $sizes; do
  tables=${size%%:*} keys=${size##*:}
  for zoom in fit 0.5; do
  for avoid in NO YES; do
    # A folder that doesn't exist yet, so the library starts with the examples to open.
    scratch=$(mktemp -d) library="$scratch/library"
    line=$(JOINERY_LIBRARY="$library" JOINERY_OPEN=Storefront \
      JOINERY_SCRIPT="generate $tables $keys;$([ $zoom = fit ] || echo "focus t$((tables / 2)) $zoom;")wait 1.5;shake t$((tables / 2)) 3;quit" \
      "$app" -ApplePersistenceIgnoreState YES -wiresAvoidTables $avoid 2>&1 | grep '^shake:' || echo "shake: failed")
    rm -rf "$scratch"
    avoids=$([ $avoid = YES ] && echo yes || echo no)
    echo "$line" | sed -E "s/^shake: ([0-9]+) fps, work per frame ([0-9.]+) ms median, ([0-9.]+) ms worst \| update ([0-9.]+) ms median, ([0-9.]+) ms worst$/| $tables | $keys | $zoom | $avoids | \1 | \2, \3 ms | \4, \5 ms |/"
  done
  done
done
