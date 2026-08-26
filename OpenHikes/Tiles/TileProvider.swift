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
    /// Required credits, shown wherever the source is displayed. Every link
    /// here is a term of use rather than a convenience — see ``TileAttribution``.
    let attribution: TileAttribution
    /// Whether the provider's usage policy permits pre-downloading tiles for offline use.
    let supportsBulkDownload: Bool
    /// Device-wide ceiling on this provider's *durably* stored tiles, where its
    /// terms impose one. `nil` means the provider sets no such limit.
    ///
    /// Not a storage preference. Stadia's terms permit offline caching only
    /// "not to exceed 100MB cached at a time per device", so this is the same
    /// kind of promise ``supportsBulkDownload`` is: exceeding it is a licensing
    /// problem, not a full disk. Enforced by ``TileCache`` at every durable
    /// write, because that is the one place both write paths meet.
    let durableByteLimit: Int64?
    /// Whether selecting this source requires the paid Pro unlock.
    ///
    /// The app is usable, and fully offline-capable, without ever paying: the
    /// two keyless sources carry no flag here. What the unlock buys is access
    /// to the two commercial sources, whose own plans the app pays for per
    /// tile served — which is the reason a gate exists at all.
    let requiresPaidAccess: Bool
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
    /// Stadia's terms of service, §8.4: bulk downloading is prohibited "except
    /// for the purpose of caching small amounts of data for offline use in a
    /// mobile application, **not to exceed 100MB cached at a time per device**".
    ///
    /// Device-wide and provider-wide — not per hike — which is why it is
    /// enforced against a running total of everything Stadia has durably on
    /// disk rather than against any one download.
    static let stadiaDurableByteLimit: Int64 = 100 * 1024 * 1024
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
        attribution: TileAttribution([.openStreetMap]),
        supportsBulkDownload: false,
        durableByteLimit: nil,
        requiresPaidAccess: false,
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
        attribution: TileAttribution([.apple]),
        supportsBulkDownload: false,
        durableByteLimit: nil,
        requiresPaidAccess: false,
        apiKeyPlistKey: nil,
        usesSystemBaseMap: true
    )

    /// A topographic source tuned for hiking that permits offline downloads,
    /// within the 100 MB per-device ceiling its terms set.
    static let stadiaOutdoors = TileProvider(
        id: "stadia_outdoors",
        name: "Stadia Outdoors",
        summary: "Topographic map tuned for hiking. Offline downloads are allowed, "
            + "up to 100 MB of saved tiles on this device.",
        urlTemplate: "https://tiles.stadiamaps.com/tiles/outdoors/{z}/{x}/{y}.png?api_key={key}",
        maximumZ: 20,
        attribution: TileAttribution([.stadiaMaps, .openMapTiles, .openStreetMap]),
        supportsBulkDownload: true,
        durableByteLimit: stadiaDurableByteLimit,
        requiresPaidAccess: true,
        apiKeyPlistKey: "StadiaAPIKey",
        usesSystemBaseMap: false
    )

    /// A hiking-focused source with deep native zoom, so close-in views stay sharp.
    ///
    /// Bulk download is off, and that is a licensing fact rather than a missing
    /// feature: Thunderforest's terms open with "Absolutely no bulk-downloading
    /// scraping, pre-downloading, pre-caching or anything similar without an
    /// appropriate plan", and reserve prefetching for their Small Business plan
    /// and above. The same terms do allow what auto-save does — "Tiles may be
    /// cached in-browser and on-device for offline use" — so browsing a route
    /// still builds offline coverage for it, exactly as OpenStreetMap does.
    /// Restoring the flag means buying that plan first.
    static let thunderforestOutdoors = TileProvider(
        id: "thunderforest_outdoors",
        name: "Thunderforest Outdoors",
        summary: "Topographic map with deep zoom for sharp close-up detail. Its plan "
            + "disallows bulk downloads, so viewed tiles are auto-saved for offline use instead.",
        urlTemplate: "https://tile.thunderforest.com/outdoors/{z}/{x}/{y}.png?apikey={key}",
        maximumZ: thunderforestMaximumZ,
        attribution: TileAttribution([.thunderforest, .openStreetMapData]),
        supportsBulkDownload: false,
        durableByteLimit: nil,
        requiresPaidAccess: true,
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

    /// The credits this source must display, projected from the catalog for
    /// the same reason ``permitsBulkDownload`` is: a licence term is never
    /// carried in a value that could go stale.
    var attribution: TileAttribution {
        TileProvider.provider(id: providerID).attribution
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
    /// unless it's key-gated and no key resolves on this build, or it's a paid
    /// source this device isn't entitled to — in either case the (keyless,
    /// free) default.
    ///
    /// Settings won't let such a provider be *selected* — see `providerRow` —
    /// but a build that once had a `Secrets.plist` can leave the id behind in
    /// `UserDefaults` after the key is gone, and a lapsed subscription (or a
    /// choice synced from a device that still has one) leaves a paid id behind
    /// the same way. A blank map is the worst possible answer to either, so the
    /// fallback lives here rather than at each call site. Everything
    /// user-facing has to agree on one provider — the tiles, the attribution
    /// shown for them, whether a bulk download is even offered.
    ///
    /// The stored id is deliberately *not* rewritten to match. It travels
    /// through iCloud (see ``SyncedSetting``), so overwriting it on an
    /// unentitled device would push that downgrade to the entitled one and
    /// silently undo a choice made there.
    ///
    /// - Parameter entitlement: passed explicitly by tests, which must not
    ///   touch the process-wide value — suites run in parallel and share it.
    static func renderable(
        id: String?,
        entitlement: MapEntitlementState = MapEntitlement.current
    ) -> TileProvider {
        let stored = provider(id: id)
        guard Secrets.canLoadTiles(stored), entitlement.allows(stored) else { return .default }
        return stored
    }

    /// The provider the map is currently drawing with, read from `defaults`.
    ///
    /// The one lookup for callers outside SwiftUI — ``AutoSaveController`` and
    /// ``OpenHikesModel`` — so "which map is selected" is answered the same way
    /// there as it is by the `@AppStorage` bindings in the views.
    static func selected(
        in defaults: UserDefaults,
        entitlement: MapEntitlementState = MapEntitlement.current
    ) -> TileProvider {
        renderable(
            id: defaults.string(forKey: SettingsKey.tileProviderID),
            entitlement: entitlement
        )
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
