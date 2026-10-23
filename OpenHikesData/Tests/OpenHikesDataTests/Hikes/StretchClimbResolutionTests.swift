//
//  StretchClimbResolutionTests.swift
//  OpenHikesTests
//
//  What a stretch of a route climbs is counted over every height the route
//  has, not over the chart's thinned series. The chart keeps each bucket's
//  lowest and highest point, which is the right picture and the wrong sum:
//  every rise between two plotted points is gone. On a rolling route past the
//  plot budget the walk's estimates and share card read a fraction of the
//  climb the hike's own statistics report (#963).
//

import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("Stretch climb at full resolution")
struct StretchClimbResolutionTests {
    /// Each step is a real rise or fall, well past the deadband.
    private static let low = 100.0
    private static let high = 110.0

    /// A walk east at about 0.76 m a step whose heights alternate between
    /// ``low`` and ``high``, starting low, with the points named in `resumed`
    /// arriving after a pause `lift` metres higher than the walking before it.
    private static func rollingRoute(
        count: Int,
        resumingAt resumed: [Int] = [],
        lift: Double = 1000
    ) -> [RouteCoordinate] {
        (0..<count).map { index in
            let lifted = Double(resumed.count { $0 <= index }) * lift
            return RouteCoordinate(
                latitude: 47,
                longitude: 11 + Double(index) * 0.00001,
                elevation: (index.isMultiple(of: 2) ? low : high) + lifted,
                boundary: resumed.contains(index) ? .paused : nil
            )
        }
    }

    @Test("the whole of a long rolling route climbs what its totals say")
    func wholeRouteAgreesWithTheTotals() throws {
        let profile = RouteProfile(route: Self.rollingRoute(count: 10_000))
        try #require(profile.samples.count <= RouteProfile.plottedSampleBudget)

        let gain = try #require(profile.elevation.gainMeters)
        let loss = try #require(profile.elevation.lossMeters)
        let climb = try #require(profile.climb(from: 0, to: profile.totalDistanceMeters))

        #expect(gain.isApproximatelyEqual(to: 50_000, absoluteTolerance: 0.001))
        #expect(climb.gainMeters.isApproximatelyEqual(to: gain, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: loss, absoluteTolerance: 0.001))
    }

    @Test("the whole of a long route with pauses climbs what its totals say, and nothing across them")
    func wholeRouteWithPausesAgreesWithTheTotals() throws {
        let profile = RouteProfile(route: Self.rollingRoute(count: 6001, resumingAt: [2000, 4000]))
        try #require(profile.pauseDistances.count == 2)

        let gain = try #require(profile.elevation.gainMeters)
        let loss = try #require(profile.elevation.lossMeters)
        let climb = try #require(profile.climb(from: 0, to: profile.totalDistanceMeters))

        // 3,000 rises of 10 m; each resume lands low, so the lift is the
        // only rise into it. The two lifts of 1,000 m were not walked.
        #expect(gain.isApproximatelyEqual(to: 30_000, absoluteTolerance: 0.001))
        #expect(climb.gainMeters.isApproximatelyEqual(to: gain, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: loss, absoluteTolerance: 0.001))
    }

    /// A stretch a few steps long sits between two plotted points, so the
    /// thinned series held at most one height inside it — no climb at all.
    @Test("a short stretch keeps the rises that fall between plotted points")
    func shortStretchKeepsItsRises() throws {
        let profile = RouteProfile(route: Self.rollingRoute(count: 10_000))
        let start = profile.distances[5001]
        let end = profile.distances[5005]
        try #require(profile.samples.count { (start...end).contains($0.distanceMeters) } < 2)

        // 110, 100, 110, 100, 110: two rises and two falls.
        let climb = try #require(profile.climb(from: start, to: end))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 20, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 20, absoluteTolerance: 0.001))
    }

    @Test("a stretch inside a long route climbs every rise in it")
    func longStretchKeepsItsRises() throws {
        let profile = RouteProfile(route: Self.rollingRoute(count: 10_000))

        // From index 1000 (low) to 3000 (low): 1,000 rises and 1,000 falls.
        let climb = try #require(profile.climb(from: profile.distances[1000], to: profile.distances[3000]))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 10_000, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 10_000, absoluteTolerance: 0.001))
    }

    @Test("a stretch across a pause leaves the lift out at full resolution too")
    func partialStretchAcrossAPause() throws {
        let profile = RouteProfile(route: Self.rollingRoute(count: 6001, resumingAt: [2000]))

        // 1990 (low) … 1999 (high), pause, 2000 (low + lift) … 2010 (low + lift):
        // five rises and four falls before it, five of each after.
        let climb = try #require(profile.climb(from: profile.distances[1990], to: profile.distances[2010]))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 100, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 90, absoluteTolerance: 0.001))
    }

    /// The trade the file header of `RouteProfile+Climb.swift` makes at a
    /// stretch's start: it carries on the route's run rather than judging its
    /// first few metres afresh.
    @Test("a stretch that starts just below a peak is credited with the route's turn from it")
    func stretchStartTakesTheRoutesVerdict() throws {
        let heights = [100.0, 200, 198, 196]
        let profile = RouteProfile(route: heights.enumerated().map { index, height in
            RouteCoordinate(latitude: 47, longitude: 11 + Double(index) * 0.001, elevation: height)
        })

        // 198 to 196 is 2 m, inside the deadband, so a count begun at 198
        // would read nothing. The route turned 4 m down from its 200 m peak,
        // and this stretch is where it confirmed the turn.
        let climb = try #require(profile.climb(from: profile.distances[2], to: profile.distances[3]))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 4, absoluteTolerance: 0.001))
    }

    /// Every cut lands on a height, which is what the file header promises
    /// adds up. The one at 2,000 is a join: the paused leg has no length, so
    /// the fix before the pause stands at the same distance.
    @Test("a route's stretches add up to the whole")
    func stretchesAddUpToTheWhole() throws {
        let profile = RouteProfile(route: Self.rollingRoute(count: 6001, resumingAt: [2000, 4000]))
        try #require(profile.distances[1999] == profile.distances[2000])
        let total = profile.totalDistanceMeters
        let cuts = [0, profile.distances[777], profile.distances[2000], profile.distances[3500], total]
        let stretches = zip(cuts, cuts.dropFirst()).map { $0...$1 }

        let summed = try #require(profile.climb(over: stretches))
        let whole = try #require(profile.climb(from: 0, to: total))

        #expect(summed.gainMeters.isApproximatelyEqual(to: whole.gainMeters, absoluteTolerance: 0.001))
        #expect(summed.lossMeters.isApproximatelyEqual(to: whole.lossMeters, absoluteTolerance: 0.001))
    }
}
