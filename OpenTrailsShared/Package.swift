// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTrailsShared",
    platforms: [
        .iOS(.v18),
        .watchOS(.v10),
        .macOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "OpenTrailsShared", targets: ["OpenTrailsShared"])
    ],
    targets: [
        .target(name: "OpenTrailsShared"),
        .testTarget(name: "OpenTrailsSharedTests", dependencies: ["OpenTrailsShared"])
    ]
)
