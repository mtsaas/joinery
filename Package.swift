// swift-tools-version: 6.2
// The core (the data model, the session protocol and the MCP server's tools) as a package, for platforms other than
// the Mac app, which builds the same files in Joinery.xcodeproj. scripts/check_layers.sh keeps them portable.
import PackageDescription

let package = Package(
    name: "JoineryCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "JoineryCore", targets: ["JoineryCore"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")],
    targets: [
        .target(
            name: "JoineryCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows, .wasi]))],
            path: "Joinery",
            sources: ["Document", "Collaboration/Protocol", "MCP/Protocol"]
        ),
    ]
)
