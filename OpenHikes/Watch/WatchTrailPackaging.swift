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
//  What they must agree on is the trail's *length* and its *climb*, and they
//  do: both read `Hike.distanceMeters` rather than measuring the line they
//  send, and both count the climb over the whole route with
//  `ElevationAccumulator` — the snapshot through `RouteProfile`, this directly
//  — ending its run at a pause, as the watch's own recorder does.
//
//  ## Off the main actor
//
//  A route is the largest thing this app holds in memory and the longest thing
//  it serializes; this walks one and encodes a few hundred points of it, and a
//  watch asking for a trail must not cost the hiker a frame on the phone they
//  are holding. Reading it is off the main actor too: the hike is fetched into
//  a context made and dropped inside one call, the way the launch sweep reads
//  a pinned trail, and only values cross — ``HikeRouteInput``, the same one
//  the widget's snapshot starts from.
//

import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared
import SwiftData

nonisolated enum WatchTrailPackaging {
    /// The package that answers `request`, or `nil` when there is nothing to
    /// send: a hike deleted since the watch's list was published, a hike with
    /// no line, or a trail the watch already holds exactly this copy of.
    ///
    /// The hike is read in a context of its own off the main actor, by the
    /// read the launch sweep makes of each pinned trail. `HikeRouteInput`
    /// reads `route`, which is external storage decoded whole, and reading it
    /// inside `MainActor.run` cost the phone in the hiker's hand a stall for
    /// every trail the watch asked for (#1025).
    ///
    /// Stamped as the read starts, on the caller's executor — the main actor,
    /// where an edit is saved — so the line a package carries is never older
    /// than its stamp says. See ``package(from:readAt:requestID:)`` for what
    /// the stamp orders.
    ///
    /// - Parameter graph: the trail graph the package's junctions are read
    ///   from, or `nil` to send none.
    /// - Parameter fetch: the store's fetch of one hike, a seam so a suite can
    ///   see which thread it ran on.
    static func answer(
        to request: WatchTrailRequest,
        from container: ModelContainer,
        graph: (any TrailGraphProviding)? = nil,
        fetch: @Sendable (ModelContext, UUID) throws -> Hike? = SharedHikeCatalogPublisher.fetchHike
    ) async -> WatchTrailPackage? {
        let readAt = Date.now
        guard let input = await SharedHikeCatalogPublisher.routeInput(
            for: request.hikeID,
            in: container,
            fetch: fetch
        ).input,
            let package = await package(from: input, readAt: readAt, requestID: request.id, graph: graph)
        else { return nil }
        // The watch already holds exactly this, and asked to find out whether
        // the route had been edited since. It had not, so there is nothing to
        // send: the copy it has stays the one it draws.
        return request.needs(package) ? package : nil
    }

    /// The package, or `nil` for a hike with no line to send.
    ///
    /// A single-point route is a place rather than a trail, and every consumer
    /// on the watch wants a line: see ``WatchTrailPackage/isDrawable``. Sent
    /// anyway it would cost a transfer and draw nothing.
    ///
    /// `readAt` is when `input` was read off the hike, and becomes the
    /// package's ``WatchTrailPackage/sentAt``. Stamped there rather than when
    /// this finishes, because two requests either side of an edit are
    /// packaged concurrently and can finish in either order; the watch orders
    /// two copies of one trail by it — see `WatchTrailSelection`.
    ///
    /// The junctions are read from `graph` along the whole route and put
    /// where the watch's tracker will read a fix at each — see
    /// ``WatchTrailPackage/junctions``. A trail graph that has to be
    /// downloaded first holds the package until it arrives: a watch with the
    /// trail and no junctions would tap at no fork for the whole walk.
    @concurrent
    static func package(
        from input: HikeRouteInput,
        readAt: Date = .now,
        requestID: UUID = UUID(),
        graph: (any TrailGraphProviding)? = nil
    ) async -> WatchTrailPackage? {
        assertOffMainThread("Packaging a route for the watch must stay off the main thread")
        guard input.route.count > 1 else { return nil }
        let kept = keptPoints(of: input.route)
        let points = kept.routeIndices.map { index in
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
        let climb = Self.climb(of: input.route)
        var package = WatchTrailPackage(
            hikeID: input.hikeID,
            title: input.title,
            tintHex: input.tintHex,
            totalDistanceMeters: input.totalDistanceMeters,
            points: points,
            pauseIndices: kept.pauseIndices,
            elevationGainMeters: climb.gainMeters,
            elevationLossMeters: climb.lossMeters,
            sentAt: readAt,
            requestID: requestID
        )
        let junctions = await Self.junctions(
            of: input,
            keptIndices: kept.routeIndices,
            readBy: WatchRouteTracker(package),
            graph: graph
        )
        package.junctions = Array(junctions.prefix(WatchTrailPackage.junctionBudget))
        return package
    }

    /// Which of the route's points cross, and which of them a pause arrives
    /// at — ``WatchTrailPackage/keptPoints(of:gapMeters:pointBudget:pauseBudget:)``,
    /// handed the route cut at its pauses and the length of each break.
    ///
    /// Taken as *indices*, so a kept point's height is the height of that
    /// point rather than of one nearby — see
    /// ``decimatedIndices(count:maxPoints:)``. Both ends of every pause that
    /// crosses are kept: the watch gives a paused leg no length and never
    /// matches onto it (``WatchTrailPackage/pauseIndices``), which it can only
    /// do for a leg that is the pause alone. A GPX file can hold more pauses
    /// than the budget has points, so past ``WatchTrailPackage/pauseBudget``
    /// the shortest breaks are folded into the line (#1023).
    static func keptPoints(of route: [RouteCoordinate]) -> WatchTrailPackage.KeptPoints {
        WatchTrailPackage.keptPoints(of: route.trailRuns) { leg in
            RouteGeometry.distanceMeters(from: route[leg].clCoordinate, to: route[leg + 1].clCoordinate)
        }
    }

    /// The route's junctions, found along the whole route and placed on the
    /// line the watch is sent, where `tracker` reads them as it reads a fix.
    ///
    /// Placed leg by leg rather than scaled as a whole. Dropping points takes
    /// more length out of a winding stretch than a straight one, so after a
    /// run of switchbacks a junction stands further along the sent line, in
    /// proportion, than along the route: on a long trail by hundreds of
    /// metres, which would have the watch tap at the wrong place. Each is
    /// read as a fix at it would be, matched to the kept leg that spans it
    /// along the route. That leg, rather than the nearest one, because a
    /// trail that comes back past its own junction has two.
    ///
    /// - Parameter keptIndices: the route index of each point the watch is
    ///   sent, in order.
    private static func junctions(
        of input: HikeRouteInput,
        keptIndices: [Int],
        readBy tracker: WatchRouteTracker,
        graph: (any TrailGraphProviding)?
    ) async -> [TrailJunction] {
        guard graph != nil, keptIndices.count > 1 else { return [] }
        let profile = RouteProfile(route: input.route)
        let distances = profile.distances
        let found = await TrailJunctionFinder.junctions(along: profile, from: graph)
        var leg = 0
        return found.compactMap { junction in
            // Both are in order along the line, so the leg only moves on.
            while leg < keptIndices.count - 2, distances[keptIndices[leg + 1]] < junction.distanceMeters {
                leg += 1
            }
            guard let coordinate = profile.coordinate(atDistance: junction.distanceMeters),
                  let along = tracker.trailDistance(
                      latitude: coordinate.latitude,
                      longitude: coordinate.longitude,
                      onLeg: leg
                  )
            else { return nil }
            return TrailJunction(
                distanceMeters: along,
                towardsEnd: junction.towardsEnd,
                towardsStart: junction.towardsStart
            )
        }
    }

    /// Climb and descent over the *whole* route.
    ///
    /// Summed run by run rather than taken as high minus low, which a rolling
    /// trail understates by every descent it makes on the way up — the
    /// argument ``SharedTrailSnapshot/elevationGainMeters`` already makes —
    /// and through ``ElevationAccumulator``'s deadband, like every other climb
    /// in the app. This used to sum every step instead, which counts each
    /// metre a GPX altitude wobbles as climb — so the watch's trail screen
    /// stated a figure the phone's never would for the same hike. Measured
    /// before decimation, because dropping points removes the rises they
    /// spanned — and a pause ends the run, so a recording that was carried up
    /// a hill while paused does not send the watch a climb nobody walked.
    private static func climb(of route: [RouteCoordinate]) -> RouteElevationSummary {
        var accumulator = ElevationAccumulator()
        for point in route { accumulator.record(point) }
        return RouteElevationSummary(accumulator)
    }
}
