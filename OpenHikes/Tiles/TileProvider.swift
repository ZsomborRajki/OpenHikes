//
//  TileProvider.swift
//  OpenHikes
//
//  The selectable raster tile sources the map can render, plus the one entry
//  that renders none of them and leaves MapKit's own base map in place. The
//  settings keys that persist the user's choice live in
//  `App/Configuration/SettingsKey.swift`.
//

import Foundation

/// A raster tile source the map can render. Add new sources to ``all``.
///
/// `nonisolated` as a whole: the tile-loading code that reads a provider's
/// template and zoom ceiling runs off the main actor, and a pure value type
/// has nothing for an actor to protect.
nonisolated struct TileProvider: Identifiable, Hashable, Sendable {
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
    /// Whether this entry draws MapKit's own base map instead of raster tiles.
    ///
    /// The one such entry isn't a tile source at all — it has no template, no
    /// zoom ceiling and nothing to fetch — but it is still a *choice of map*,
    /// so it lives in the same catalog the settings screen lists and the same
    /// `UserDefaults` key it persists. Everything downstream reads this flag
    /// rather than testing the id: it decides whether an overlay is installed
    /// (``TileProvider/renderedSource``), whether auto-save runs, and whether
    /// the offline controls are offered at all.
    let usesSystemBaseMap: Bool

    /// The template with `{key}` replaced by `apiKey`. Keyless providers ignore it.
    func resolvedTemplate(apiKey: String) -> String {
        urlTemplate.replacingOccurrences(of: "{key}", with: apiKey)
    }

    /// Whether this source can actually load tiles given the key resolved for
    /// it. Keyless providers always can; a key-gated one without a key renders
    /// nothing but 401s, so selecting it would leave the map blank forever.
    ///
    /// Pure, and takes the key rather than looking it up, so the rule is
    /// testable without a bundle to read it from — see ``Secrets/canLoadTiles(_:)``
    /// for the lookup that feeds it.
    func isUsable(withKey apiKey: String?) -> Bool {
        apiKeyPlistKey == nil || apiKey?.isEmpty == false
    }
}

