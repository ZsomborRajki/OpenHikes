//
//  GPXTrackSplit.swift
//  OpenHikes
//
//  Which of a multi-track file's hikes each of its loose waypoints belongs to.
//
//  A `<wpt>` is a child of `<gpx>`, not of any `<trk>`, so a file with three
//  days in it says nothing about which day the hut was on. The line does: a
//  waypoint belongs to the track it lies on, by the rule a drawn trail's save
//  already uses for its places — within ``TrailPlaceAnchor/touchedOffRouteMeters``
//  of the route (``TrailPlaceOrder``). One that lies on two goes to the nearer;
//  one that lies on none is dropped rather than pinned to a day it was never
//  part of, and the confirmation says how many were.
//

import CoreLocation
import Foundation

nonisolated enum GPXTrackSplit {
    /// `items`, shared out among `routes`: one list per route, in the order
    /// the routes were given, each in the order the items were.
    static func assign<Item>(
        _ items: [Item],
        at coordinate: (Item) -> CLLocationCoordinate2D,
        to routes: [[RouteCoordinate]]
    ) -> [[Item]] {
        var assigned = Array(repeating: [Item](), count: routes.count)
        guard !items.isEmpty else { return assigned }
        let reaches = routes.map(Reach.init)
        for item in items {
            let target = coordinate(item)
            let nearest = routes.indices
                .filter { reaches[$0].mayHold(target) }
                .compactMap { index in offRouteMeters(of: target, along: routes[index]).map { (index, $0) } }
                .min { $0.1 < $1.1 }
            guard let nearest, nearest.1 <= TrailPlaceAnchor.touchedOffRouteMeters else { continue }
            assigned[nearest.0].append(item)
        }
        return assigned
    }

    /// A route's bounding box grown by the touching distance: a waypoint
    /// outside it cannot lie on the route, so the route is not measured for it.
    ///
    /// The measuring is every segment of the route, and without this every
    /// waypoint pays it for every track — a region's download of forty walks
    /// with a few dozen huts marked is tens of millions of projections for
    /// answers that are almost all "a valley away". Checked against the box
    /// first, each waypoint measures only the one or two walks it could be on.
    ///
    /// A route whose grown box reaches past ±180° is always measured instead,
    /// because a box that wraps cannot be held as one span of longitude and
    /// being slow there beats refusing a waypoint that is ten metres away
    /// across the antimeridian.
    private struct Reach {
        private var south = Double.infinity
        private var north = -Double.infinity
        private var west = Double.infinity
        private var east = -Double.infinity
        private var wraps = false
        /// No points, so nothing lies on it — and no box to build a range from.
        private var isEmpty = true

        init(_ route: [RouteCoordinate]) {
            for point in route {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
                west = min(west, point.longitude)
                east = max(east, point.longitude)
            }
            guard !route.isEmpty else { return }
            isEmpty = false
            let margin = TrailPlaceAnchor.touchedOffRouteMeters
            let latitudeMargin = margin / Self.metersPerDegree
            // Widest where the box is nearest a pole; the importer refuses
            // anything past Web Mercator's ~85°, so the cosine never reaches 0.
            let widest = max(abs(south), abs(north)) + latitudeMargin
            let longitudeMargin = margin
                / (Self.metersPerDegree * cos(min(widest, Self.steepestLatitude) * .pi / 180))
            south -= latitudeMargin
            north += latitudeMargin
            west -= longitudeMargin
            east += longitudeMargin
            wraps = west < -180 || east > 180
        }

        func mayHold(_ coordinate: CLLocationCoordinate2D) -> Bool {
            if isEmpty { return false }
            if wraps { return true }
            return (south...north).contains(coordinate.latitude)
                && (west...east).contains(coordinate.longitude)
        }

        /// A little under a degree of latitude's length anywhere, so the
        /// margin it yields is a little over the distance, never under it.
        private static let metersPerDegree = 110_000.0
        /// Where the cosine is held, short of the pole it would reach zero at.
        private static let steepestLatitude = 89.0
    }

    /// How far `coordinate` is from the nearest point of `route`, or `nil` for
    /// a route with fewer than two points.
    static func offRouteMeters(
        of coordinate: CLLocationCoordinate2D,
        along route: [RouteCoordinate]
    ) -> Double? {
        guard route.count > 1 else { return nil }
        var nearest = Double.infinity
        for (start, end) in zip(route, route.dropFirst()) {
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: start.clCoordinate,
                to: end.clCoordinate
            )
            nearest = min(nearest, projection.offRouteMeters)
        }
        return nearest
    }
}
