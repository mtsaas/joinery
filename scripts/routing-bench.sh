#!/bin/sh
# Times routing on big models (see scripts/RoutingBench/main.swift), compiled on its own: optimized, or with -Onone as
# a Debug build is, to see what running from Xcode costs.
# Usage: scripts/routing-bench.sh [-Onone] [model.joinery …]
set -e
cd "$(dirname "$0")/.."
level=-O
if [ "$1" = "-Onone" ]; then level=-Onone; shift; fi
out="${TMPDIR:-/tmp}/joinery-routing-bench$level"
swiftc $level -D DEBUG -o "$out" Joinery/Document/DataModel.swift Joinery/Document/DataModel+Editing.swift Joinery/Document/Ports.swift \
  Joinery/Document/Placement.swift Joinery/Debug/SyntheticModel.swift Joinery/Canvas/Geometry.swift Joinery/Canvas/Metrics.swift \
  Joinery/Canvas/Routing.swift Joinery/Canvas/WireSimulation.swift scripts/RoutingBench/main.swift
"$out" "$@"
