//
//  WatchRouteTrackerTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch route tracker")
struct WatchRouteTrackerTests {
    @Test("A fix on the line reports how far along it is, and no distance off it")
    func onLineFixMeasuresAlong() throws {
        var tracker = WatchRouteTracker(Fixture.straightPackage(totalDistanceMeters: nil))
        // Hoisted out of `#require`, here and below: the macro passes its
        // operand into a non-escaping closure, where a `mutating` member
        // cannot be called.
        let match = tracker.advance(latitude: Fixture.latitude, longitude: Fixture.midpointLongitude)
        let halfway = try #require(match)
        #expect(halfway.isOnTrail)
        #expect(halfway.offRouteMeters < 1)
        #expect(abs(halfway.fractionComplete - 0.5) < 0.01)
    }

    @Test("Progress is reported on the trail's scale, not the decimated line's")
    func distanceIsRescaledToTheTrail() throws {
        // The line the watch was sent is short by construction: two points
        // spanning a stretch the phone measured as three times as long, which
        // is what decimating a winding route does to it.
        var asMeasured = WatchRouteTracker(Fixture.straightPackage(totalDistanceMeters: nil))
        let end = asMeasured.advance(latitude: Fixture.latitude, longitude: Fixture.endLongitude)
        let lineLength = try #require(end).distanceAlongRouteMeters

        var rescaled = WatchRouteTracker(
            Fixture.straightPackage(totalDistanceMeters: lineLength * 3)
        )
        let middle = rescaled.advance(latitude: Fixture.latitude, longitude: Fixture.midpointLongitude)
        let halfway = try #require(middle)
        #expect(abs(halfway.distanceAlongRouteMeters - lineLength * 1.5) < 1)
        #expect(abs(halfway.remainingMeters - lineLength * 1.5) < 1)
        #expect(rescaled.trailLengthMeters == lineLength * 3)
    }

    @Test("A fix off the line still says how far off, and says it is not on the trail")
    func offLineFixIsMeasuredAnyway() throws {
        var tracker = WatchRouteTracker(Fixture.straightPackage(totalDistanceMeters: nil))
        // Roughly 1.8 km north of a line that runs due east.
        let away = tracker.advance(
            latitude: Fixture.latitude + 0.016,
            longitude: Fixture.midpointLongitude
        )
        let strayed = try #require(away)
        #expect(!strayed.isOnTrail)
        #expect(strayed.offRouteMeters > WatchRouteTracker.matchThresholdMeters)
    }

