#!/bin/sh
# Builds an unsandboxed, ad-hoc-signed Debug copy for command-line checks (sandboxing would block reading sample files
# and writing snapshots), without the hardened runtime (which would refuse Sparkle's differently signed framework). For everyday work, open Joinery.xcodeproj and press ⌘R.
# Usage: scripts/build.sh <derived-data-dir> [build settings…]    → <dir>/Build/Products/Debug/Joinery.app
set -e
cd "$(dirname "$0")/.."
derived=${1:?derived data dir}
shift
xcodebuild -project Joinery.xcodeproj -scheme Joinery -configuration Debug -derivedDataPath "$derived" "$@" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.mtsaas.joinery.test -quiet build
