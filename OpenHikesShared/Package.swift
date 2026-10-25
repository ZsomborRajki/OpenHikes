// swift-tools-version: 6.2
import PackageDescription

/// Platforms are the app's own floor, exactly: the phone targets deploy to
/// iOS 18.4 and the watch app to watchOS 11.0. Higher, and neither could link
/// this. Lower, and every API added since would be refused here, silently, as
/// an unavailability error at the one call site that reached for one. An API
/// newer than the floor is reached through `if #available` with a fallback,
/// as it is in the app — *Deployment floor* in the repository instructions.
/// watchOS is named because `OpenHikesWatch` genuinely builds against it and
/// reads the payloads, the trail glyph and the formatters from here; what is
/// iOS-only says so with `#if` — the Live Activity's ActivityKit conformance
/// and its buttons, the Spotlight half of `HikeEntity`, and the UIKit haptics.
/// macOS and visionOS are named at the same generation, macOS 15.4 and
/// visionOS 2.4, so that `swift test`, which runs the suite on the macOS host,
/// refuses the same APIs the iOS build does. Nothing else builds them (see the
/// `canImport` guards in the sources). CI pins that host to the `xcode-27`
/// runner image.
///
/// The library has no dependencies, deliberately: every product that links
/// this package and nothing else — the widget, the watch app, its
/// complications — would carry a dependency whole. *Architecture* in the
/// repository instructions has the measurement.
///
/// swift-numerics is the one external dependency, and only the test target
/// links it, for `isApproximatelyEqual(to:absoluteTolerance:)`. It is the
/// version swift-algorithms already resolves for the app and `OpenHikesData`,
/// named by the same URL so the three pin one checkout.
let package = Package(
    name: "OpenHikesShared",
    platforms: [
        .iOS("18.4"),
        .macOS("15.4"),
        .visionOS("2.4"),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "OpenHikesShared", targets: ["OpenHikesShared"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-numerics.git", from: "1.1.1")
    ],
    targets: [
        .target(name: "OpenHikesShared", swiftSettings: .shared),
        .testTarget(
            name: "OpenHikesSharedTests",
            dependencies: [
                "OpenHikesShared",
                .product(name: "RealModule", package: "swift-numerics")
            ],
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
    /// opts back out with `@concurrent`. The package's `async` code is its App
    /// Intents' `perform()` methods and the handler protocols behind them,
    /// which is exactly what this setting is for: an intent is performed in
    /// the app's process, and it runs there the way the same code written in
    /// the app would rather than the opposite way.
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
