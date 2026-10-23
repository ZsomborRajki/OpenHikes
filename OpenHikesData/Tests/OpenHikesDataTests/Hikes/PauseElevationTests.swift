//
//  PauseElevationTests.swift
//  OpenHikesTests
//
//  A pause is the one gap in a route whose rise was not walked: the receiver
//  may be somewhere else when it resumes, and the height difference across the
//  gap is a lift, a drive or a drifting barometer rather than ground covered.
//  The watch ends its elevation run at a pause; the phone's figures used to
//  read straight across it, so a recording paused at 110 m and resumed at
//  1,110 m reported a 1,020 m climb for what was 20 m of walking (#910).
//
//  What these pin is the climb only. The paused leg has no length on the
//  distance axis (#962, pinned in `RouteProfilePausedTransferTests`), so the
//  fix before a pause and the fix after it stand at one distance, and the
//  height a resume reports is still an observation — it is the new run's
//  start, and it belongs in the hike's extremes.
//

import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("Climb across a pause")
struct PauseElevationTests {
    /// A walk north in steps of about 111 m, one height per point, with the
    /// points named in `resumed` arriving after a pause.
    private static func route(
        _ elevations: [Double?],
        resumingAt resumed: Set<Int> = []
    ) -> [RouteCoordinate] {
        elevations.enumerated().map { index, elevation in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.001,
                longitude: 12.86,
                elevation: elevation,
                boundary: resumed.contains(index) ? .paused : nil
            )
        }
    }

    private static func statistics(of route: [RouteCoordinate]) -> HikeRouteStatistics {
        HikeRouteStatistics(
            distanceMeters: RouteProfile(route: route).totalDistanceMeters,
            route: route
        )
    }

    // MARK: - The hike's own statistics

    @Test("the climb stops at a pause instead of bridging it")
    func statisticsDoNotBridgeAPause() {
        let statistics = Self.statistics(of: Self.route([100, 110, 1110, 1120], resumingAt: [2]))

        #expect(statistics.elevationGain?.value == 20)
        #expect(statistics.elevationLoss?.value == 0)
    }

    @Test("the descent stops at a pause instead of bridging it")
    func descentIsNotBridgedEither() {
        let statistics = Self.statistics(of: Self.route([1110, 1100, 100, 90], resumingAt: [2]))

        #expect(statistics.elevationLoss?.value == 20)
        #expect(statistics.elevationGain?.value == 0)
    }

    @Test("the height a resume reports is still an observation")
    func resumedHeightStillCountsTowardTheExtremes() {
        let statistics = Self.statistics(of: Self.route([100, 110, 1110, 1120], resumingAt: [2]))

        #expect(statistics.minElevation?.value == 100)
        #expect(statistics.maxElevation?.value == 1120)
    }

    @Test("the same heights with no pause are one climb")
    func withoutAPauseTheJumpIsClimbed() {
        let statistics = Self.statistics(of: Self.route([100, 110, 1110, 1120]))

        #expect(statistics.elevationGain?.value == 1020)
    }

    @Test("a resume with no height still ends the run")
    func aResumedPointWithoutAHeightEndsTheRun() {
        let statistics = Self.statistics(of: Self.route([100, 110, nil, 1120, 1130], resumingAt: [2]))

        #expect(statistics.elevationGain?.value == 20)
    }

    @Test("a point with no height before the pause changes nothing")
    func aHeightlessPointBeforeThePauseChangesNothing() {
        let statistics = Self.statistics(of: Self.route([100, 110, nil, 1120, 1130], resumingAt: [3]))

        #expect(statistics.elevationGain?.value == 20)
    }

    @Test("a boundary on the first point is no boundary")
    func aBoundaryOnTheFirstPointIsHarmless() {
        let statistics = Self.statistics(of: Self.route([100, 110, 120], resumingAt: [0]))

        #expect(statistics.elevationGain?.value == 20)
    }

    // MARK: - The route profile

    @Test("the profile's own totals stop at a pause")
    func profileTotalsDoNotBridgeAPause() {
        let profile = RouteProfile(route: Self.route([100, 110, 1110, 1120], resumingAt: [2]))

        #expect(profile.elevation.gainMeters == 20)
        #expect(profile.elevation.lowMeters == 100)
        #expect(profile.elevation.highMeters == 1120)
    }

    @Test("a stretch of the route climbs only what is walked inside it")
    func stretchClimbStopsAtAPause() throws {
        let profile = RouteProfile(route: Self.route([100, 110, 1110, 1120], resumingAt: [2]))
        let pause = try #require(profile.pauseDistances.first)
        let total = profile.totalDistanceMeters

        let whole = try #require(profile.climb(from: 0, to: total))
        #expect(whole.gainMeters == 20)
        #expect(whole.lossMeters == 0)

        let reversed = try #require(profile.climb(from: total, to: 0))
        #expect(reversed.gainMeters == 20)

        let upToThePause = try #require(profile.climb(from: 0, to: pause))
        #expect(upToThePause.gainMeters == 10)

        let after = try #require(profile.climb(from: pause, to: total))
        #expect(after.gainMeters == 10)
    }

    @Test("a stretch holding only the fix before a pause and the one after it climbs nothing")
    func stretchAcrossOnlyTheGapClimbsNothing() throws {
        let profile = RouteProfile(route: Self.route([100, 110, 1110, 1120], resumingAt: [2]))

        let gap = try #require(profile.climb(from: profile.distances[1], to: profile.distances[2]))

        #expect(gap.gainMeters == 0)
        #expect(gap.lossMeters == 0)
    }

    @Test("a walk's covered stretches add up without the pause between them")
    func coveredStretchesDoNotBridgeAPause() throws {
        let profile = RouteProfile(route: Self.route([100, 110, 1110, 1120], resumingAt: [2]))
        let pause = try #require(profile.pauseDistances.first)

        let covered = try #require(profile.climb(over: [0...pause, pause...profile.totalDistanceMeters]))
        #expect(covered.gainMeters == 20)

        let oneStretch = try #require(profile.climb(over: [0...profile.totalDistanceMeters]))
        #expect(oneStretch.gainMeters == 20)
    }

    /// The chart's series is thinned to its drawing budget, and the bucket
    /// holding the resume keeps its lowest and highest points, neither of
    /// which need be the resumed one. ``RouteProfile/climb(from:to:)`` reads
    /// every height instead (#963), so the pause stays closed and the stretch
    /// is the route's own figure to the metre.
    @Test("a pause stays closed when downsampling dropped the sample that resumed")
    func downsamplingKeepsThePauseClosed() throws {
        let resumedAt = 600
        let heights: [Double?] = (0..<1200).map { $0 < resumedAt ? Double($0) : Double($0) + 5000 }
        let route = Self.route(heights, resumingAt: [resumedAt])
        let profile = RouteProfile(route: route)
        let pause = try #require(profile.pauseDistances.first)

        try #require(route.count > RouteProfile.plottedSampleBudget)
        try #require(!profile.samples.contains { $0.distanceMeters == pause && $0.elevation >= 5000 })

        #expect(profile.elevation.gainMeters == 1198)

        let climb = try #require(profile.climb(from: 0, to: profile.totalDistanceMeters))
        #expect(climb.gainMeters.isApproximatelyEqual(to: 1198, absoluteTolerance: 0.001))
    }
}
