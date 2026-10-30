#!/bin/sh
# Builds Joinery's core (the Swift package at the repository root) to WebAssembly, into core/, for the app to load.
# Needs a swift.org toolchain and its WebAssembly SDK; SWIFT_SDK names the SDK (`swift sdk list`).
set -eu
cd "$(dirname "$0")/../.."
sdk=${SWIFT_SDK:-$(swift sdk list | grep -E '_wasm$' | head -1)}
# On a Mac, Xcode's swift comes first on the PATH but can't use the SDK: use the swift.org toolchain it matches.
toolchain=~/Library/Developer/Toolchains/${sdk%_wasm}.xctoolchain/usr/bin
[ -d "$toolchain" ] && PATH=$toolchain:$PATH
swift package --swift-sdk "$sdk" --scratch-path .build/wasm js -c release
rm -rf desktop/core-pkg
cp -R .build/wasm/plugins/PackageToJS/outputs/Package desktop/core-pkg
echo "Built the core: desktop/core-pkg"
