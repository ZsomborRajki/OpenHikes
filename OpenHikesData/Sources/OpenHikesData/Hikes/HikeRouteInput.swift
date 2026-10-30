//
//  HikeRouteInput.swift
//  OpenHikesData
//
//  What a hike looks like once it is off the main actor.
//
//  A `Hike` is a `@Model` and cannot cross an isolation boundary, so the work
//  that walks its route off the main actor starts from values read off one
//  where its context lives. Three pieces of work do: the widget's trail
//  snapshot, the snapshots of the trails placed widgets are pinned to, and
//  the package a watch is sent.
//  They used to start from two structs with the same five fields, and the two
//  disagreed about the one field that is a decision — the watch was sent the
//  name the hiker had given a hike, and the widget drew the one it was
//  imported under.
//

import Foundation

/// The values off-main route work needs from a hike, read while the hike is
/// still in hand.
nonisolated public struct HikeRouteInput: Sendable {
    public let hikeID: UUID
    /// The name the hiker has seen — ``Hike/displayTitle``, resolved here so
    /// nothing downstream has to know a custom name exists: the widget, the
    /// watch and the pinned-trail catalogue all say what the library says.
    public let title: String
    public let tintHex: String
    public let totalDistanceMeters: Double
    public let route: [RouteCoordinate]

    /// Read wherever the hike's context lives: on the main actor for the
    /// selected trail's live fixes, and off it for the widget's background
    /// match, the pinned trails' snapshots and the trail a watch asks for,
    /// each of which fetches the hike into a context of its own there. So
    /// nothing here is isolated — each field is a column of the model, read
    /// on the thread that owns it.
    public init(hike: Hike) {
        self = Self(columnsOf: hike).replacingRoute(with: hike.route)
    }

    /// Everything but the route, for a route read somewhere else and added
    /// with ``replacingRoute(with:)``: the selected trail's widget feed reads
    /// these where the hike lives, on the main actor, and its route in a
    /// context of its own off it, where reading it does not decode the whole
    /// line on the main thread.
    public init(columnsOf hike: Hike) {
        self.init(
            hikeID: hike.id,
            title: hike.displayTitle,
            tintHex: hike.tintHex,
            totalDistanceMeters: hike.distanceMeters,
            route: []
        )
    }

    /// These values with `route` in place of their own.
    public func replacingRoute(with route: [RouteCoordinate]) -> Self {
        Self(
            hikeID: hikeID,
            title: title,
            tintHex: tintHex,
            totalDistanceMeters: totalDistanceMeters,
            route: route
        )
    }

    private init(hikeID: UUID, title: String, tintHex: String, totalDistanceMeters: Double, route: [RouteCoordinate]) {
        self.hikeID = hikeID
        self.title = title
        self.tintHex = tintHex
        self.totalDistanceMeters = totalDistanceMeters
        self.route = route
    }
}
