//
//  RouteReroute.swift
//  OpenHikes
//
//  Drawing a stretch of a hike's line along another path: who is asked for
//  the path, and what comes back.
//
//  ## The maker's router, not one of its own
//
//  *Edit Route* asks the same question the trail maker asks about a leg
//  between two stops — what is the way from here to there over mapped paths
//  — so it asks the same router, with its graph of trails and the roads that
//  join them, its cache of answers and its manners towards Overpass (see
//  ``TrailLegRouting``). A pull through a spot is two such legs, asked one
//  after the other.
//
//  ## A straight leg is still an answer
//
//  The router never refuses: a leg it cannot route comes back straight. For
//  a pull that is the answer — the hiker said the line went through there,
//  and where no path is mapped it goes there straight. *Follow Trails* asks
//  for mapped ground and nothing else, so it reads ``Way/isMapped`` and says
//  when there is none.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum RouteReroute {
    /// Who draws a path, and who knows where the junctions are.
    struct Services: Sendable {
        /// The trail maker's router. `nil` on a launch without one, where a
        /// stretch can still be straightened or taken out.
        var router: (any TrailLegRouting)?
        /// The trail graph a line's junctions are read from, which is what a
        /// pull on the map is bounded by — see ``TrailJunctionFinder``.
        var graph: (any TrailGraphProviding)?
    }

    /// The way between two points of a line.
    struct Way: Equatable, Sendable {
        var coordinates: [CLLocationCoordinate2D]
        /// Whether every leg of it follows mapped paths.
        var isMapped: Bool

        static func == (one: Self, other: Self) -> Bool {
            one.isMapped == other.isMapped && one.coordinates.map(RouteCoordinate.init)
                == other.coordinates.map(RouteCoordinate.init)
        }
    }

    /// The way from `start` to `end`, through `via` where the hiker pulled
    /// the line through a spot. `nil` when the question was cancelled.
    @concurrent
    static func way(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        using router: any TrailLegRouting,
        through via: CLLocationCoordinate2D? = nil
    ) async -> Way? {
        let spots = [start, via, end].compactMap(\.self).map(RouteCoordinate.init)
        var way = Way(coordinates: [], isMapped: true)
        // One after the other, for the reason the maker's legs are: see the
        // file header of `TrailLegRouter.swift`.
        for (from, to) in spots.adjacentPairs() {
            guard let leg = await router.route(TrailLegEnds(start: from, end: to)) else { return nil }
            if leg.snap != .snapped { way.isMapped = false }
            // The spot two legs meet at is drawn once.
            let points = leg.coordinates.map(\.clCoordinate)
            way.coordinates.append(contentsOf: way.coordinates.isEmpty ? points[...] : points.dropFirst())
        }
        return way
    }
}
