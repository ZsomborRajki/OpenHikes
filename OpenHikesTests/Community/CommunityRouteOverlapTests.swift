//
//  CommunityRouteOverlapTests.swift
//  OpenHikesTests
//
//  Whether two routes are the same walk.
//
//  What the community list has to avoid is two entries for one trail, and no
//  two recordings of a path are ever identical — so what is measured is
//  coverage, and these fix the three things a coverage measure can get wrong:
//  the direction it is asymmetric in, whether it survives a route recorded at
//  a different point density, and whether it says no quickly for two walks
//  that have nothing to do with each other.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community route overlap")
struct CommunityRouteOverlapTests {
    /// A straight line north from a fixed point, `count` points spread over
    /// `meters`. Built from a metre offset rather than from typed-out
    /// coordinates so that a test can say what it means — "the same line,
    /// thirty metres east" — and so the distances are the ones being asserted
    /// rather than whatever six decimal places happened to produce.
    private static func line(
        meters: Double,
        count: Int,
        eastOffset: Double = 0,
        startingAt startMeters: Double = 0
    ) -> [RouteCoordinate] {
        let baseLatitude = 47.6
        let baseLongitude = 12.87
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(baseLatitude * .pi / 180)
        return (0..<count).map { step in
            let along = startMeters + meters * Double(step) / Double(max(count - 1, 1))
            return RouteCoordinate(
                latitude: baseLatitude + along / metersPerDegreeLatitude,
                longitude: baseLongitude + eastOffset / metersPerDegreeLongitude
            )
        }
    }

    @Test("a route is fully covered by itself")
    func identical() {
        let route = Self.line(meters: 3000, count: 120)
        #expect(CommunityRouteOverlap.coverage(of: route, by: route) == 1)
        #expect(CommunityRouteOverlap.isDuplicate(route, of: route))
    }

    /// The case the tolerance exists for: two honest recordings of one path
    /// differ by more than a receiver's error — opposite sides of a track, a
    /// switchback cut on one pass and not the other.
    @Test("the same path walked a little to one side is still the same path")
    func withinTolerance() {
        let first = Self.line(meters: 3000, count: 120)
        let second = Self.line(meters: 3000, count: 120, eastOffset: 20)
        #expect(CommunityRouteOverlap.isDuplicate(first, of: second))
    }

    /// And the other side of it. A parallel trail on the far side of a valley
    /// is a different walk, however similar its shape.
    @Test("a parallel path far enough away is a different walk")
    func beyondTolerance() {
        let first = Self.line(meters: 3000, count: 120)
        let second = Self.line(meters: 3000, count: 120, eastOffset: 300)
        #expect(CommunityRouteOverlap.coverage(of: first, by: second) == 0)
        #expect(!CommunityRouteOverlap.isDuplicate(first, of: second))
    }

    /// **The asymmetry, which is the whole design.**
    ///
    /// A short walk along the first stretch of a long published one adds
    /// nothing to the list and is refused. The long one is not a duplicate of
    /// the short one — it is mostly ground the short one never touches — and
    /// refusing it would be the rule firing backwards.
    @Test("a short walk inside a long one is a duplicate, and not the other way round")
    func asymmetric() {
        let long = Self.line(meters: 10_000, count: 400)
        let short = Self.line(meters: 2000, count: 80)

        #expect(CommunityRouteOverlap.isDuplicate(short, of: long))
        #expect(!CommunityRouteOverlap.isDuplicate(long, of: short))
    }

    /// Two walks from one car park share their approach and are different
    /// hikes. This is the case the fraction is set where it is to allow.
    @Test("sharing an approach is not sharing a walk")
    func sharedApproach() {
        let first = Self.line(meters: 6000, count: 240)
        // The same first kilometre, then away to the east for five more.
        let shared = Self.line(meters: 1000, count: 40)
        let away = Self.line(meters: 5000, count: 200, eastOffset: 2000, startingAt: 1000)
        let second = shared + away

        #expect(!CommunityRouteOverlap.isDuplicate(second, of: first))
    }

    /// **The densifying, which nothing else would catch.**
    ///
    /// The test is point-to-point, so a route recorded with a point every
    /// 250 m would report almost no overlap with a walk straight down the
    /// middle of it — the points are further apart than the tolerance is wide.
    /// Interpolating the indexed route is what makes a GPX from another
    /// provider comparable with a dense recording of the same trail.
    @Test("a sparsely recorded route still covers a dense one")
    func sparseAgainstDense() {
        let sparse = Self.line(meters: 5000, count: 21)
        let dense = Self.line(meters: 5000, count: 500)

        #expect(CommunityRouteOverlap.isDuplicate(dense, of: sparse))
    }

    @Test("an empty route covers nothing and is covered by nothing")
    func empties() {
        let route = Self.line(meters: 3000, count: 120)
        #expect(CommunityRouteOverlap.coverage(of: [], by: route) == 0)
        #expect(CommunityRouteOverlap.coverage(of: route, by: []) == 0)
        #expect(CommunityRouteOverlap.coverage(of: [], by: []) == 0)
    }

    /// The bounding-box rejection, asserted through the answer rather than by
    /// reaching into it: two walks in different countries share no ground.
    @Test("walks in different places do not overlap")
    func farApart() {
        let alps = Self.line(meters: 3000, count: 120)
        let elsewhere = [
            RouteCoordinate(latitude: -33.8, longitude: 151.2),
            RouteCoordinate(latitude: -33.81, longitude: 151.21),
        ]
        #expect(CommunityRouteOverlap.coverage(of: alps, by: elsewhere) == 0)
        #expect(CommunityRouteOverlap.coverage(of: elsewhere, by: alps) == 0)
    }

    /// A single point is a hike with no length, refused long before this by
    /// the distance floor — but the geometry must not divide by zero on the
    /// way past.
    @Test("a one-point route is handled rather than crashed on")
    func singlePoint() {
        let route = Self.line(meters: 3000, count: 120)
        let point = [route[0]]
        #expect(CommunityRouteOverlap.coverage(of: point, by: route) == 1)
        #expect(CommunityRouteOverlap.coverage(of: route, by: point) < 1)
    }

    /// The sample is spread through the walk rather than taken off the front,
    /// so a long route's second half cannot be ignored. Asserted through a
    /// pair where only the first half matches: sampling the front alone would
    /// call this a duplicate.
    @Test("a long route is sampled across its whole length")
    func samplingIsEven() {
        let published = Self.line(meters: 4000, count: 160)
        let firstHalfThenAway = Self.line(meters: 4000, count: 2000)
            + Self.line(meters: 4000, count: 2000, eastOffset: 5000, startingAt: 4000)

        #expect(firstHalfThenAway.count > CommunityRouteOverlap.sampleLimit)
        #expect(!CommunityRouteOverlap.isDuplicate(firstHalfThenAway, of: published))
    }
}
