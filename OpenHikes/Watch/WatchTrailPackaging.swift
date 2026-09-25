//
//  WatchTrailPackaging.swift
//  OpenHikes
//
//  Turning a hike into the small thing a watch can hold.
//
//  ## Why this is not `BackgroundTrailTracker.buildSnapshotOffMain`
//
//  The two look alike and answer different questions — see
//  ``WatchTrailPackage``'s header. A snapshot is a picture of a match the
//  *phone* already made, decimated to 180 points because a widget draws it and
//  nothing measures against it. A package is the input to the watch's own
//  arithmetic, so it carries an order of magnitude more points and the trail's
//  own elevations.
//
//  What they must agree on is the trail's *length*, and they do, because both
//  read `Hike.distanceMeters` rather than measuring the line they send.
//
//  ## Off the main actor
//
//  A route is the largest thing this app holds in memory and the longest thing
//  it serializes; this walks one and encodes a few hundred points of it, and a
//  watch asking for a trail must not cost the hiker a frame on the phone they
//  are holding. The same shape `HikeImport.stored` and
//  `BackgroundTrailTracker.buildSnapshotOffMain` use: values are read off the
//  model on the main actor, and only values cross — ``HikeRouteInput``, the
//  same one the widget's snapshot starts from.
//

import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum WatchTrailPackaging {
    /// The package, or `nil` for a hike with no line to send.
    ///
    /// A single-point route is a place rather than a trail, and every consumer
    /// on the watch wants a line: see ``WatchTrailPackage/isDrawable``. Sent
    /// anyway it would cost a transfer and draw nothing.
    @concurrent
    static func package(from input: HikeRouteInput) async -> WatchTrailPackage? {
        assertOffMainThread("Packaging a route for the watch must stay off the main thread")
        guard input.route.count > 1 else { return nil }
        // The same stride the widget's polyline uses, taken as *indices* so a
        // kept point's height is the height of that point rather than of one
        // nearby — see ``decimatedIndices(count:maxPoints:)``.
        let points = decimatedIndices(
            count: input.route.count,
            maxPoints: WatchTrailPackage.pointBudget
        ).map { index in
            let coordinate = input.route[index]
            return WatchTrailPoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                // Filtered the way every other encoder in this app filters a
                // route's heights — `GPXExport` and `CommunityRoutePayload`
                // both do it — because a non-finite one reaches the store and
                // `JSONEncoder` refuses it. Unfiltered, a single `nan`
                // silently sinks the whole transfer and leaves the watch
                // waiting for a trail that will never arrive.
                elevationMeters: coordinate.elevation.flatMap { $0.isFinite ? $0 : nil }
            )
        }
        let totals = RouteElevationTotals(of: input.route)
        return WatchTrailPackage(
            hikeID: input.hikeID,
            title: input.title,
            tintHex: input.tintHex,
            totalDistanceMeters: input.totalDistanceMeters,
            points: points,
            elevationGainMeters: totals.gainMeters,
            elevationLossMeters: totals.lossMeters
        )
    }

    /// Climb and descent over the *whole* route.
    ///
    /// Summed between consecutive points that carry an elevation rather than
    /// taken as high minus low, which a rolling trail understates by every
    /// descent it makes on the way up — the argument
    /// ``SharedTrailSnapshot/elevationGainMeters`` already makes. Measured
    /// before decimation, because dropping points removes the little rises
    /// they spanned.
    private struct RouteElevationTotals {
        let gainMeters: Double?
        let lossMeters: Double?

        init(of route: [RouteCoordinate]) {
            var gain = 0.0
            var loss = 0.0
            var previous: Double?
            var sawAny = false
            for elevation in route.compactMap(\.elevation) where elevation.isFinite {
                sawAny = true
                defer { previous = elevation }
                guard let last = previous else { continue }
                let change = elevation - last
                if change > 0 { gain += change } else { loss -= change }
            }
            gainMeters = sawAny ? gain : nil
            lossMeters = sawAny ? loss : nil
        }
    }
}
