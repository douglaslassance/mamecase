// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mamecase",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mamecase",
            path: "Sources/Mamecase",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
