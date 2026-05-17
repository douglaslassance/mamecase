// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MAMECASE",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MAMECASE",
            path: "Sources/MAMECASE"
        )
    ]
)
