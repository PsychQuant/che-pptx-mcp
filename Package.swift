// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChePPTXMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/PsychQuant/pptx-swift.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ChePPTXMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "PPTXSwift", package: "pptx-swift"),
            ]
        )
    ]
)
