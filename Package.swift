// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mamecase",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.6"),
    ],
    targets: [
        .executableTarget(
            name: "Mamecase",
            dependencies: [
                .product(name: "SWCompression", package: "SWCompression"),
            ],
            path: "Sources/MAMECASE"
        )
    ]
)
