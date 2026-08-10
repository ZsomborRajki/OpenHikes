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
    /// UserDefaults key holding the API key, for providers that need one. `nil` if keyless.
    let apiKeyDefaultsKey: String?

    var requiresAPIKey: Bool { apiKeyDefaultsKey != nil }

    /// The template with `{key}` replaced by `apiKey`. Keyless providers ignore it.
    func resolvedTemplate(apiKey: String) -> String {
        urlTemplate.replacingOccurrences(of: "{key}", with: apiKey)
    }
}

// Provider constants are `nonisolated` so the tile-loading code (which runs off
// the main actor) can reference them alongside the main-actor settings UI.
extension TileProvider {
    /// The current default: OpenStreetMap's standard raster tiles.
    nonisolated static let openStreetMap = TileProvider(
        id: "osm",
        name: "OpenStreetMap",
        summary: "Standard street map. Its tile policy disallows bulk downloads, so viewed tiles are auto-saved for offline use instead.",
        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        maximumZ: 19,
        attribution: "© OpenStreetMap contributors",
        supportsBulkDownload: false,
        apiKeyDefaultsKey: nil
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
        apiKeyDefaultsKey: SettingsKey.stadiaAPIKey
    )

    /// A hiking-focused source with deep native zoom, so close-in views stay sharp.
    nonisolated static let thunderforestOutdoors = TileProvider(
        id: "thunderforest_outdoors",
        name: "Thunderforest Outdoors",
        summary: "Topographic map with deep zoom for sharp close-up detail. Permits offline downloads.",
        urlTemplate: "https://tile.thunderforest.com/outdoors/{z}/{x}/{y}.png?apikey={key}",
        maximumZ: 22,
        attribution: "Maps © Thunderforest, Data © OpenStreetMap contributors",
        supportsBulkDownload: true,
        apiKeyDefaultsKey: SettingsKey.thunderforestAPIKey
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

/// UserDefaults / `@AppStorage` keys shared between the settings UI and the map.
enum SettingsKey {
    static let tileProviderID = "settings.tileProviderID"
    static let stadiaAPIKey = "settings.apiKey.stadia"
    static let thunderforestAPIKey = "settings.apiKey.thunderforest"
}
