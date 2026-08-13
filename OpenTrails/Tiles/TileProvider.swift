//
//  TileProvider.swift
//  OpenTrails
//
//  The selectable raster tile sources the map can render, plus the settings
//  keys that persist the user's choice.
//

import Foundation

/// A raster tile source the map can render. Add new sources to ``all``.
struct TileProvider: Identifiable, Hashable {
    let id: String
    let name: String
    /// One-line description shown under the name in Settings.
    let summary: String
    /// URL template with `{z}/{x}/{y}` and an optional `{key}` placeholder.
    let urlTemplate: String
    /// Highest real zoom level the source serves. Deeper zooms are overzoomed.
    let maximumZ: Int
    /// Required attribution string, shown wherever the source is displayed.
    let attribution: String
    /// Whether the provider's usage policy permits pre-downloading tiles for offline use.
    let supportsBulkDownload: Bool
    /// `Secrets.plist` key holding this provider's API key, for providers that need one. `nil` if keyless.
    let apiKeyPlistKey: String?

    /// The template with `{key}` replaced by `apiKey`. Keyless providers ignore it.
    nonisolated func resolvedTemplate(apiKey: String) -> String {
        urlTemplate.replacingOccurrences(of: "{key}", with: apiKey)
    }

    /// Whether this source can actually load tiles given the key resolved for
    /// it. Keyless providers always can; a key-gated one without a key renders
    /// nothing but 401s, so selecting it would leave the map blank forever.
    ///
    /// Pure, and takes the key rather than looking it up, so the rule is
    /// testable without a bundle to read it from — see ``Secrets/canLoadTiles(_:)``
    /// for the lookup that feeds it.
    nonisolated func isUsable(withKey apiKey: String?) -> Bool {
        apiKeyPlistKey == nil || apiKey?.isEmpty == false
    }
}

// Provider constants are `nonisolated` so the tile-loading code (which runs off
// the main actor) can reference them alongside the main-actor settings UI.
extension TileProvider {
    private static let osmMaximumZ = 19
    private static let thunderforestMaximumZ = 22

    /// The current default: OpenStreetMap's standard raster tiles.
    nonisolated static let openStreetMap = TileProvider(
        id: "osm",
        name: "OpenStreetMap",
        summary: "Standard street map. Its tile policy disallows bulk downloads, " +
            "so viewed tiles are auto-saved for offline use instead.",
        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        maximumZ: osmMaximumZ,
        attribution: "© OpenStreetMap contributors",
        supportsBulkDownload: false,
        apiKeyPlistKey: nil
    )

    /// A topographic source tuned for hiking that permits offline downloads.
    nonisolated static let stadiaOutdoors = TileProvider(
        id: "stadia_outdoors",
        name: "Stadia Outdoors",
        summary: "Topographic map tuned for hiking. Permits offline downloads.",
        urlTemplate: "https://tiles.stadiamaps.com/tiles/outdoors/{z}/{x}/{y}.png?api_key={key}",
        maximumZ: 20,
        attribution: "© Stadia Maps, © OpenMapTiles, © OpenStreetMap contributors",
        supportsBulkDownload: true,
        apiKeyPlistKey: "StadiaAPIKey"
    )

    /// A hiking-focused source with deep native zoom, so close-in views stay sharp.
    nonisolated static let thunderforestOutdoors = TileProvider(
        id: "thunderforest_outdoors",
        name: "Thunderforest Outdoors",
        summary: "Topographic map with deep zoom for sharp close-up detail. Permits offline downloads.",
        urlTemplate: "https://tile.thunderforest.com/outdoors/{z}/{x}/{y}.png?apikey={key}",
        maximumZ: thunderforestMaximumZ,
        attribution: "Maps © Thunderforest, Data © OpenStreetMap contributors",
        supportsBulkDownload: true,
        apiKeyPlistKey: "ThunderforestAPIKey"
    )

    /// All selectable providers, in display order.
    nonisolated static let all: [TileProvider] = [openStreetMap, stadiaOutdoors, thunderforestOutdoors]

    nonisolated static let `default` = openStreetMap

    /// The provider with `id`, or the default if none matches (e.g. a removed provider).
    nonisolated static func provider(id: String?) -> TileProvider {
        all.first { $0.id == id } ?? .default
    }
}

/// A ready-to-render tile source: a provider with its API key already resolved.
/// The map compares these to decide when to rebuild its overlay.
struct ActiveTileSource: Equatable {
    let providerID: String
    let urlTemplate: String
    let maximumZ: Int
}

extension ActiveTileSource {
    /// Resolves `provider`'s bundled key into its URL template. Pair with
    /// ``TileProvider/renderable(id:)`` rather than ``TileProvider/provider(id:)``,
    /// so a key-gated provider with no key can't be built into a source that
    /// only ever 401s.
    init(_ provider: TileProvider) {
        self.init(
            providerID: provider.id,
            urlTemplate: provider.resolvedTemplate(apiKey: Secrets.apiKey(for: provider) ?? ""),
            maximumZ: provider.maximumZ
        )
    }
}

extension TileProvider {
    /// The provider to actually render with for a stored `id`: the stored one,
    /// unless it's key-gated and no key resolves on this build, in which case
    /// the (keyless) default.
    ///
    /// Settings won't let such a provider be *selected* — see `providerRow` —
    /// but a build that once had a `Secrets.plist` can leave the id behind in
    /// `UserDefaults` after the key is gone, and a blank map is the worst
    /// possible answer to that. Everything user-facing has to agree on one
    /// provider (the tiles, the attribution shown for them, whether a bulk
    /// download is even offered), so the fallback lives here rather than at
    /// each call site.
    nonisolated static func renderable(id: String?) -> TileProvider {
        let stored = provider(id: id)
        return Secrets.canLoadTiles(stored) ? stored : .default
    }
}

/// UserDefaults / `@AppStorage` key shared between the settings UI and the map.
enum SettingsKey {
    static let tileProviderID = "settings.tileProviderID"
    /// Whether Background Trail Tracking is on, read by `BackgroundTrailTracker`
    /// at launch to decide whether to re-arm significant-change monitoring.
    static let backgroundTrackingEnabled = "settings.backgroundTrackingEnabled"
    /// The last-selected hike's `id.uuidString`, written by `OpenTrailsModel` on
    /// every selection change. Serves two purposes: restoring the selection
    /// on a normal launch, and telling `BackgroundTrailTracker` which hike to
    /// match a fix against on a background relaunch, which has no in-memory
    /// selection to read.
    static let lastSelectedHikeID = "selection.lastHikeID"
}
