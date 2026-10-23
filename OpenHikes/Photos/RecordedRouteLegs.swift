//
//  RecordedRouteLegs.swift
//  OpenHikes
//
//  Whether a place is on the line a route actually measured, for a camera
//  whose own position is all there is to go on.
//
//  A recording is sampled every few metres, so the nearest of its points is
//  within a couple of metres of the nearest point on its line, and testing the
//  points alone used to be enough. A timestamped GPX file is not held to that:
//  it can carry a fix every twenty minutes, a kilometre and a half apart, and a
//  photograph taken on the trail halfway between two of them is that far from
//  both (#965). So the line is tested, one leg at a time.
//
//  Only the legs that were walked and measured, though. A leg arriving at a
//  ``RouteBoundary/paused`` point is the straight line across a pause — the
//  cable car, the lift to the next trailhead — which the hiker told the
//  recording not to watch. It is not trail: ``HikePhotoTimeline`` refuses to
//  place anything along it, and ``RouteProfile``, which the walks and the
//  picker project with, never matches onto it either. A leg arriving at a
//  ``RouteProvenance/inferred`` point is the app's own bridge across a gap in
//  the signal: a guess, and a straight one where no trail was found. Neither
//  may turn a picture taken somewhere along it into a picture of this walk.
//
//  Their ends are real fixes, and still count as points on the route, exactly
//  as they did before any leg was projected onto. That, and the bridge, are
//  where this and ``RouteProfile`` part: a profile projects onto a bridge, and
//  a route whose every leg is paused leaves it nothing to answer with, where
//  this still measures to the fixes.
//
//  Built once per search, by ``HikePhotoSearchPlan``, and asked once per photo
//  the clock could not place.
//

import CoreLocation
import Foundation
import OpenHikesData

nonisolated struct RecordedRouteLegs: Sendable {
    /// The route's points, in route order — untimestamped ones included, since
    /// a leg runs between neighbours whatever their clocks say.
    private let coordinates: [CLLocationCoordinate2D]
    /// Whether the leg from `coordinates[i]` to `coordinates[i + 1]` was
    /// walked and measured; one shorter than ``coordinates``.
    private let measured: [Bool]

    init(route: [RouteCoordinate]) {
        coordinates = route.map(\.clCoordinate)
        // A boundary or a provenance describes the leg *arriving* at the point
        // that carries it, so leg `i` is judged by point `i + 1`.
        measured = route.dropFirst().map { !$0.isPauseBoundary && !$0.isInferred }
    }

    /// The closest point to `coordinate` on a measured leg, or at any of the
    /// route's own points, and how far away it is. `nil` for an empty route.
    func nearestPoint(
        to coordinate: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, meters: Double)? {
        var best: (coordinate: CLLocationCoordinate2D, meters: Double)?
        for index in coordinates.indices {
            if index < measured.count, measured[index] {
                let start = coordinates[index]
                let end = coordinates[index + 1]
                let projection = RouteGeometry.project(coordinate, onSegmentFrom: start, to: end)
                if projection.offRouteMeters < (best?.meters ?? .infinity) {
                    best = (
                        RouteGeometry.interpolate(from: start, to: end, fraction: projection.fraction),
                        projection.offRouteMeters
                    )
                }
            }
            // A point with a measured leg on either side is already one of
            // that leg's candidates, at a fraction of 0 or 1. The rest — the
            // ends of a paused or bridged leg with nothing measured beside
            // them, or a route of one point — are tested as points.
            let followsMeasuredLeg = index > 0 && measured[index - 1]
            let leadsMeasuredLeg = index < measured.count && measured[index]
            guard !followsMeasuredLeg, !leadsMeasuredLeg else { continue }
            let point = coordinates[index]
            let meters = RouteGeometry.distanceMeters(from: coordinate, to: point)
            if meters < (best?.meters ?? .infinity) {
                best = (point, meters)
            }
        }
        return best
    }
}
