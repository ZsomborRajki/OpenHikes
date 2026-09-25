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
    /// catalogue and the watch, and off it for the widget's background match,
    /// which fetches the hike into a context of its own there. So nothing here
    /// is isolated — each field is a column of the model, read on the thread
    /// that owns it.
    public init(hike: Hike) {
        hikeID = hike.id
        title = hike.displayTitle
        tintHex = hike.tintHex
        totalDistanceMeters = hike.distanceMeters
        route = hike.route
    }
}
