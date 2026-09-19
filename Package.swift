// swift-tools-version: 6.0
import PackageDescription

// Callboard: product-free plumbing for Mac apps driven by AI agents over MCP.
//
//   CallboardJSON       a JSON value, parser and writer, keys kept in order
//   CallboardTransport  local sockets, line framing, session descriptors and
//                       the directory they are published in, support paths,
//                       and a project lock held by the kernel
//   CallboardMCP        MCP over stdio, a relay to a server over a socket,
//                       and installation into hosts' configuration
//
// No product logic: every name, path and environment variable a product
// needs comes from the `Product` value it passes in.

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "callboard",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CallboardJSON", targets: ["CallboardJSON"]),
        .library(name: "CallboardTransport", targets: ["CallboardTransport"]),
        .library(name: "CallboardMCP", targets: ["CallboardMCP"]),
    ],
    targets: [
        .target(name: "CallboardJSON", swiftSettings: swift6),
        .target(name: "CallboardTransport", dependencies: ["CallboardJSON"], swiftSettings: swift6),
        .target(name: "CallboardMCP", dependencies: ["CallboardTransport", "CallboardJSON"], swiftSettings: swift6),

        .testTarget(name: "CallboardJSONTests", dependencies: ["CallboardJSON"], swiftSettings: swift6),
        .testTarget(name: "CallboardTransportTests",
                    dependencies: ["CallboardTransport", "CallboardMCP", "CallboardJSON"], swiftSettings: swift6),
        .testTarget(name: "CallboardMCPTests",
                    dependencies: ["CallboardMCP", "CallboardTransport", "CallboardJSON"], swiftSettings: swift6),
    ]
)
