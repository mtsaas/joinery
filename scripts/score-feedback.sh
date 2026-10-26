#!/bin/sh
# Scores the current routing against exported routing feedback (Debug ▸ Export Routing Feedback…).
# Usage: scripts/score-feedback.sh routing-feedback.json
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/joinery-score-feedback"
swiftc -O -o "$out" Joinery/Document/DataModel.swift Joinery/Document/DataModel+Editing.swift Joinery/Document/DataModelFile.swift \
  Joinery/Canvas/Geometry.swift Joinery/Canvas/Metrics.swift Joinery/Canvas/Routing.swift Joinery/Canvas/WireSimulation.swift \
  Joinery/Canvas/ZipTying.swift scripts/ScoreFeedback/main.swift
"$out" "${1:?exported feedback file}"
