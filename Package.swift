// swift-tools-version:5.9
import PackageDescription
import Foundation

// Sparkle is omitted for App Store builds (Apple forbids auto-update mechanisms).
let isAppStore = ProcessInfo.processInfo.environment["APPSTORE_BUILD"] == "1"

let dependencies: [Package.Dependency] = isAppStore ? [] : [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
]

let appTargetDeps: [Target.Dependency] = isAppStore ? [] : [
    .product(name: "Sparkle", package: "Sparkle")
]

let package = Package(
    name: "Mamecase",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "Mamecase",
            dependencies: appTargetDeps,
            path: "Sources/Mamecase",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
