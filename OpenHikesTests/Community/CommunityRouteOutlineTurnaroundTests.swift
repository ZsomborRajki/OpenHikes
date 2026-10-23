//
//  CommunityRouteOutlineTurnaroundTests.swift
//  OpenHikesTests
//
//  The geometry a perpendicular-distance simplifier cannot see: a turnaround
//  that lies on the line through a span's endpoints but outside the span.
//
//  An out-and-back whose finish is partway along the way out is exactly that.
//  Measured against the infinite line, the far end of the walk is zero metres
//  from the chord between start and finish, so Ramer–Douglas–Peucker dropped
//  it and the published outline stopped where the hiker turned for home
//  rather than where they turned around (#964). Each case here is above the
//  point budget, so the simplifier really runs, and each puts the turnaround
//  somewhere the old measure called "on the line".
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

/// Simplification keeps the reach of a trail that doubles back on itself.
@Suite("Community route outline turnarounds")
struct CommunityRouteOutlineTurnaroundTests {
    private static let latitude = 47.0
    /// About 7.6 m of longitude at this latitude: a dense recording.
    private static let step = 0.0001
    /// The encoding's five decimal places, about a metre.
    private static let precisionTolerance = 0.00002
    /// A parallel return two metres north of the way out: inside the
    /// simplification tolerance, so the two legs are one line to RDP, and the
    /// case a test of exactly collinear points would not cover.
    private static let nearlyCollinearOffset = 0.000018

    /// Points due east or west along one parallel, from `start` to `end` in
    /// `step`s, both ends included.
    private static func leg(
        from start: Int,
        to end: Int,
        latitudeOffset: Double = 0
    ) -> [RouteCoordinate] {
        let indices = start <= end ? Array(start...end) : Array((end...start).reversed())
        return indices.map { index in
            RouteCoordinate(latitude: latitude + latitudeOffset, longitude: Double(index) * step)
        }
    }

    /// Asserts that `outline` is the three points of an out-and-back: where
    /// it started, where it turned, and where it ended.
    private static func expectTurnaround(
        _ outline: [CLLocationCoordinate2D],
        start: CLLocationCoordinate2D,
        turn: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(outline.count == 3, "start, turnaround and finish", sourceLocation: sourceLocation)
        guard outline.count == 3 else { return }
        for (kept, expected) in zip(outline, [start, turn, end]) {
            #expect(
                kept.latitude.isApproximatelyEqual(to: expected.latitude, absoluteTolerance: precisionTolerance),
                sourceLocation: sourceLocation
            )
            #expect(
                kept.longitude.isApproximatelyEqual(to: expected.longitude, absoluteTolerance: precisionTolerance),
                sourceLocation: sourceLocation
            )
        }
    }

    private static func coordinate(_ index: Int, latitudeOffset: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude + latitudeOffset, longitude: Double(index) * step)
    }

    /// The reported case: east for 760 m, then back west to halfway. The far
    /// end lies beyond the span's *last* point.
    @Test("a turnaround beyond the finish survives thinning")
    func turnaroundBeyondTheFinish() {
        let route = Self.leg(from: 0, to: 100) + Self.leg(from: 99, to: 50)
        #expect(route.count > CommunityRouteOutline.maximumPoints)

        Self.expectTurnaround(
            CommunityRouteOutline.simplified(route),
            start: Self.coordinate(0),
            turn: Self.coordinate(100),
            end: Self.coordinate(50)
        )
    }

    /// The mirror image: a walk that sets off the wrong way first, then
    /// passes its start and finishes beyond it. The far end lies beyond the
    /// span's *first* point.
    @Test("a turnaround beyond the start survives thinning")
    func turnaroundBeyondTheStart() {
        let route = Self.leg(from: 50, to: 0) + Self.leg(from: 1, to: 100)
        #expect(route.count > CommunityRouteOutline.maximumPoints)

        Self.expectTurnaround(
            CommunityRouteOutline.simplified(route),
            start: Self.coordinate(50),
            turn: Self.coordinate(0),
            end: Self.coordinate(100)
        )
    }

    /// GPS never returns along exactly the same line. A return a couple of
    /// metres to one side is still inside the tolerance of the chord, and
    /// still must not take the turnaround with it.
    @Test("a nearly collinear return keeps its turnaround")
    func nearlyCollinearReturn() {
        let offset = Self.nearlyCollinearOffset
        let route = Self.leg(from: 0, to: 100) + Self.leg(from: 99, to: 50, latitudeOffset: offset)

        Self.expectTurnaround(
            CommunityRouteOutline.simplified(route),
            start: Self.coordinate(0),
            turn: Self.coordinate(100),
            end: Self.coordinate(50, latitudeOffset: offset)
        )
    }

    /// The same, set off the wrong way first.
    @Test("a nearly collinear overshoot of the start keeps its turnaround")
    func nearlyCollinearOvershootOfTheStart() {
        let offset = Self.nearlyCollinearOffset
        let route = Self.leg(from: 50, to: 0) + Self.leg(from: 1, to: 100, latitudeOffset: offset)

        Self.expectTurnaround(
            CommunityRouteOutline.simplified(route),
            start: Self.coordinate(50),
            turn: Self.coordinate(0),
            end: Self.coordinate(100, latitudeOffset: offset)
        )
    }

    /// The out-and-back that finishes where it started. Its first span is
    /// degenerate rather than collinear, so it was never the bug, but it is
    /// the commonest shape of all and the one a change here must not break.
    @Test("a closed out-and-back keeps its turnaround")
    func closedOutAndBack() {
        let route = Self.leg(from: 0, to: 100) + Self.leg(from: 99, to: 0)

        Self.expectTurnaround(
            CommunityRouteOutline.simplified(route),
            start: Self.coordinate(0),
            turn: Self.coordinate(100),
            end: Self.coordinate(0)
        )
    }

    /// What reaches the map: the encoded outline, read back, still goes as
    /// far as the walk did.
    @Test("the published outline reaches the turnaround")
    func theEncodedOutlineKeepsItsReach() throws {
        let route = Self.leg(from: 0, to: 100) + Self.leg(from: 99, to: 50)
        let encoded = try #require(CommunityRouteOutline.encoded(route))
        let farthest = try #require(CommunityRouteOutline.decoded(encoded).map(\.longitude).max())

        #expect(farthest.isApproximatelyEqual(to: 100 * Self.step, absoluteTolerance: Self.precisionTolerance))
    }
}
