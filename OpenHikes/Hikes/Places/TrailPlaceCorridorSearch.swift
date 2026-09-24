//
//  TrailPlaceCorridorSearch.swift
//  OpenHikes
//
//  Finding the OpenStreetMap places a finished trail passes — for a hike that
//  was recorded, imported, or saved from somebody else, none of which went
//  through the maker's *Search this area*.
//
//  ## The same answer the maker's save keeps
//
//  A drawn trail keeps only the places its line passes
//  (``TrailPlaceOrder/touched(_:along:)``, 50 m), and this answers the same
//  question about any other trail — so a recorded walk and a drawn one end up
//  with the same kind of places, by the same rule. What the maker offers while
//  a route is still being decided (the summit across the valley) is not
//  offered here, because the route is decided.
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

import CoreLocation
import Foundation
import Observation
import os
import SwiftData

nonisolated enum TrailPlaceCorridorSearch {
    /// The widest stretch of line asked about at once, in metres of radius.
    static let stretchRadiusMeters: Double = 5000

    /// How far past the line a stretch's circle reaches. Enough to catch a
    /// hut that Overpass answers as the centre of its building, which is the
    /// case ``TrailPlaceAnchor/touchedOffRouteMeters`` makes room for.
    static let marginMeters: Double = 150

    /// The most stretches one search makes: a trail of a couple of hundred
    /// kilometres. Past that, the stretches grow rather than multiply — see
    /// ``areas(along:)``.
    static let maximumAreas = 12

    /// What a search found, and whether any stretch of it was refused.
    struct Outcome: Equatable, Sendable {
        /// The places the line passes, in the order they are met walking it,
        /// less any the hike already holds.
        var places: [TrailPlace]
        /// The first refusal, if any stretch was refused. What was found
        /// elsewhere on the line is in ``places`` either way.
        var outage: CuratedTrailOutage?
    }

    /// The circles a search asks about, in order along the line.
    ///
    /// Greedy: a stretch grows point by point until its bounding circle would
    /// pass `radius`, and the next begins at the point that did not fit — so
    /// consecutive stretches share that point and no piece of line is left
    /// between them. A line that needs more than ``maximumAreas`` stretches is
    /// cut again with a wider radius, up to the query's own ceiling.
    static func areas(along route: [RouteCoordinate]) -> [CommunitySearchArea] {
        guard route.count > 1 else { return [] }
        var radius = stretchRadiusMeters
        while true {
            let cut = areas(along: route, radius: radius)
            let ceiling = TrailPointQuery.maximumRadiusMeters
            if cut.count <= maximumAreas || radius >= ceiling {
                return Array(cut.prefix(maximumAreas))
            }
            radius = min(radius * 2, ceiling)
        }
    }

    private static func areas(along route: [RouteCoordinate], radius: Double) -> [CommunitySearchArea] {
        var result: [CommunitySearchArea] = []
        var box = Box(route[0])
        for point in route.dropFirst() {
            var grown = box
            grown.include(point)
            if grown.radiusMeters + marginMeters <= radius {
                box = grown
            } else {
                result.append(box.area(margin: marginMeters))
                var next = Box(box.last)
                next.include(point)
                box = next
            }
        }
        result.append(box.area(margin: marginMeters))
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
        showing symbols: Set<TrailPlaceSymbol>
    ) async throws -> Outcome {
        var found: [TrailPlace] = []
        var outage: CuratedTrailOutage?
        for area in areas(along: route) {
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
        return Outcome(places: kept(wanted, along: route, excluding: held), outage: outage)
    }

    /// Of `found`, one of each element, the ones the line passes and the hike
    /// does not already hold, in walking order.
    ///
    /// One of each first, because neighbouring stretches overlap by design and
    /// both answer for the hut on their shared edge.
    static func kept(
        _ found: [TrailPlace],
        along route: [RouteCoordinate],
        excluding held: [TrailPlace]
    ) -> [TrailPlace] {
        var seen: Set<String> = []
        let unique = found.filter { place in
            guard let osm = place.osm else { return true }
            return seen.insert("\(osm.elementType)/\(osm.elementID)").inserted
        }
        let touched = TrailPlaceOrder.touched(unique, along: route)
        let heldElements = Set(held.compactMap(\.osm).map { "\($0.elementType)/\($0.elementID)" })
        let fresh = TrailPointRanking.excluding(held, from: touched).filter { place in
            guard let osm = place.osm else { return true }
            return !heldElements.contains("\(osm.elementType)/\(osm.elementID)")
        }
        return TrailPlaceOrder.ordered(fresh, along: route).map(\.place)
    }

    /// A stretch's bounding box, in degrees.
    private struct Box {
        var south: Double
        var west: Double
        var north: Double
        var east: Double
        var last: RouteCoordinate

        init(_ point: RouteCoordinate) {
            south = point.latitude
            north = point.latitude
            west = point.longitude
            east = point.longitude
            last = point
        }

        mutating func include(_ point: RouteCoordinate) {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
            last = point
        }

        var centre: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
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

/// Where a *Find Places Along Trail* asks, and which kinds it asks for.
struct TrailPlaceSearchScope {
    let source: any TrailPointSourcing
    /// The maker's switches — see ``TrailPlaceFilter`` — which are app-wide.
    let symbols: Set<TrailPlaceSymbol>
}

/// One *Find Places Along Trail*, for the sheet that asks it.
///
/// A reference type the sheet owns, so the search outlives a body pass and is
/// cancelled with the sheet — see ``cancel()``.
@MainActor
@Observable
final class HikePlaceSearch {
    enum Phase: Equatable {
        case searching
        case found([TrailPlaceRow], outage: CuratedTrailOutage?)
        case failed(CuratedTrailOutage)
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "Places")

    private(set) var phase = Phase.searching
    /// The found places the hiker is keeping. All of them, to begin with.
    var chosen: Set<UUID> = []

    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated deinit { /* intentionally empty */ }

    /// Whether *Add* has anything to add.
    var canAdd: Bool {
        guard case .found(let rows, _) = phase else { return false }
        return rows.contains { chosen.contains($0.id) }
    }

    /// Asks about `hike`'s line.
    func start(
        for hike: Hike,
        source: any TrailPointSourcing,
        showing symbols: Set<TrailPlaceSymbol>
    ) {
        task?.cancel()
        phase = .searching
        let route = hike.route
        let held = hike.places
        task = Task { [weak self] in
            let outcome: TrailPlaceCorridorSearch.Outcome
            do {
                outcome = try await TrailPlaceCorridorSearch.search(
                    along: route,
                    excluding: held,
                    from: source,
                    showing: symbols
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            receive(outcome, along: route)
        }
    }

    func receive(_ outcome: TrailPlaceCorridorSearch.Outcome, along route: [RouteCoordinate]) {
        if outcome.places.isEmpty, let outage = outcome.outage {
            Self.logger.info("A search along a trail was refused: \(String(describing: outage), privacy: .public)")
            phase = .failed(outage)
            return
        }
        let rows = TrailPlaceOrder.ordered(outcome.places, along: route)
        chosen = Set(rows.map(\.id))
        phase = .found(rows, outage: outcome.outage)
    }

    func toggle(_ id: UUID) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    /// Adds the chosen places to `hike`, answering how many went in.
    @discardableResult func add(to hike: Hike, in context: ModelContext) -> Int {
        guard case .found(let rows, _) = phase else { return 0 }
        let places = rows.map(\.place).filter { chosen.contains($0.id) }
        let added = hike.addPlaces(places, in: context)
        do {
            try context.save()
        } catch {
            // Left to the next autosave rather than taken back: the rows are
            // on the hike, and a place is not a file that can be orphaned.
            Self.logger.error(
                "Places found along a trail could not be saved: \(error.localizedDescription, privacy: .public)"
            )
        }
        return added.count
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
