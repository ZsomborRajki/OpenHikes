//
//  TileLayer.swift
//  OpenHikes
//
//  Transparent raster layers drawn *over* whichever map is selected, rather
//  than instead of it.
//
//  A separate catalog from ``TileProvider`` on purpose. A provider is a choice
//  of map — exactly one is drawn, it replaces Apple's base map, and it is what
//  a bulk download fetches. A layer is none of those: it draws over all five
//  maps, Apple's included, it never replaces anything, and it has no bulk
//  download path at all, because the only kind it is ever offered is a
//  volunteer-run server whose terms discourage one. Putting it in
//  `TileProvider.all` would have made it selectable as a base map and given it
//  the paywall, preview card and download flags every base map carries, each
//  of which would then have had to be answered "not for this one".
//

import Foundation

/// A transparent tile source drawn above the selected map and below the route.
///
/// `nonisolated` for the same reason ``TileProvider`` is: the tile-loading
/// code reads it off the main actor, and a pure value has nothing to protect.
nonisolated struct TileLayer: Identifiable, Hashable, Sendable {
    /// Namespaces this layer's tiles in ``TileCache`` and in a hike's
    /// auto-saved manifest, exactly as a provider's id does — see
    /// ``TileCacheKey``. Never the same as any provider's.
    let id: String
    /// URL template with `{z}/{x}/{y}`. Keyless: nothing here is billed.
    let urlTemplate: String
    /// The shallowest zoom the layer is drawn and fetched at.
    ///
    /// A floor rather than the server's own: the server answers from z0, but
    /// a marked route is something to follow on the ground, and a tile that
    /// shows a continent's worth of them is a request spent on a picture
    /// nobody can walk. Every request is a second one on top of the base
    /// map's, so the zooms where the layer earns nothing are the cheapest
    /// place to save.
    let minimumZ: Int
    /// The deepest zoom the server renders. Deeper zooms are overzoomed by
    /// ``CachingTileOverlayRenderer`` from this level, as a provider's are.
    let maximumZ: Int
    /// Required credits, added to the selected map's own whenever the layer
    /// is drawn — see ``TileAttribution/drawn(base:layer:)``.
    let attribution: TileAttribution
}

nonisolated extension TileLayer {
    private static let waymarkedMinimumZ = 10
    private static let waymarkedMaximumZ = 18

    /// Waymarked Trails' hiking layer: OpenStreetMap's marked hiking route
    /// relations, in their colours and with their refs.
    ///
    /// The server is run by a volunteer, and its usage policy reads, in full:
    /// "You may use the overlay on other sites as long as access rates are
    /// moderate. Please cache tiles as often as possible and use a correct
    /// referrer. Mass download of tiles is strongly discouraged." This app
    /// meets that by being off by default, by the ``minimumZ`` floor, by going
    /// through the same ``TileCache`` tiers and ``TileNetworkPolicy`` every
    /// provider does, by identifying itself with ``TileCache/userAgent`` —
    /// an app has no referrer, and the User-Agent is what OSM's own policy
    /// asks an app for in its place — and by having no bulk download path.
    /// Tiles are saved only the way auto-save saves any provider's: the ones
    /// the map already drew.
    ///
    /// z18 is the deepest level the server answers; z19 is a 404.
    static let waymarkedHiking = TileLayer(
        id: "waymarked_hiking",
        urlTemplate: "https://tile.waymarkedtrails.org/hiking/{z}/{x}/{y}.png",
        minimumZ: waymarkedMinimumZ,
        maximumZ: waymarkedMaximumZ,
        attribution: TileAttribution([.waymarkedTrails, .openStreetMap])
    )

    /// Every layer, for the code that has to recognise a layer's tiles on
    /// disk — see `TileCache+DurableQuota.swift`.
    static let all: [TileLayer] = [waymarkedHiking]

    /// Whether this build offers the hiking routes at all.
    ///
    /// Not a shipping one yet, and that is a condition of the feature rather
    /// than an unfinished part of it. The policy quoted on
    /// ``waymarkedHiking`` is written for websites, and an App Store app
    /// sending its hikers' tile requests to a volunteer's server waits on the
    /// maintainer's written agreement (#804). Until it arrives a Debug build
    /// offers the layer, so it is built and tested like everything else, and
    /// a Release build neither shows the switch nor draws or fetches a tile —
    /// whatever the synced setting says, since another device's Debug build
    /// can have turned it on. The agreement is this becoming `true` for both.
    #if DEBUG
    static let isOffered = true
    #else
    static let isOffered = false
    #endif

    /// The layer to draw for the stored switch, or `nil` when it is off or
    /// this build does not offer it — see ``isOffered``. Every read of the
    /// switch goes through here, so that holds everywhere at once.
    static func shown(isOn: Bool, offered: Bool = isOffered) -> TileLayer? {
        isOn && offered ? .waymarkedHiking : nil
    }

    /// The layer the map is drawing, read from `defaults`.
    ///
    /// The one lookup for callers outside SwiftUI, the counterpart of
    /// ``TileProvider/selected(in:entitlement:)``.
    static func selected(in defaults: UserDefaults) -> TileLayer? {
        shown(isOn: defaults.bool(forKey: SettingsKey.showsHikingRoutes))
    }
}
