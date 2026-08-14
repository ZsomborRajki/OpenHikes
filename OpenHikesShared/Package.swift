// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenHikesShared",
    platforms: [
        .iOS(.v18),
        .macOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "OpenHikesShared", targets: ["OpenHikesShared"])
    ],
    targets: [
        .target(name: "OpenHikesShared"),
        .testTarget(name: "OpenHikesSharedTests", dependencies: ["OpenHikesShared"])
    ]
)
