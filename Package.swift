// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/gordonbeeming/mac-reactions", from: "0.1.0")
    ],
    targets: [
        .target(name: "CodexBarCore"),
        .executableTarget(
            name: "CodexBar",
            dependencies: [
                "CodexBarCore",
                .product(name: "MacReactions", package: "mac-reactions")
            ]
        ),
        .testTarget(
            name: "CodexBarCoreTests",
            dependencies: ["CodexBarCore"]
        )
    ]
)
