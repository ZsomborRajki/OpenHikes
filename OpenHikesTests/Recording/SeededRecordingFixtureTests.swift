//
//  SeededRecordingFixtureTests.swift
//  OpenHikesTests
//
//  The recording `--ui-test-seed-recording` puts under way is a stretch of a
//  real file with its own clock, moved to end a moment ago — not a line drawn
//  at a pace nobody walks.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Seeded recording fixture")
struct SeededRecordingFixtureTests {
    private static let start = Date(timeIntervalSince1970: 1_750_000_000)
    private static let end = Date(timeIntervalSince1970: 1_760_000_000)

    /// A line due north, a point every 0.0002° (about 22 m), one a minute.
    private static func route(points: Int, timed: Bool = true) -> [RouteCoordinate] {
        (0..<points).map { index in
            RouteCoordinate(
                latitude: 47.6 + Double(index) * 0.0002,
                longitude: 12.98,
                elevation: 600 + Double(index),
                timestamp: timed ? start.addingTimeInterval(Double(index) * 60) : nil
            )
        }
    }

    @Test("the stretch stops at the distance asked for")
    func stopsAtTheDistance() {
        let points = SeededRecordingFixture.recordedPoints(
            of: Self.route(points: 50),
            upTo: 100,
            endingAt: Self.end
        )
        // 22 m apart: the first five are within 100 m, the sixth is not.
        #expect(points.count == 5)
    }

    @Test("the last point was taken at the end, and the file's own spacing is kept")
    func reTimedToEndNow() throws {
        let points = SeededRecordingFixture.recordedPoints(
            of: Self.route(points: 50),
            upTo: 1000,
            endingAt: Self.end
        )
        let last = try #require(points.last)
        let first = try #require(points.first)
        #expect(last.timestamp.timeIntervalSince(Self.end).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(
            last.timestamp.timeIntervalSince(first.timestamp)
                .isApproximatelyEqual(to: Double(points.count - 1) * 60, absoluteTolerance: 0.001)
        )
        #expect(first.elevation == 600)
    }

    @Test("a route with no clock gives nothing to recover")
    func untimedRouteGivesNothing() {
        let points = SeededRecordingFixture.recordedPoints(
            of: Self.route(points: 50, timed: false),
            upTo: 1000,
            endingAt: Self.end
        )
        #expect(points.isEmpty)
    }
}
