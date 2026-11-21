//
//  VectorTileArchives+OpenHikes.swift
//  OpenHikes
//
//  What makes the map the `OpenHikesVectorTiles` package draws this app's:
//  the tile server, the manifest of its archives this build was made with,
//  the archives a launch draws from, and the words the map is written in.
//  The package reads tiles and draws them, and names no server, no archive,
//  no cache key and no setting; see its `Package.swift` and *Tiles* in the
//  repository instructions.
//

import Foundation
import OpenHikesData
import OpenHikesVectorTiles

nonisolated extension VectorTileArchives {
    // swiftlint:disable:next force_unwrapping
    /// The OpenHikes tile server (#1481).
    static let server = URL(string: "https://tiles.openhikes.app/")!

    /// The app's, or `nil` in a suite, which reaches no tile server unless it
    /// is the App Store frames' (``AppLaunchEnvironment/asksTileServer``).
    static func forThisLaunch() -> VectorTileArchives? {
        guard !AppLaunchEnvironment.isRunningTests || AppLaunchEnvironment.asksTileServer,
              let bundled = VectorTileArchiveManifest.bundled else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VectorTileArchives(
            providerIDs: Set(TileProvider.vectorSources.keys),
            bundled: bundled,
            manifests: VectorTileManifestServer(root: server, userAgent: TileCache.userAgent),
            file: support.appending(path: "VectorTileArchives.json"),
            server: server,
            mayAsk: {
                TileNetworkPolicy.decide(.interactive, conditions: TileCache.shared.networkConditions).isAllowed
            },
            // The map draws what it shows again, from the new archives.
            didMove: { TileCache.shared.notifyInteractiveFetchUnblocked() }
        )
    }
}

nonisolated extension VectorTileArchiveManifest {
    /// The manifest this build was made with (`VectorTileArchiveManifest.json`,
    /// beside this file), or `nil` if it is not in the bundle or cannot be
    /// read, which `VectorTileBundledManifestTests` holds against.
    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "VectorTileArchiveManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()
}

nonisolated extension VectorTileSource {
    /// The OpenHikes planet on `tiles.openhikes.app`, as the manifest this
    /// build was made with names it: Protomaps' basemap, OpenStreetMap's data
    /// under the ODbL, with the extras. The tile cache draws from what the
    /// server's manifest names now (`VectorTileArchives`), which this is only
    /// the first of; a provider asks this whether it is drawn from vector
    /// tiles at all.
    static let openHikesPlanet = VectorTileArchiveManifest.bundled?.source(on: VectorTileArchives.server)
}

/// The words the app has its map written in, handed to the package wherever
/// a tile is drawn: off the tile server and out of a downloaded country
/// alike, so the two draw one map.
nonisolated enum VectorMapWording {
    /// The language the app is showing, whose names the map prefers.
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// A summit's height, as the app writes one everywhere else.
    static func height(_ meters: Double) -> String {
        HikeFormat.elevation(Measurement(value: meters, unit: .meters))
    }
}
