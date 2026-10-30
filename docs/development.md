# Developing Joinery

Joinery needs macOS 26 and Xcode 26. Open `Joinery.xcodeproj` and press ⌘R; ⌘U runs the tests. Debug builds share the
installed app's bundle ID, so they open your real library; quit the installed copy first.

From the command line, sign ad hoc and without the hardened runtime, which would refuse Sparkle's differently signed
framework, and with a bundle ID of its own: the test runner hangs if a copy with the same one is open. About 50 seconds
from clean, 15 after a change:

```sh
xcodebuild -project Joinery.xcodeproj -scheme Joinery test -derivedDataPath /tmp/joinery-tests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.mtsaas.joinery.unittest
```

The relay, in `relay/`, has its own [README](../relay/README.md).

## The code

```
Joinery/
  Document/        The core: the data model, its edits, layout and geometry, files, and the replica its changes are ops on
  Collaboration/
    Protocol/      The core of live sessions: the host's and guest's sides as state machines, the wire format, sealing,
                   digests, and RelayCore, the Swift relay the tests run
    Transport/     Sessions on the network: the WebSocket, and the host and client that connect the protocol to the app
    UI/            Share and Join panels, people, and others' pointers on the canvas
  Library/         The library of files and collections, the open data model, its editor and version history
  Canvas/          Canvas view, table drawing, routing, wire physics, zip tying
  MCP/
    Protocol/      The MCP server for AI assistants, but for its socket: HTTP, JSON-RPC, and the data model tools
                   (MCPServer.swift is the Mac's socket and library tools)
  App/             App entry, menu commands, settings, debug hooks
  Debug/           Routing feedback mode, the frame-rate readout, made-up data models (Debug builds only)
  Examples/        The bundled example data models
JoineryTests/      Swift Testing: the data model, routing and physics, undo, the library, sessions (with a simulation)
relay/             The relay, in Zig, and its Helm chart
desktop/           Joinery for Windows and Linux: the core in WebAssembly, a TypeScript canvas, and a Tauri shell
docs/              guide.md, relay.md (the session protocol, and why it's correct), this
scripts/           Builds, benchmarks and the release
```

