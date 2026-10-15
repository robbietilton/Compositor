// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompositorMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "compositor-mcp", targets: ["CompositorMCP"])
    ],
    targets: [
        .target(name: "CompositorMCPKit"),
        .executableTarget(name: "CompositorMCP", dependencies: ["CompositorMCPKit"]),
        .testTarget(name: "CompositorMCPKitTests", dependencies: ["CompositorMCPKit"])
    ],
    swiftLanguageModes: [.v5]
)
