# Joinery

Joinery is a macOS app for sketching SQL data models on an infinite canvas. Tables sit on the canvas, foreign keys are
drawn as wires between column sockets, and wires can be zip-tied into bundles. Models live in a Freeform-style library
with version history, can be edited live with others through an end-to-end encrypted relay, and can be read and changed
by AI assistants over MCP. It needs macOS 26 and Xcode 26: open `Joinery.xcodeproj` and press ⌘R. The full guide is in
[docs/guide.md](docs/guide.md).

The relay in [relay/](relay/) is a small Zig server that passes live sessions between people without reading them. One
16-core, 64 GB machine holds 80,000 people in rooms of four, or 32,000 in full rooms of 32, using a quarter of its CPU
and under 2 GB. It ships as the container `ghcr.io/mtsaas/joinery-relay` and the Helm chart
`oci://ghcr.io/mtsaas/charts/joinery-relay`.
