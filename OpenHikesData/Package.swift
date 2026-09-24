// swift-tools-version: 6.2
import PackageDescription

/// What a hike *is*: the SwiftData models, the schema, the route index and
/// the framework-free logic over them — the Backyard Birds `…Data` package,
/// for this app. See issue #573 and *Architecture* in the repository
/// instructions for why it is a package of its own.
///
/// **A sibling of `OpenHikesShared`, not a target inside it**, because the two
/// want different default isolations and one package cannot have both. This
/// one is main-actor by default, exactly as the app target is
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so code moved here from the
/// app means what it meant there. `OpenHikesShared` deliberately is not: the
/// widget reads it off the main actor.
///
/// What stayed in the app is the container: `ModelContainer.openHikes(…)`,
/// the two-store configuration, the iCloud switch read at launch and the
/// in-memory fallback are settled decisions about *launching*, and they live
/// with the composition root in `App/Configuration/`.
///
/// Built statically, like `OpenHikesShared`: launch time is measured here,
/// and a dynamic library is a dylib load on the launch path for nothing.
let package = Package(
    name: "OpenHikesData",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
        .watchOS(.v26)
    ],
    products: [
        .library(name: "OpenHikesData", targets: ["OpenHikesData"])
    ],
    dependencies: [
        .package(path: "../OpenHikesShared"),
        .package(url: "https://github.com/apple/swift-collections/", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-algorithms/", from: "1.2.1")
    ],
    targets: [
        .target(
            name: "OpenHikesData",
            dependencies: [
                "OpenHikesShared",
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            swiftSettings: .data
        ),
        .testTarget(
            name: "OpenHikesDataTests",
            dependencies: ["OpenHikesData"],
            swiftSettings: .data
        )
    ]
)

extension [SwiftSetting] {
    /// The app target's language, so a file moved here compiles to the same
    /// thing it compiled to there: `OpenHikesShared`'s two upcoming features,
    /// and main-actor default isolation — the setting that package cannot
    /// have and this one exists to carry.
    static var data: Self {
        [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .defaultIsolation(MainActor.self)
        ]
    }
}
