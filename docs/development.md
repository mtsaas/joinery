# Developing Joinery

Joinery needs macOS 26 and Xcode 26. Open `Joinery.xcodeproj` and press ⌘R; ⌘U runs the tests. Debug builds share the
installed app's bundle ID, so they open your real library; quit the installed copy first.

From the command line, sign ad hoc and without the hardened runtime, which would refuse Sparkle's differently signed
framework. About 50 seconds from clean, 15 after a change:

```sh
xcodebuild -project Joinery.xcodeproj -scheme Joinery test \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO
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
  MCP/             The MCP server for AI assistants, and its data model tools
  App/             App entry, menu commands, settings, debug hooks
  Debug/           Routing feedback mode, the frame-rate readout, made-up data models (Debug builds only)
  Examples/        The bundled example data models
JoineryTests/      Swift Testing: the data model, routing and physics, undo, the library, sessions (with a simulation)
relay/             The relay, in Zig, and its Helm chart
docs/              guide.md, relay.md (the session protocol, and why it's correct), this
scripts/           Builds, benchmarks and the release
```

**The core stands alone.** `Document/` and `Collaboration/Protocol/` are plain state and state machines: Foundation,
CoreGraphics and UniformTypeIdentifiers only, and nothing from the main actor, the network, the screen or the rest of
the app. So the protocol can be simulated across every core with no network at all. `scripts/check_layers.sh` fails if
anything in the core reaches outside it.

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

## Releases

[release-please](https://github.com/googleapis/release-please) makes releases from commit messages in the
[Conventional Commits](https://www.conventionalcommits.org) style: `fix:` or `feat:`, with `(relay)` or a change under
`relay/` for the relay. It keeps a release pull request open for each of Joinery and the relay; merging one makes the
release. Below 1.0, a breaking change bumps the minor version.

- **Joinery** (`joinery-v…`): the release workflow builds it, signs it and its Sparkle helpers with a Developer ID, has
  Apple notarize it, lays out the disk image with `dmgbuild` (`scripts/dmg.py`), and attaches it to the release. It adds
  it to Sparkle's update feed, `appcast.xml`, on the `updates` release, where `Joinery.dmg` is always the newest. That
  release is never the latest, so relay releases can't take its place. Copies built in Xcode don't check for updates.
- **The relay** (`relay-v…`): the image `ghcr.io/mtsaas/joinery-relay` and the chart
  `oci://ghcr.io/mtsaas/charts/joinery-relay`, at the release's version. Every push to `main` also publishes `:main`.

`gh workflow run Release -f version=<x.y.z>` builds Joinery again for a release that's been made, after a failed build.
`scripts/package-app.sh` is what the workflow runs. Signing needs these repository secrets:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD` | The Developer ID Application certificate and key, as a base64 .p12, and its password |
| `APPLE_TEAM_ID` | The team it belongs to |
| `NOTARY_API_KEY`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER` | An App Store Connect API key (the .p8's contents), its ID and issuer, to notarize |
| `SPARKLE_PRIVATE_KEY` | Sparkle's private key, kept in the login keychain under the account `mtsaas-joinery` (`generate_keys --account mtsaas-joinery -x <file>`). Joinery installs only updates signed with it |

**Rotating keys.** Sparkle accepts an update that changes the Sparkle key or the Developer ID certificate, never both
at once. To change the Sparkle key, release once with the new public key in `Info.plist` while still signing with the
old one, then switch `SPARKLE_PRIVATE_KEY`. If the key is lost, change both in one release: the unchanged Developer ID
certificate carries the trust. Renew the certificate in a release that keeps the key.
