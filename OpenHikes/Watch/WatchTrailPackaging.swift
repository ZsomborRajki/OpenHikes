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
//  model on the main actor, and only values cross.
//

import Foundation
import OpenHikesShared

nonisolated enum WatchTrailPackaging {
    /// What a hike looks like once it is off the main actor.
    ///
    /// A `Hike` is a `@Model` and cannot cross an isolation boundary, so this
    /// is read from one on the main actor and is what the packaging works
    /// from — the same seam `BackgroundTrailTracker.SnapshotInput` is.
    struct Input: Sendable {
        let hikeID: UUID
        let title: String
        let tintHex: String
        let totalDistanceMeters: Double
        let route: [RouteCoordinate]

        @MainActor
        init(hike: Hike) {
            hikeID = hike.id
            // The name the hiker has seen, resolved here so nothing
            // downstream has to know a custom name exists — the same
            // resolution ``SharedHikeSummary`` promises.
            title = hike.displayTitle
            tintHex = hike.tintHex
            totalDistanceMeters = hike.distanceMeters
            route = hike.route
        }
    }

    /// The package, or `nil` for a hike with no line to send.
    ///
    /// A single-point route is a place rather than a trail, and every consumer
    /// on the watch wants a line: see ``WatchTrailPackage/isDrawable``. Sent
    /// anyway it would cost a transfer and draw nothing.
    @concurrent
    static func package(from input: Input) async -> WatchTrailPackage? {
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
                elevationMeters: coordinate.elevation
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
