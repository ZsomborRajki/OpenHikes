//
//  TileLayer.swift
//  OpenHikes
//
//  Layers drawn *over* whichever map is selected, rather than instead of it.
//
//  A separate catalog from ``TileProvider`` on purpose. A provider is a choice
//  of map — exactly one is drawn, it replaces Apple's base map, and it is what
//  a bulk download fetches. A layer is none of those: it draws over all five
//  maps, Apple's included, and it never replaces anything. Putting it in
//  `TileProvider.all` would have made it selectable as a base map and given it
//  the paywall, preview card and download flags every base map carries, each
//  of which would then have had to be answered "not for this one".
//
//  There is one: OpenStreetMap's marked hiking routes, which the app draws
//  itself from squares it fetches — see `HikingRoutesRenderer.swift`. Until
//  2026-11 it was Waymarked Trails' tiles, fetched from a volunteer's server;
//  the squares are the same OpenStreetMap routes, on the phone once seen and
//  drawn at every zoom from 7.
//

import Foundation

/// What is drawn above the selected map and below the route.
///
/// `nonisolated` for the same reason ``TileProvider`` is: the map's code reads
/// it off the main actor, and a pure value has nothing to protect.
nonisolated struct TileLayer: Identifiable, Hashable, Sendable {
    /// Names the layer to the map, which rebuilds its overlay only when this
    /// changes. Never the same as any provider's.
    let id: String
    /// The shallowest zoom the layer is drawn at.
    let minimumZ: Int
    /// Required credits, added to the selected map's own whenever the layer
    /// is drawn — see ``TileAttribution/drawn(base:layer:)``.
    let attribution: TileAttribution
}

nonisolated extension TileLayer {
    /// OpenStreetMap's marked hiking routes, in the colours of their networks.
    ///
    /// Credited to OpenStreetMap alone: the squares are its data, read from a
    /// planet file, and the drawing is the app's.
    static let hikingRoutes = TileLayer(
        id: "hiking_routes",
        minimumZ: RouteSquareLevel.minimumZoom,
        attribution: TileAttribution([.openStreetMap])
    )

    /// The layer to draw for the stored switch, or `nil` when it is off.
    static func shown(isOn: Bool) -> TileLayer? {
        isOn ? .hikingRoutes : nil
    }
}
