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
        for item in items {
            let target = coordinate(item)
            let nearest = routes.indices
                .compactMap { index in offRouteMeters(of: target, along: routes[index]).map { (index, $0) } }
                .min { $0.1 < $1.1 }
            guard let nearest, nearest.1 <= TrailPlaceAnchor.touchedOffRouteMeters else { continue }
            assigned[nearest.0].append(item)
        }
        return assigned
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
