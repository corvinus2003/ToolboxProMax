// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ToolboxProMax",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ToolboxProMax",
            path: "Sources/ToolboxProMax",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