nonisolated extension TileProvider {
    private static let osmMaximumZ = 19
    private static let thunderforestMaximumZ = 22

    /// The current default: OpenStreetMap's standard raster tiles.
    static let openStreetMap = TileProvider(
        id: "osm",
        name: "OpenStreetMap",
        summary: "Standard street map. Its tile policy disallows bulk downloads, " +
            "so viewed tiles are auto-saved for offline use instead.",
        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        maximumZ: osmMaximumZ,
        attribution: "© OpenStreetMap contributors",
        supportsBulkDownload: false,
        apiKeyPlistKey: nil,
        usesSystemBaseMap: false
    )

    /// MapKit's own base map: no raster tiles, and therefore no tile pipeline.
    ///
    /// Second in the list rather than last because it is the cheapest thing the
    /// app can draw, not a fallback. Nothing is fetched, nothing is written to
    /// disk, nothing is auto-saved and nothing can be bulk-downloaded — the map
    /// data is already on the device, served by the system's own cache. It is
    /// the option to pick when battery and data matter more than a topographic
    /// rendering, and the only one whose entire storage cost is zero.
    ///
    /// `maximumZ` is 0 because it is meaningless here: MapKit chooses its own
    /// levels of detail, and no code path reads this value for a provider that
    /// installs no overlay.
    static let appleMaps = TileProvider(
        id: "apple_maps",
        name: "Apple Maps",
        summary: "The system's built-in map. Downloads no tiles and saves nothing to disk, "
            + "so it uses the least battery and data.",
        urlTemplate: "",
        maximumZ: 0,
        attribution: "Map data © Apple",
        supportsBulkDownload: false,
        apiKeyPlistKey: nil,
        usesSystemBaseMap: true
    )

    /// A topographic source tuned for hiking that permits offline downloads.
    static let stadiaOutdoors = TileProvider(
        id: "stadia_outdoors",
        name: "Stadia Outdoors",
        summary: "Topographic map tuned for hiking. Permits offline downloads.",
        urlTemplate: "https://tiles.stadiamaps.com/tiles/outdoors/{z}/{x}/{y}.png?api_key={key}",
        maximumZ: 20,
        attribution: "© Stadia Maps, © OpenMapTiles, © OpenStreetMap contributors",
        supportsBulkDownload: true,
        apiKeyPlistKey: "StadiaAPIKey",
        usesSystemBaseMap: false
    )

    /// A hiking-focused source with deep native zoom, so close-in views stay sharp.
    static let thunderforestOutdoors = TileProvider(
        id: "thunderforest_outdoors",
        name: "Thunderforest Outdoors",
        summary: "Topographic map with deep zoom for sharp close-up detail. Permits offline downloads.",
        urlTemplate: "https://tile.thunderforest.com/outdoors/{z}/{x}/{y}.png?apikey={key}",
        maximumZ: thunderforestMaximumZ,
        attribution: "Maps © Thunderforest, Data © OpenStreetMap contributors",
        supportsBulkDownload: true,
        apiKeyPlistKey: "ThunderforestAPIKey",
        usesSystemBaseMap: false
    )

    /// All selectable providers, in display order.
    static let all: [TileProvider] = [openStreetMap, appleMaps, stadiaOutdoors, thunderforestOutdoors]

    /// The entries that actually fetch raster tiles. Everything that reasons
    /// about templates, zoom ceilings, cache keys or downloads means these.
    static let rasterSources: [TileProvider] = all.filter { !$0.usesSystemBaseMap }

    static let `default` = openStreetMap

    /// The provider with `id`, or the default if none matches (e.g. a removed provider).
    static func provider(id: String?) -> TileProvider {
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
    /// Whether the provider behind this source permits pre-downloading tiles.
    ///
    /// The source deliberately does not store the flag: it is projected from
    /// ``TileProvider/supportsBulkDownload`` on every read, so a source can
    /// never carry a stale `true` for a provider whose policy has since
    /// changed. An unknown `providerID` resolves to the (keyless, download-
    /// forbidding) default, which fails closed.
    var permitsBulkDownload: Bool {
        TileProvider.provider(id: providerID).supportsBulkDownload
    }

    /// Resolves `provider`'s bundled key into its URL template. Pair with
    /// ``TileProvider/renderable(id:)`` rather than ``TileProvider/provider(id:)``,
    /// so a key-gated provider with no key can't be built into a source that
    /// only ever 401s.
    ///
    /// Not the entry point for deciding what the map draws: a provider that
    /// uses the system base map has no template to resolve. Go through
    /// ``TileProvider/renderedSource``, which answers `nil` for it.
    init(_ provider: TileProvider) {
        self.init(
            providerID: provider.id,
            urlTemplate: provider.resolvedTemplate(apiKey: Secrets.apiKey(for: provider) ?? ""),
            maximumZ: provider.maximumZ
        )
    }
}

nonisolated extension TileProvider {
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
    static func renderable(id: String?) -> TileProvider {
        let stored = provider(id: id)
        return Secrets.canLoadTiles(stored) ? stored : .default
    }

    /// The provider the map is currently drawing with, read from `defaults`.
    ///
    /// The one lookup for callers outside SwiftUI — ``AutoSaveController`` and
    /// ``OpenHikesModel`` — so "which map is selected" is answered the same way
    /// there as it is by the `@AppStorage` bindings in the views.
    static func selected(in defaults: UserDefaults) -> TileProvider {
        renderable(id: defaults.string(forKey: SettingsKey.tileProviderID))
    }
}

extension TileProvider {
    /// The overlay source to draw this provider with, or `nil` when it draws no
    /// raster tiles at all.
    ///
    /// `nil` is not an error and not a fallback: it is the instruction to leave
    /// MapKit's own base map in place and start none of the tile pipeline. It
    /// is returned instead of an ``ActiveTileSource`` with an empty template so
    /// there is no value in the system that an overlay could be built from by
    /// accident.
    ///
    /// Main-actor, unlike the rest of the catalog: it builds an
    /// ``ActiveTileSource``, and only the views that decide what the map draws
    /// ever need one.
    var renderedSource: ActiveTileSource? {
        usesSystemBaseMap ? nil : ActiveTileSource(self)
    }
}
