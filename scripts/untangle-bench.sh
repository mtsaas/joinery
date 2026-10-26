#!/bin/sh
# Compares tunings of untangling (see scripts/UntangleBench/main.swift), compiled on its own and optimized.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/joinery-untangle-bench"
swiftc -O -D DEBUG -o "$out" Joinery/Document/DataModel.swift Joinery/Document/DataModel+Editing.swift \
  Joinery/Document/Untangler.swift Joinery/Debug/SyntheticModel.swift Joinery/Canvas/Geometry.swift Joinery/Canvas/Metrics.swift \
  scripts/UntangleBench/main.swift
"$out"
