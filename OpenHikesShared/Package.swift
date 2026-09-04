// swift-tools-version: 6.2
import PackageDescription

/// Platforms track the app rather than trailing it. The app ships iOS 26.0
/// only, so a shared target that still claimed iOS 18 would be refusing every
/// API added since — silently, as an unavailability error at the one call site
/// that reached for one. macOS and visionOS are named at the same level for
/// the same reason: nothing builds them today (see the `canImport` guards in
/// the sources), but if one ever does it should start where the app already
/// is. `swift test` runs the suite on the macOS host, which CI pins to
/// `macos-26`.
let package = Package(
    name: "OpenHikesShared",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "OpenHikesShared", targets: ["OpenHikesShared"])
    ],
    targets: [
        .target(name: "OpenHikesShared", swiftSettings: .shared),
        .testTarget(
            name: "OpenHikesSharedTests",
            dependencies: ["OpenHikesShared"],
            swiftSettings: .shared
        )
    ]
)

extension [SwiftSetting] {
    /// Matches what the Xcode targets already set, so the package and the app
    /// compile the same language.
    ///
    /// `MemberImportVisibility` is `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`
    /// in the project: a member is only visible when its module is imported
    /// directly, rather than leaking in through some other module's import.
    ///
    /// `NonisolatedNonsendingByDefault` (SE-0461) is the one part of
    /// `SWIFT_APPROACHABLE_CONCURRENCY = YES` the Swift 6 language mode does
    /// not already imply — the other three that setting expands to
    /// (`InferSendableFromCaptures`, `GlobalActorIsolatedTypesUsability`,
    /// `DisableOutwardActorInference`) are on as of Swift 6 and warn if named
    /// again. Without it a `nonisolated` `async` function hops to the global
    /// executor; with it the function runs on the caller's actor unless it
    /// opts back out with `@concurrent`. The package's only `async` code is
    /// `ToggleHikeRecordingIntent.perform()` and the handler protocol behind
    /// it, which is exactly what this setting is for: the intent is performed
    /// in the app's process, and it runs there the way the same code written
    /// in the app would rather than the opposite way.
    ///
    /// Deliberately *not* `defaultIsolation(MainActor.self)`, which the app
    /// does set. This package is read by the widget extension off the main
    /// actor — `TrailBasemap` projection and `SharedStore` decoding both run
    /// there — so main-actor-by-default would be the wrong default here and
    /// does not compile.
    static var shared: Self {
        [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]
    }
}
