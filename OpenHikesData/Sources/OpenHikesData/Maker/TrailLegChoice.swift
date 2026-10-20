//
//  TrailLegChoice.swift
//  OpenHikes
//
//  The way a hiker picked for one leg of a drawn trail, kept with the
//  drawing.
//
//  Everything else a drawing is written down as is what it was drawn *from*:
//  the stops, the mode, the switch. The legs between them are not, because
//  they are re-derivable — reopen the drawing and the router answers the same
//  question with the same shape. A tap on a grey alternative is the one fact
//  about a leg that is not: the router's answer between the same two stops is
//  its own default, and nothing about the stops says the hiker preferred the
//  other way. So the chosen way is kept beside the stops, by the two places it
//  runs between, and laid back over the router's answer when that lands.
//
//  The whole shape rather than an index into the router's alternatives: an
//  index means nothing to a router that has since answered in another order,
//  and a hiker's choice has to survive Apple Maps rethinking its routes.
//

import Foundation

nonisolated public struct TrailLegChoice: Codable, Hashable, Sendable {
    /// Where the leg starts and ends — the two stops' places, which are what
    /// the maker looks a leg up by.
    public var start: RouteCoordinate
    public var end: RouteCoordinate
    /// The way chosen, both ends included.
    public var coordinates: [RouteCoordinate]
    public var distanceMeters: Double
    /// Apple Maps' estimate for this way, or `nil` where only a distance was
    /// known.
    public var travelTime: TimeInterval?

    public init(
        start: RouteCoordinate,
        end: RouteCoordinate,
        coordinates: [RouteCoordinate],
        distanceMeters: Double,
        travelTime: TimeInterval?
    ) {
        self.start = start
        self.end = end
        self.coordinates = coordinates
        self.distanceMeters = distanceMeters
        self.travelTime = travelTime
    }
}
