# Joinery for Windows and Linux

The same Joinery as the Mac app's, for Windows and Linux: the Swift core compiled to WebAssembly, the canvas and library
in TypeScript, and a small Rust shell (Tauri) that keeps the library on disk and listens for AI assistants on
`http://127.0.0.1:8723/mcp`. It opens the same `.joinery` files and joins the same live sessions as the Mac app.

```sh
npm ci
npm run core      # the core to WebAssembly (needs the swift.org toolchain and its WebAssembly SDK)
npx tauri dev     # run it
npm test          # the core as the app drives it, and a session through the relay
```

How it fits together, building it, and releasing it: [docs/development.md](../docs/development.md#windows-and-linux).
