//
//  TrailPointRanking.swift
//  OpenHikes
//
//  Which of the places Overpass answered with are worth offering, and in what
//  order.
//
//  **Ranked against the line, not against the screen, and that is the whole
//  reason this feature lives in the maker rather than on the browse map.**
//  *What is near what I am drawing* is a question only this screen can ask: a
//  hiker drawing a valley walk wants the spring on the climb and the hut at
//  the saddle, not the two hundred summits the box happens to contain. So the
//  nearest few to the *nearest leg* are what is kept, and a drawing that has
//  no line yet falls back to distance from the middle of the map, which is the
//  only thing that can stand in for it.
//
//  Choosing runs over everything the box held — 578 elements in the densest
//  Alpine mapping there is, see ``TrailPointQuery`` — against a snapped line
//  that is thousands of coordinates, once per Overpass round trip. It is
//  ``TrailPlaceOrder``'s arithmetic rather than a second copy of it.
//
//  ## And the choosing is done off the main actor
//
//  Which follows from the sizes above rather than from a rule. 578 candidates
//  against a snapped line of a few thousand coordinates is over a million
//  projections, each of them trigonometry, and the actor it would otherwise
//  run on is the one drawing the map the hiker is looking at. So
//  ``offered(from:along:in:excluding:limit:)`` is `@concurrent` and is the
//  whole of what a search does between the answer landing and the pins going
//  down.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum TrailPointRanking {
    /// The whole choosing step, off the main actor: the places the hiker has
    /// already marked taken out, and the nearest `limit` of what is left
    /// picked against the line.
    ///
    /// One function rather than two calls at each of the two sites that need
    /// it — a search that answered and a refusal drawing from disk — because
    /// the pair has to stay in that order. Excluding after choosing would let
    /// the hiker's own hut take one of the forty places on offer and then be
    /// removed from it, so a search would quietly offer thirty-nine.
    ///
    /// - Parameter area: where the map is looking, which is what the ranking
    ///   falls back to when there is no line yet. A whole
    ///   ``CommunitySearchArea`` rather than its centre because a
    ///   `CLLocationCoordinate2D` is not `Sendable` and this crosses an
    ///   isolation boundary.
    @concurrent
    static func offered(
        from found: [TrailPlace],
        along route: [RouteCoordinate],
        in area: CommunitySearchArea?,
        excluding placed: [TrailPlace],
        limit: Int = TrailPointQuery.maximumResults
    ) async -> [TrailPlace] {
        chosen(
            from: excluding(placed, from: found),
            along: route,
            around: area?.coordinate,
            limit: limit
        )
    }

    /// `found` without the places the hiker already has.
    ///
    /// By where they are rather than by identity, because there is no identity
    /// to compare: a marked place carries a `UUID` this device made and an
    /// Overpass answer carries whatever the store or the decoder minted for
    /// it. What a hiker would see without this is their own hut with a second,
    /// provisional pin under it, offering to add the hut again.
    ///
    /// The tolerance is a few metres because that is what the two coordinates
    /// actually differ by: a hiker who marked a spring by tapping the map put
    /// their pin where OpenStreetMap's node is, give or take a thumb.
    static func excluding(
        _ placed: [TrailPlace],
        from found: [TrailPlace]
    ) -> [TrailPlace] {
        guard !placed.isEmpty else { return found }
        return found.filter { candidate in
            !placed.contains { marked in
                RouteGeometry.distanceMeters(
                    from: marked.clCoordinate,
                    to: candidate.clCoordinate
                ) <= alreadyMarkedMeters
            }
        }
    }

    /// How close a candidate has to be to a marked place to be the same place
    /// — see ``TrailPlace/alreadyMarkedMeters``, which a saved hike's own
    /// place list reads too.
    static let alreadyMarkedMeters = TrailPlace.alreadyMarkedMeters

    /// The `limit` places of `found` nearest the drawing, or nearest
    /// `centre` where there is no drawing to be near.
    ///
    /// Nearest to the **line** rather than nearest to its start or its middle:
    /// a trail is long, and a hut half a kilometre from its far end is nearer
    /// to the walk than a summit a hundred metres from its first point is to
    /// the rest of it. ``TrailPlaceAnchor/offRouteMeters`` is that distance
    /// and arrives free with the projection.
    ///
    /// `centre` is `nil` only where a caller has neither a line nor a map,
    /// which nothing in the app is; it answers the first `limit` in that case
    /// rather than refusing, because an arbitrary forty is a better answer
    /// than none to a question nobody can order.
    static func chosen(
        from found: [TrailPlace],
        along route: [RouteCoordinate],
        around centre: CLLocationCoordinate2D?,
        limit: Int = TrailPointQuery.maximumResults
    ) -> [TrailPlace] {
        guard found.count > limit else { return found }
        let anchors = TrailPlaceOrder.anchors(of: found, along: route)
        if anchors.isEmpty {
            guard let centre else { return Array(found.prefix(limit)) }
            return nearest(found, to: centre, limit: limit)
        }
        return found
            .map { place in
                // A place the line could not be measured against sorts behind
                // every one it could. It cannot happen while `anchors` is
                // non-empty — the same route was walked for all of them — and
                // is spelled rather than force-unwrapped because the two
                // collections are joined by a dictionary lookup.
                (place: place, distance: anchors[place.id]?.offRouteMeters ?? .infinity)
            }
            .min(count: limit) { $0.distance < $1.distance }
            .map(\.place)
    }

    /// The `limit` places nearest one coordinate.
    ///
    /// The fallback for a search made before anything has been drawn, which is
    /// a perfectly ordinary thing to do: marking the hut before drawing the
    /// walk to it is the most useful order to work in.
    private static func nearest(
        _ places: [TrailPlace],
        to centre: CLLocationCoordinate2D,
        limit: Int
    ) -> [TrailPlace] {
        places
            .map { place in
                (place: place, distance: RouteGeometry.distanceMeters(from: centre, to: place.clCoordinate))
            }
            // Measured once per place and then ordered, rather than measured
            // inside a comparator — the shape ``CuratedTrailSource``'s own
            // listing sort takes, and for the same reason: a full sort would
            // run the arithmetic on both sides of every comparison.
            .min(count: limit) { $0.distance < $1.distance }
            .map(\.place)
    }
}
