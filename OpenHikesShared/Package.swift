// swift-tools-version: 6.2
import PackageDescription

/// Platforms track the app rather than trailing it. The app ships iOS 26.5
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
    /// Deliberately *not* `defaultIsolation(MainActor.self)`, which the app
    /// does set. This package is read by the widget extension off the main
    /// actor — `TrailBasemap` projection and `SharedStore` decoding both run
    /// there — so main-actor-by-default would be the wrong default here and
    /// does not compile.
    static var shared: Self {
        [.enableUpcomingFeature("MemberImportVisibility")]
    }
}
