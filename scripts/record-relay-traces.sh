#!/bin/bash
# Records what the Swift relay (RelayCore) hears and does in the simulation, into relay/src/testdata, for the Zig relay's
# replay test. Run from the repository root after changing the protocol, then commit the traces.
set -euo pipefail
out=/tmp/joinery-traces
rm -rf "$out" && mkdir -p "$out"
xcodebuild test -project Joinery.xcodeproj -scheme Joinery -derivedDataPath /tmp/joinery-unit \
  -packageCachePath /tmp/joinery-spm-cache -resultBundlePath "$out/result.xcresult" \
  '-only-testing:JoineryTests/RelaySimulation/recordsTracesForTheZigRelay()' -quiet
xcrun xcresulttool export attachments --path "$out/result.xcresult" --output-path "$out/attachments"
# The export names files by UUID; its manifest maps them back.
python3 - "$out/attachments" relay/src/testdata <<'PY'
import json, os, re, shutil, sys
src, dst = sys.argv[1:]
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for a in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-F-]+(?=\.trace$)", "", a["suggestedHumanReadableName"])
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, name))
        print(name, os.path.getsize(os.path.join(dst, name)))
PY
