// swift-tools-version: 6.2
import PackageDescription

/// The OpenHikes map, drawn: a Mapbox Vector Tile read, drawn in
/// OpenStreetMap Carto's look with Carto's own icons, and handed back as a
/// picture a raster tile pipeline can file. With it, where the tiles are: the
/// client that asks a tile server for them and the reading of that server's
/// manifest. See issue #1488 and *Layout and targets* in the repository
/// instructions.
///
/// **What the app keeps** is everything that makes this *its* map: which
/// server and which archives (the manifest it bundles), the cache the
/// pictures are filed in, the raster fallback, the network policy and the
/// downloaded countries. Nothing here names a tile provider, a cache key or
/// a setting. The app hands in its language and its height formatter.
///
/// **The PMTiles reader is the app's too**, though a downloaded country is
/// drawn here: it is built on the packed-bytes reader, writer and deflate
/// that the app's four sets of squares share. So a tile comes out of an
/// archive on the app's side of the boundary, unpacked, and only then
/// crosses it (`VectorTileRasterizer.png(ofArchiveTile:…)`).
///
/// **Not main-actor by default**, unlike the app and `OpenHikesData`: every
/// tile is read and drawn on MapKit's drawing threads or a detached task, and
/// nothing here touches a view or a model.
///
/// The app alone links it. Neither the widget nor the watch draws a tile, so
/// the cost *Layout and targets* measured for a dependency on those products
/// does not arise, and swift-algorithms and swift-collections are the app's
/// own checkouts, pinned here to the versions it resolves.
///
/// `OpenHikesVectorTilesTestSupport` is the tiles a suite writes in code and
/// the tile server a suite scripts. It is a library rather than part of the
/// test target because the app's hosted suites need both too: the cache's
/// fallback, a retired archive and a downloaded country are tested there,
/// with the app's `TileCache`. It uses the package as any host does, by its
/// `public` declarations alone, so it builds wherever the package builds;
/// what it offers is `internal`, and a suite reads it through
/// `@testable import`.
///
/// Platforms are the app's floor and the generation beside it, as in
/// `OpenHikesShared`, so that `swift test` on the macOS host refuses what the
/// iOS build refuses. No watchOS: nothing on the watch draws a tile.
let package = Package(
    name: "OpenHikesVectorTiles",
    platforms: [
        .iOS("18.4"),
        .macOS("15.4"),
        .visionOS("2.4")
    ],
    products: [
        .library(name: "OpenHikesVectorTiles", targets: ["OpenHikesVectorTiles"]),
        .library(name: "OpenHikesVectorTilesTestSupport", targets: ["OpenHikesVectorTilesTestSupport"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections/", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-algorithms/", from: "1.2.1"),
        .package(url: "https://github.com/apple/swift-numerics.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "OpenHikesVectorTiles",
            dependencies: [
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "OrderedCollections", package: "swift-collections")
            ],
            resources: [.process("Resources")],
            swiftSettings: .vectorTiles
        ),
        .target(
            name: "OpenHikesVectorTilesTestSupport",
            dependencies: ["OpenHikesVectorTiles"],
            swiftSettings: .vectorTiles
        ),
        .testTarget(
            name: "OpenHikesVectorTilesTests",
            dependencies: [
                "OpenHikesVectorTiles",
                "OpenHikesVectorTilesTestSupport",
                .product(name: "RealModule", package: "swift-numerics")
            ],
            swiftSettings: .vectorTiles
        )
    ]
)

extension [SwiftSetting] {
    /// `OpenHikesShared`'s language, for the reasons that manifest gives:
    /// the two upcoming features the Xcode targets set, and no main-actor
    /// default isolation.
    static var vectorTiles: Self {
        [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]
    }
}
