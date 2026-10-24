//
//  RouteCoordinate+TrailRuns.swift
//  OpenHikesData
//
//  A stored route cut at its pauses: the way into ``TrailRuns`` for a reader
//  of a `[RouteCoordinate]` (#1035).
//
//  A ``RouteBoundary`` sits on the point a pause *arrives* at, and a reader
//  wants legs and runs. The conversion between the two is the one place a
//  reader of a route could be off by one, so the readers #1035 moved make it
//  here; a reader iterates what comes back and never sees a paused leg.
//

import OpenHikesShared

nonisolated public extension [RouteCoordinate] {
    /// The route cut at its pauses: a paused leg is not distance and not
    /// trail (see ``RouteBoundary``).
    var trailRuns: TrailRuns {
        trailRuns(cutAt: \.isPauseBoundary)
    }

    /// The route cut at every leg arriving at a point `isCut` holds for.
    ///
    /// For a reader whose rule refuses more than a pause, and says so where it
    /// reads: a photograph's place refuses the app's own bridges across a
    /// lost signal as well (`RecordedRouteLegs`), where the profile projects
    /// onto them. The other readers #1035 moved take ``trailRuns``.
    func trailRuns(cutAt isCut: (RouteCoordinate) -> Bool) -> TrailRuns {
        TrailRuns(pointCount: count, pauseIndices: indices.filter { isCut(self[$0]) })
    }
}