    @Test("On an out-and-back the return leg is not mistaken for the outbound one")
    func courseTellsTheTwoLegsApart() throws {
        var tracker = WatchRouteTracker(Fixture.outAndBackPackage)
        // Out to the far end, heading due east.
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            _ = tracker.advance(
                latitude: Fixture.latitude,
                longitude: Fixture.startLongitude
                    + (Fixture.endLongitude - Fixture.startLongitude) * step,
                courseDegrees: Fixture.east
            )
        }
        let atTurn = tracker.advance(
            latitude: Fixture.latitude,
            longitude: Fixture.endLongitude,
            courseDegrees: Fixture.east
        )
        let turned = try #require(atTurn)
        // Back at the midpoint, now heading west. Geometrically this fix sits
        // on both legs and is *equidistant from the turn* along each, so
        // continuity alone cannot choose — the course is the whole of what
        // makes the return leg the answer.
        let back = tracker.advance(
            latitude: Fixture.latitude,
            longitude: Fixture.midpointLongitude,
            courseDegrees: Fixture.west
        )
        let returning = try #require(back)
        #expect(returning.isOnTrail)
        #expect(returning.fractionComplete > 0.7)
        #expect(returning.distanceAlongRouteMeters > turned.distanceAlongRouteMeters)
    }

    @Test("Without a course the same fix reads as the outbound leg")
    func withoutACourseTheFirstLegWins() throws {
        var tracker = WatchRouteTracker(Fixture.outAndBackPackage)
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            _ = tracker.advance(
                latitude: Fixture.latitude,
                longitude: Fixture.startLongitude
                    + (Fixture.endLongitude - Fixture.startLongitude) * step
            )
        }
        let back = tracker.advance(latitude: Fixture.latitude, longitude: Fixture.midpointLongitude)
        let ambiguous = try #require(back)
        // Not a defect being pinned as a feature: the two legs really are the
        // same ground, the anchor at the turn is equidistant from both, and a
        // receiver that will not say which way somebody is moving has not
        // given anything to break the tie with. The outbound reading is the
        // conservative one — it under-reports progress rather than claiming a
        // hiker is nearly home.
        #expect(abs(ambiguous.fractionComplete - 0.25) < 0.05)
    }

    @Test("Forgetting the position puts the next fix back on the whole trail")
    func forgettingReleasesTheAnchor() throws {
        var tracker = WatchRouteTracker(Fixture.outAndBackPackage)
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            _ = tracker.advance(
                latitude: Fixture.latitude,
                longitude: Fixture.startLongitude
                    + (Fixture.endLongitude - Fixture.startLongitude) * step,
                courseDegrees: Fixture.east
            )
        }
        tracker.forgetPosition()
        // A hiker who paused at the turn and resumed back at the midpoint,
        // walking east again: with the anchor released this is read as the
        // outbound leg, which is where somebody walking east on this trail is.
        let restarted = tracker.advance(
            latitude: Fixture.latitude,
            longitude: Fixture.midpointLongitude,
            courseDegrees: Fixture.east
        )
        let afresh = try #require(restarted)
        #expect(abs(afresh.fractionComplete - 0.25) < 0.05)
    }

    @Test("The trail's own height is interpolated along the segment, not the receiver's")
    func elevationComesFromTheTrail() throws {
        var tracker = WatchRouteTracker(Fixture.climbingPackage)
        let middle = tracker.advance(latitude: Fixture.latitude, longitude: Fixture.midpointLongitude)
        let halfway = try #require(middle)
        let elevation = try #require(halfway.trailElevationMeters)
        #expect(abs(elevation - 800) < 5)
    }

    @Test("The matched point follows distance along the line, not position in the array")
    func matchedPointIsNotTheIndexFraction() throws {
        var tracker = WatchRouteTracker(Fixture.unevenPackage)
        // Halfway along the one long segment, which is most of this route's
        // length and the last of its four segments. Reading the line by index
        // instead puts this seven-eighths of the way along it, back among the
        // clustered points at the start — which is what decimating a route
        // that was densely sampled at a switchback leaves behind.
        let longitude = (Fixture.clusterEndLongitude + Fixture.endLongitude) / 2
        let match = tracker.advance(latitude: Fixture.latitude, longitude: longitude)
        let halfway = try #require(match)
        #expect(halfway.isOnTrail)
        #expect(abs(halfway.trailCoordinate.longitude - longitude) < 0.0005)
        #expect(abs(halfway.trailCoordinate.latitude - Fixture.latitude) < 0.0005)
    }

    @Test("A segment across the antimeridian puts the dot on the segment")
    func matchedPointCrossesTheAntimeridian() throws {
        var tracker = WatchRouteTracker(Fixture.antimeridianPackage)
        let match = tracker.advance(latitude: Fixture.latitude, longitude: 180)
        let onTheLine = try #require(match)
        #expect(onTheLine.isOnTrail)
        // Interpolating the longitudes the long way round lands on the prime
        // meridian instead — half a world from a segment 2 km long.
        #expect(abs(abs(onTheLine.trailCoordinate.longitude) - 180) < 0.001)
    }

    @Test("A package with one point has no line, and says so rather than guessing")
    func onePointIsNotALine() {
        var tracker = WatchRouteTracker(
            WatchTrailPackage(
                hikeID: UUID(),
                title: "A place",
                tintHex: "#1B7F3B",
                totalDistanceMeters: 0,
                points: [WatchTrailPoint(latitude: Fixture.latitude, longitude: Fixture.startLongitude)]
            )
        )
        #expect(!tracker.isUsable)
        let nothing = tracker.advance(latitude: Fixture.latitude, longitude: Fixture.startLongitude)
        #expect(nothing == nil)
    }

    private enum Fixture {
        static let latitude = 47.55
        static let startLongitude = 12.90
        static let endLongitude = 12.94
        static var midpointLongitude: Double { (startLongitude + endLongitude) / 2 }
        /// Clockwise from north, the convention `CLLocation.course` reports in.
        static let east = 90.0
        static let west = 270.0

        /// A line running due east, so "off the trail" is purely a latitude
        /// offset and the arithmetic in the test is legible.
        static func straightPackage(totalDistanceMeters: Double?) -> WatchTrailPackage {
            WatchTrailPackage(
                hikeID: UUID(),
                title: "Straight",
                tintHex: "#1B7F3B",
                // 0 means "as measured": the tracker's scale falls back to 1,
                // so the reported distance is the line's own.
                totalDistanceMeters: totalDistanceMeters ?? 0,
                points: [
                    WatchTrailPoint(latitude: latitude, longitude: startLongitude),
                    WatchTrailPoint(latitude: latitude, longitude: endLongitude),
                ]
            )
        }

        /// Out and back along the same line, which is the shape a plain
        /// nearest-point scan cannot read.
        static var outAndBackPackage: WatchTrailPackage {
            WatchTrailPackage(
                hikeID: UUID(),
                title: "Out and back",
                tintHex: "#1B7F3B",
                totalDistanceMeters: 0,
                points: [
                    WatchTrailPoint(latitude: latitude, longitude: startLongitude),
                    WatchTrailPoint(latitude: latitude, longitude: endLongitude),
                    WatchTrailPoint(latitude: latitude, longitude: startLongitude),
                ]
            )
        }

        static var climbingPackage: WatchTrailPackage {
            WatchTrailPackage(
                hikeID: UUID(),
                title: "Climb",
                tintHex: "#1B7F3B",
                totalDistanceMeters: 0,
                points: [
                    WatchTrailPoint(latitude: latitude, longitude: startLongitude, elevationMeters: 600),
                    WatchTrailPoint(latitude: latitude, longitude: endLongitude, elevationMeters: 1000),
                ]
            )
        }
        /// The far end of a run of points a few metres apart, before the one
        /// long segment that is the rest of the route.
        static let clusterEndLongitude = 12.903

        /// Points clustered at one end and sparse at the other, which is what
        /// decimation leaves of a route sampled densely at a switchback and
        /// thinly along the ridge after it. Index position and distance along
        /// the line say different things here, which is the whole point.
        static var unevenPackage: WatchTrailPackage {
            WatchTrailPackage(
                hikeID: UUID(),
                title: "Uneven",
                tintHex: "#1B7F3B",
                totalDistanceMeters: 0,
                points: [
                    WatchTrailPoint(latitude: latitude, longitude: startLongitude),
                    WatchTrailPoint(latitude: latitude, longitude: 12.901),
                    WatchTrailPoint(latitude: latitude, longitude: 12.902),
                    WatchTrailPoint(latitude: latitude, longitude: clusterEndLongitude),
                    WatchTrailPoint(latitude: latitude, longitude: endLongitude),
                ]
            )
        }

        /// A short segment straddling ±180°, where subtracting the longitudes
        /// says the two ends are most of a world apart.
        static var antimeridianPackage: WatchTrailPackage {
            WatchTrailPackage(
                hikeID: UUID(),
                title: "Dateline",
                tintHex: "#1B7F3B",
                totalDistanceMeters: 0,
                points: [
                    WatchTrailPoint(latitude: latitude, longitude: 179.99),
                    WatchTrailPoint(latitude: latitude, longitude: -179.99),
                ]
            )
        }
    }
}