**The core stands alone.** `Document/`, `Collaboration/Protocol/` and `MCP/Protocol/` are plain state and state
machines: Foundation, CoreGraphics, CryptoKit and UniformTypeIdentifiers only, and nothing from the main actor, the
network, the screen or the rest of the app. So the protocol can be simulated across every core with no network at all,
and the core can be built for other platforms (CryptoKit's API is `swift-crypto` elsewhere). `scripts/check_layers.sh`,
run in CI, fails if anything in the core reaches outside it.

**Wires** work in two steps. `Routing` computes each wire's rest curve, Bézier segments from socket to socket through
its zip ties. `WireSimulation` then springs a chain of points toward it, stiff at the ends and loose in the middle, only
while something moves. Routes are reused until their ends, ties or nearby tables move, and wires bending around tables
are routed across the cores. Tables are drawn in one layer (`TableLayer`), only those in view, with text laid out once
per string.

## Checking from the command line

Debug builds have hooks for driving the app without clicking (`App/DebugHooks.swift` lists them all): a library folder
of its own, a model to open, scripted steps, and a snapshot of the window.

```sh
scripts/build.sh /tmp/joinery-dd
JOINERY_LIBRARY=/tmp/joinery-library JOINERY_OPEN=Sakila JOINERY_SCRIPT="tie 320 -20 320 140" JOINERY_SNAPSHOT=/tmp/out.png \
  /tmp/joinery-dd/Build/Products/Debug/Joinery.app/Contents/MacOS/Joinery
```

`scripts/build.sh` builds an unsandboxed, ad-hoc-signed Debug copy with its own bundle ID, so it can read sample files
and write snapshots, and never touches the real library.

## Performance

- **Frame rate:** Debug builds show frames per second while anything moves, and what the last frame cost.
  `JOINERY_SCRIPT="shake <table> <seconds>"` drags a table about and prints frame stats.
- **Scale test:** `scripts/scale-test.sh` drags a table about in made-up models of 10 to 200 tables, zoomed to fit and
  at 50%, with wires under tables and avoiding them. At 200 tables and 300 keys, avoiding tables, a drag holds 120 fps.
- **Routing alone:** `scripts/routing-bench.sh [-Onone] [model.joinery …]`. The Debug configuration is optimized (`-O`),
  because unoptimized routing is 15 to 30 times slower; set it back to `-Onone` to step through code.
- **Layout and untangling:** `scripts/layout-bench.sh` and `scripts/untangle-bench.sh`.

## Routing feedback (Debug builds)

Debug ▸ Routing Feedback Mode (⌥⌘R) records how a cable *should* run: click a cable, drag the points of its grey copy
to where it should go, add a note, and press Return. Each correction keeps the whole model, the routing version and
both lines. Debug ▸ Export Routing Feedback… writes them to one file, and `scripts/score-feedback.sh <file>` replays every
case against the current routing.

## Windows and Linux

`desktop/` is Joinery for Windows and Linux. It runs the same Swift core as the Mac app, compiled to WebAssembly, so a
model, an edit, a session or an assistant's tool call behaves the same on every platform.

```
desktop/
  core/            The core's folders, linked in from Joinery/, and Bridge/: the open model with its undo, the scene
                   the canvas draws, each frame's wires, edits by name, sessions and MCP, exported to JavaScript
  src/             The window, in TypeScript and Preact: the canvas (drawn as the Mac's TableLayer and CanvasView draw
                   it), the library sidebar, panels, the WebSocket a session runs over, and the library tools for MCP
  src-tauri/       The shell, in Rust: the library on disk, in the Mac's own format, and MCP's socket
  tests/           The core as the app drives it, in Node, and a session between two copies through the relay
```

The core can't reach the network or the disk in WebAssembly, so the shell does: the window holds the session's
WebSocket and hands its bytes to the core, and the Rust side keeps the `.joinery` packages, their versions and the
review's baseline. Models move between a Mac and a PC as the same files. The library is `Documents\Joinery` on Windows
and `~/Documents/Joinery` on Linux; favorites and when each was last opened are in its `.library.json`, as the Mac keeps
them on the files themselves.

**Building it** needs the swift.org toolchain and its WebAssembly SDK (Xcode's Swift can't build for WebAssembly), Rust,
and Node. With the toolchain installed under `~/Library/Developer/Toolchains`:

```sh
export PATH=~/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin:$PATH
swift sdk install https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5
cd desktop
npm ci
npm run core          # the core to WebAssembly, into core-pkg/: about 3 minutes
npx tauri dev         # the app, in its own window, reloading as src/ changes
npm run dev           # or just the window, in a browser, with a library kept in memory
```

`JOINERY_LIBRARY` points the app at another library folder, and `JOINERY_MCP_PORT` moves MCP off 8723, so it can run
beside the Mac app. The WebAssembly module is about 47 MB, most of it Foundation's internationalization data; installed,
that loads from disk, and the installer compresses it to about 18 MB.

**Testing:** `npm test` in `desktop/` opens examples, edits and undoes, reviews, answers MCP, and shares a model
between two copies of the core through the relay. That last test needs the relay built (`zig build` in `relay/`) and is
skipped without it. `cargo test` in `desktop/src-tauri` checks the library's paths, names and version thinning.

## Releases

[release-please](https://github.com/googleapis/release-please) makes releases from commit messages in the
[Conventional Commits](https://www.conventionalcommits.org) style: `fix:` or `feat:`, with `(relay)` or a change under
`relay/` for the relay, or under `desktop/` for Windows and Linux. It keeps a release pull request open for each of
Joinery, the relay and the desktop app; merging one makes the release. A change to the core is Joinery's, and the
desktop app picks it up in its next release. Below 1.0, a breaking change bumps the minor version.

- **Joinery** (`joinery-v…`): the release workflow builds it, signs it and its Sparkle helpers with a Developer ID, has
  Apple notarize it, lays out the disk image with `dmgbuild` (`scripts/dmg.py`), and attaches it to the release. It adds
  it to Sparkle's update feed, `appcast.xml`, on the `updates` release, where `Joinery.dmg` is always the newest. That
  release is never the latest, so relay releases can't take its place. Copies built in Xcode don't check for updates.
- **The relay** (`relay-v…`): the image `ghcr.io/mtsaas/joinery-relay` and the chart
  `oci://ghcr.io/mtsaas/charts/joinery-relay`, at the release's version. Every push to `main` also publishes `:main`.

- **Joinery for Windows and Linux** (`desktop-v…`): the Desktop workflow builds the core, tests it, and builds the
  NSIS and MSI installers on Windows and the .deb and AppImage on Linux, and attaches them to the release. With the
  updater key set, it also signs the update files and puts `latest.json` on the `desktop-updates` release, which
  released copies check at launch. The installers aren't code-signed yet, so Windows shows a SmartScreen warning (More
  info, then Run anyway); `bundle.windows.signCommand` in the workflow's build step is where signing goes.

`gh workflow run Release -f version=<x.y.z>` builds Joinery again for a release that's been made, after a failed build.
`scripts/package-app.sh` is what the workflow runs. Signing needs these repository secrets:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD` | The Developer ID Application certificate and key, as a base64 .p12, and its password |
| `APPLE_TEAM_ID` | The team it belongs to |
| `NOTARY_API_KEY`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER` | An App Store Connect API key (the .p8's contents), its ID and issuer, to notarize |
| `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | The Windows and Linux app's updater key and its password. Without them, installers are built but released copies aren't offered updates |
| `SPARKLE_PRIVATE_KEY` | Sparkle's private key, kept in the login keychain under the account `mtsaas-joinery` (`generate_keys --account mtsaas-joinery -x <file>`). Joinery installs only updates signed with it |

**The desktop updater key.** Make it once, keep the private key somewhere safe, and put the public key in the app:

```sh
npx --prefix desktop tauri signer generate -w ~/.tauri/joinery-desktop.key
gh secret set TAURI_SIGNING_PRIVATE_KEY < ~/.tauri/joinery-desktop.key
gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD
```

Then replace `REPLACE_WITH_THE_UPDATER_PUBLIC_KEY` in `desktop/src-tauri/tauri.conf.json` with the contents of
`~/.tauri/joinery-desktop.key.pub`, and commit it. Copies only install updates signed with the matching private key, so
a lost key means people download the next version by hand.

**Rotating keys.** Sparkle accepts an update that changes the Sparkle key or the Developer ID certificate, never both
at once. To change the Sparkle key, release once with the new public key in `Info.plist` while still signing with the
old one, then switch `SPARKLE_PRIVATE_KEY`. If the key is lost, change both in one release: the unchanged Developer ID
certificate carries the trust. Renew the certificate in a release that keeps the key.
