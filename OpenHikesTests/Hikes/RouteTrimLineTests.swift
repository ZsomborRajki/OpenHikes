//
//  RouteTrimLineTests.swift
//  OpenHikesTests
//
//  The line *Edit Route* measures once: where a cut stands on the map, how
//  far along the drawn polyline that is, the clock there, and what it found
//  at the line's ends.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@MainActor
@Suite("Route trim line")
struct RouteTrimLineTests {
    private enum Line {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
    }

    private static func point(
        _ step: Double,
        at seconds: TimeInterval,
        resumed: Bool = false,
        motion: RouteMotion? = nil
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: Line.latitude + step * Line.spacing,
            longitude: Line.longitude,
            timestamp: Line.start.addingTimeInterval(seconds),
            motion: motion,
            boundary: resumed ? .paused : nil
        )
    }

    /// Four steps north, a minute each.
    private static let straight = (0...4).map { point(Double($0), at: Double($0) * Line.secondsPerPoint) }
    /// Two steps, a pause an hour long that moved the hiker six steps on, two
    /// more steps.
    private static let paused = [
        point(0, at: 0),
        point(1, at: 60),
        point(2, at: 120),
        point(8, at: 3720, resumed: true),
        point(9, at: 3780),
        point(10, at: 3840),
    ]

    @Test("a cut between two points stands between them, on the map and on the clock")
    func aCutBetweenPoints() async throws {
        let line = try await RouteTrimLine.measuring(Self.straight)
        let meters = line.totalMeters * 0.375

        let spot = line.endSpot(at: meters)

        #expect(spot.coordinate.latitude.isApproximatelyEqual(
            to: Line.latitude + 1.5 * Line.spacing,
            absoluteTolerance: 1e-7
        ))
        #expect(spot.drawnFraction.isApproximatelyEqual(to: 0.375, absoluteTolerance: 0.001))
        #expect(line.timestamp(of: .end, at: meters) == Line.start.addingTimeInterval(90))
        #expect(line.startSpot(at: meters).drawnFraction == spot.drawnFraction)
    }

    @Test("the ends of the line are its first and last points")
    func theEnds() async throws {
        let line = try await RouteTrimLine.measuring(Self.straight)

        #expect(line.startSpot(at: 0).drawnFraction == 0)
        #expect(line.endSpot(at: line.totalMeters).drawnFraction == 1)
        #expect(line.endSpot(at: line.totalMeters).coordinate.latitude == Self.straight[4].latitude)
    }

    @Test("at a pause, an end stands before it and a start after it")
    func cutsAtAPause() async throws {
        let line = try await RouteTrimLine.measuring(Self.paused)
        let atThePause = line.distances[2]
        #expect(line.distances[3] == atThePause, "a paused leg has no length")

        let end = line.endSpot(at: atThePause)
        let start = line.startSpot(at: atThePause)

        #expect(end.coordinate.latitude == Self.paused[2].latitude)
        #expect(start.coordinate.latitude == Self.paused[3].latitude)
        // The drawn polyline runs across the pause, so the two are far apart
        // on it: two steps of ten, and eight.
        #expect(end.drawnFraction.isApproximatelyEqual(to: 0.2, absoluteTolerance: 0.001))
        #expect(start.drawnFraction.isApproximatelyEqual(to: 0.8, absoluteTolerance: 0.001))
        #expect(line.timestamp(of: .end, at: atThePause) == Self.paused[2].timestamp)
        #expect(line.timestamp(of: .start, at: atThePause) == Self.paused[3].timestamp)
    }

    @Test("a handle is never slid onto a paused leg")
    func aPausedLegIsNoPlaceForAHandle() async throws {
        let line = try await RouteTrimLine.measuring(Self.paused)
        // Halfway across the ground the pause skipped.
        let finger = CLLocationCoordinate2D(latitude: Line.latitude + 5 * Line.spacing, longitude: Line.longitude)

        let meters = try #require(line.distance(nearest: finger, around: line.distances[2]))

        // One of the two fixes either side of the pause, which share its
        // distance: nothing between them is a place on the line.
        #expect(meters.isApproximatelyEqual(to: line.distances[2], absoluteTolerance: 0.01))
    }

    @Test("a line that ends with a drive says so")
    func aDriveAtTheEnd() async throws {
        // A kilometre and a half on foot, then six at a car's pace, tagged.
        let walked = (0...14).map { Self.point(Double($0), at: Double($0) * 120) }
        let driven = (1...6).map { Self.point(14 + Double($0) * 9, at: 1680 + Double($0) * 60, motion: .nonPedestrian) }

        let line = try await RouteTrimLine.measuring(walked + driven)

        let trailing = try #require(line.carriedEnds.trailing)
        #expect(line.carriedEnds.leading == nil)
        #expect(trailing.range.lowerBound.isApproximatelyEqual(to: line.distances[14], absoluteTolerance: 0.01))
        #expect(trailing.range.upperBound == line.totalMeters)
    }
}
