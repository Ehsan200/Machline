// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Machline",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        .executable(name: "harness-approve", targets: ["harness-approve"]),
        .executable(name: "harness-mcp-proxy", targets: ["harness-mcp-proxy"])
    ],
    // The project's only third-party dependency. Pinned exactly rather than by range: SwiftTerm's
    // 2.0 API exists on `main` but is untagged, so a range would eventually pull a breaking change
    // in on an ordinary `swift update`.
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .target(
            name: "HarnessCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "harness-approve",
            dependencies: ["HarnessCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "harness-mcp-proxy",
            dependencies: ["HarnessCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Machline",
            dependencies: [
                "HarnessCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Test fixture: a real JSON-RPC peer for the MCP suites. Not shipped as a product.
        .executableTarget(
            name: "harness-echo-mcp",
            dependencies: ["HarnessCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HarnessCoreTests",
            dependencies: ["HarnessCore", "harness-approve", "harness-mcp-proxy", "harness-echo-mcp"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
