//
//  TrailPlaceCorridorSearch.swift
//  OpenHikes
//
//  Finding the OpenStreetMap places on and around a finished trail — for a
//  hike that was recorded, imported, or saved from somebody else, none of
//  which went through the maker's *Search this area*. See
//  ``HikePlacesAroundView``.
//
//  ## As far off the line as the hiker asks
//
//  At its narrowest this is the maker's save question — what the line passes,
//  ``TrailPlaceAnchor/touchedOffRouteMeters`` — so a recorded walk and a drawn
//  one can end up with the same places by the same rule. *Places Around
//  Trail* asks further out than that, a kilometre at most, because a place off
//  the trail is still one a hiker may want on it: the hut up the side path
//  they walked to for lunch, the summit they photographed from the ridge. The
//  reach widens every stretch's circle by as much — see
//  ``marginMeters(reaching:)`` — and keeps what falls within it.
//
//  ## Asked in pieces along the line, one at a time
//
//  ``TrailPointQuery`` asks about a box, and caps it at
//  ``TrailPointQuery/maximumRadiusMeters`` because its figures were measured
//  over one. A recorded day is routinely longer than that box is wide, and one
//  box around the whole of a thirty-kilometre loop would also be mostly
//  valley the line never enters. So the line is cut into stretches whose own
//  bounding circle is at most ``stretchRadiusMeters`` — a quarter of the
//  measured box's area, so each answer is at most about a quarter of its 122
//  KB — and each is asked about in turn. In turn and not at once, for the
//  reason the maker's legs are routed one at a time: several simultaneous
//  requests from one phone is the shape that earns Overpass's `429`, and the
//  source's own ``OverpassConversation`` paces them.
//
//  A stretch that is refused is answered from what this device already keeps
//  (``TrailPointSourcing/cachedPlaces(near:limit:)``), and the refusal is
//  reported alongside whatever was found — the maker's rule that a refusal
//  never throws away what did arrive.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum TrailPlaceCorridorSearch {
    /// The widest stretch of line asked about at once, in metres of radius.
    static let stretchRadiusMeters: Double = 5000

    /// How far past the line a stretch's circle reaches. Enough to catch a
    /// hut that Overpass answers as the centre of its building, which is the
    /// case ``TrailPlaceAnchor/touchedOffRouteMeters`` makes room for.
    static let marginMeters: Double = 150

    /// The most stretches one search makes: a trail of a couple of hundred
    /// kilometres. Past that, the stretches grow rather than multiply — see
    /// ``areas(along:)`` — until they reach the query's own ceiling, and a
    /// line longer than twelve of those (235 km if it were straight, less as
    /// it winds) is searched only as far as the twelfth. Picked by reasoning,
    /// not measured against Overpass.
    static let maximumAreas = 12

    /// What a search found, and whether any stretch of it was refused.
    struct Outcome: Equatable, Sendable {
        /// The places the line passes, in the order they are met walking it,
        /// less any the hike already holds — with where each sits, worked out
        /// here off the main actor rather than again by the sheet.
        var rows: [TrailPlaceRow]
        /// The first refusal, if any stretch was refused. What was found
        /// elsewhere on the line is in ``places`` either way.
        var outage: CuratedTrailOutage?

        var places: [TrailPlace] { rows.map(\.place) }
    }

    /// The circles a search asks about, in order along the line.
    ///
    /// Greedy: a stretch grows point by point until its bounding circle would
    /// pass `radius`, and the next begins at the point that did not fit — so
    /// consecutive stretches share that point and no piece of line is left
    /// between them. A line that needs more than ``maximumAreas`` stretches is
    /// cut again with a wider radius, up to the query's own ceiling; one that
    /// still needs more at the ceiling keeps the first ``maximumAreas``.
    ///
    /// `reach` is how far off the line a place may stand and still be wanted,
    /// and widens every circle by that much — see ``marginMeters(reaching:)``.
    static func areas(
        along route: [RouteCoordinate],
        reaching reach: Double = TrailPlaceAnchor.touchedOffRouteMeters
    ) -> [CommunitySearchArea] {
        guard route.count > 1 else { return [] }
        let margin = marginMeters(reaching: reach)
        var radius = stretchRadiusMeters + margin - marginMeters
        while true {
            let cut = areas(along: route, radius: radius, margin: margin)
            let ceiling = TrailPointQuery.maximumRadiusMeters
            if cut.count <= maximumAreas || radius >= ceiling {
                return Array(cut.prefix(maximumAreas))
            }
            radius = min(radius * 2, ceiling)
        }
    }

    /// How far past the line a stretch's circle reaches for places up to
    /// `reach` off it: ``marginMeters`` beyond the reach, for the hut answered
    /// as the centre of its building.
    static func marginMeters(reaching reach: Double) -> Double {
        max(reach, TrailPlaceAnchor.touchedOffRouteMeters) - TrailPlaceAnchor.touchedOffRouteMeters + marginMeters
    }

    private static func areas(
        along route: [RouteCoordinate],
        radius: Double,
        margin: Double
    ) -> [CommunitySearchArea] {
        var result: [CommunitySearchArea] = []
        var box = Box(route[0])
        for point in densified(route, step: radius - margin).dropFirst() {
            var grown = box
            grown.include(point)
            if grown.radiusMeters + margin <= radius {
                box = grown
            } else {
                result.append(box.area(margin: margin))
                var next = Box(box.last)
                next.include(point)
                box = next
            }
        }
        result.append(box.area(margin: margin))
        return result
    }

    /// `route` with points added along any segment longer than `step`, so no
    /// two neighbours are further apart than that.
    ///
    /// The cut above only ever checks a stretch as it grows, and a stretch
    /// that starts afresh holds two points whatever their distance. A sparse
    /// imported file — a gap in a recording, a planner that wrote a point
    /// every twenty kilometres — would make that one segment a circle wider
    /// than ``TrailPointQuery/maximumRadiusMeters``, which the query answers
    /// with nothing rather than an error, so the stretch would be skipped
    /// without a word. Straight lines between the two ends are enough: the
    /// circle only has to hold the segment, not follow the ground — but the
    /// short way round, which ``RouteGeometry/interpolate(from:to:fraction:)``
    /// takes, or a segment across ±180° is filled in across the whole world.
    private static func densified(_ route: [RouteCoordinate], step: Double) -> [RouteCoordinate] {
        guard step > 0 else { return route }
        var result: [RouteCoordinate] = [route[0]]
        for (from, to) in route.adjacentPairs() {
            let length = RouteGeometry.distanceMeters(from: from.clCoordinate, to: to.clCoordinate)
            let pieces = Int((length / step).rounded(.up))
            if pieces > 1 {
                for index in 1..<pieces {
                    let point = RouteGeometry.interpolate(
                        from: from.clCoordinate,
                        to: to.clCoordinate,
                        fraction: Double(index) / Double(pieces)
                    )
                    result.append(RouteCoordinate(latitude: point.latitude, longitude: point.longitude))
                }
            }
            result.append(to)
        }
        return result
    }

    /// The places `route` passes that `held` does not already have, asked of
    /// `source` stretch by stretch.
    ///
    /// Throws only a cancellation. Every other failure is a stretch answered
    /// from the device's store and reported in ``Outcome/outage``.
    @concurrent
    static func search(
        along route: [RouteCoordinate],
        excluding held: [TrailPlace],
        from source: any TrailPointSourcing,
        showing symbols: Set<TrailPlaceSymbol>,
        reaching reach: Double = TrailPlaceAnchor.touchedOffRouteMeters
    ) async throws -> Outcome {
        var found: [TrailPlace] = []
        var outage: CuratedTrailOutage?
        for area in areas(along: route, reaching: reach) {
            try Task.checkCancellation()
            do {
                found += try await source.places(near: area, showing: symbols)
            } catch {
                guard let refusal = CuratedTrailOutage(error) else { throw CancellationError() }
                outage = outage ?? refusal
                found += await source.cachedPlaces(near: area, limit: TrailPointQuery.maximumStoredResults)
            }
        }
        let wanted = found.filter { place in place.symbol.map(symbols.contains) ?? true }
        return Outcome(rows: kept(wanted, along: route, excluding: held, reaching: reach), outage: outage)
    }

    /// Of `found`, one of each element, the ones within `reach` of the line
    /// that the hike does not already hold, in walking order.
    ///
    /// One of each first, because neighbouring stretches overlap by design and
    /// both answer for the hut on their shared edge.
    static func kept(
        _ found: [TrailPlace],
        along route: [RouteCoordinate],
        excluding held: [TrailPlace],
        reaching reach: Double = TrailPlaceAnchor.touchedOffRouteMeters
    ) -> [TrailPlaceRow] {
        var seen: Set<String> = []
        let unique = found.filter { place in
            guard let osm = place.osm else { return true }
            return seen.insert("\(osm.elementType)/\(osm.elementID)").inserted
        }
        let fresh = TrailPlaceHolding.unheld(unique, by: held)
        return TrailPlaceOrder.ordered(fresh, along: route).filter { row in
            row.offRouteMeters.map { $0 <= max(reach, TrailPlaceAnchor.touchedOffRouteMeters) } ?? false
        }
    }

    /// A stretch's bounding box, in degrees.
    ///
    /// Its longitudes are unwrapped from the stretch's first point: each new
    /// point is placed the short way from the one before, so a stretch across
    /// ±180° runs on past 180 rather than jumping back to -180 and spanning
    /// the whole world. Only the centre is brought back into range. A stretch
    /// is at most ``TrailPointQuery/maximumRadiusMeters`` wide, so the short
    /// way is always the way the line went.
    private struct Box {
        var south: Double
        var west: Double
        var north: Double
        var east: Double
        var last: RouteCoordinate
        /// `last`'s longitude in the box's unwrapped frame.
        private var lastLongitude: Double

        init(_ point: RouteCoordinate) {
            south = point.latitude
            north = point.latitude
            west = point.longitude
            east = point.longitude
            last = point
            lastLongitude = point.longitude
        }

        mutating func include(_ point: RouteCoordinate) {
            let longitude = lastLongitude
                + RouteGeometry.normalizedLongitudeDelta(point.longitude - last.longitude)
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, longitude)
            east = max(east, longitude)
            last = point
            lastLongitude = longitude
        }

        var centre: CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: (south + north) / 2,
                longitude: RouteGeometry.normalizedLongitude((west + east) / 2)
            )
        }

        /// Half the box's diagonal: the circle about its centre that holds it.
        var radiusMeters: Double {
            RouteGeometry.distanceMeters(
                from: CLLocationCoordinate2D(latitude: south, longitude: west),
                to: CLLocationCoordinate2D(latitude: north, longitude: east)
            ) / 2
        }

        func area(margin: Double) -> CommunitySearchArea {
            CommunitySearchArea(coordinate: centre, radiusMeters: radiusMeters + margin)
        }
    }
}

/// Which found places a hike does not already have: not the same
/// OpenStreetMap element, and not within ``TrailPointRanking/alreadyMarkedMeters``
/// of a place it holds — the rule ``Hike/addPlaces(_:in:now:)`` applies.
nonisolated enum TrailPlaceHolding {
    static func unheld(_ found: [TrailPlace], by held: [TrailPlace]) -> [TrailPlace] {
        guard !held.isEmpty else { return found }
        let heldElements = Set(held.compactMap(\.osm).map { "\($0.elementType)/\($0.elementID)" })
        return TrailPointRanking.excluding(held, from: found).filter { place in
            guard let osm = place.osm else { return true }
            return !heldElements.contains("\(osm.elementType)/\(osm.elementID)")
        }
    }
}
