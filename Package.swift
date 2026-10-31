// swift-tools-version: 6.2
// Joinery's core (the data model, the session protocol and the MCP server's tools) built for WebAssembly, with the
// bridge the desktop app for Windows and Linux (desktop/) drives it through. The Mac app builds the same core files in
// Joinery.xcodeproj; scripts/check_layers.sh keeps them portable.
//
//   swift package --swift-sdk swift-6.4.2-RELEASE_wasm js -c release     → .build/plugins/PackageToJS/outputs/Package
import PackageDescription

let package = Package(
    name: "JoineryCore",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.62.0"),
    ],
    targets: [
        // One target, as the core's types are internal: the core's folders and the bridge, compiled together.
        .executableTarget(
            name: "JoineryCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows, .wasi])),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ],
            // The core's folders are linked in from Joinery/, beside the bridge.
            path: "desktop/core",
            sources: ["Document", "Collaboration/Protocol", "MCP/Protocol", "Bridge"],
            swiftSettings: [.enableExperimentalFeature("Extern")],
            plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
        ),
    ]
)
