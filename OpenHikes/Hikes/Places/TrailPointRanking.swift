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
//  ## Choosing is done once; placing is done again
//
//  ``chosen(from:along:around:limit:)`` runs when a search lands and decides
//  *which* forty. ``rows(of:along:)`` runs whenever the drawing changes and
//  decides where each of those forty sits along the line — because a leg that
//  snaps through a valley moves every distance without the hiker having
//  touched anything.
//
//  Split that way for a measured reason rather than a tidy one. Choosing runs
//  over everything the box held — 578 elements in the densest Alpine mapping
//  there is, see ``TrailPointQuery`` — against a snapped line that is
//  thousands of coordinates, which is fine once per Overpass round trip and is
//  not fine once per tap while a hiker is putting points down. Re-placing runs
//  over the forty that were kept.
//
//  Both are ``TrailPlaceOrder``'s arithmetic rather than a second copy of it:
//  a candidate is an unmarked ``TrailPlace``, so *where does this sit along
//  the line* is already answered, once per route rather than once per place.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated enum TrailPointRanking {
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

    /// `places` in the order they are met walking `route`, each with where it
    /// sits.
    ///
    /// ``TrailPlaceOrder/ordered(_:along:)`` exactly, and it is worth saying
    /// why this wrapper exists rather than the call site using that directly:
    /// the candidates are drawn *beside* the marked places, in the same list
    /// and in the same kind of row, and having one function name for "put
    /// these in along-route order" is what keeps the two halves of that screen
    /// from drifting into two different ideas of what an order is.
    static func rows(of places: [TrailPlace], along route: [RouteCoordinate]) -> [TrailPlaceRow] {
        TrailPlaceOrder.ordered(places, along: route)
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
