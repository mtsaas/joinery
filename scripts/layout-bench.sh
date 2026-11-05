#!/bin/sh
# Compares layouts with and without refining (see scripts/LayoutBench/main.swift), compiled on its own and optimized.
# Usage: scripts/layout-bench.sh [model.joinery …]
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/joinery-layout-bench"
swiftc -O -D DEBUG -o "$out" Joinery/Document/DataModel.swift Joinery/Document/DataModel+Editing.swift Joinery/Document/Ports.swift \
  Joinery/Document/Placement.swift Joinery/Document/AutoLayout.swift Joinery/Document/LayeredLayout.swift Joinery/Document/Untangler.swift Joinery/Debug/SyntheticModel.swift \
  Joinery/Document/Geometry.swift Joinery/Document/Metrics.swift scripts/LayoutBench/main.swift
"$out" "$@"
