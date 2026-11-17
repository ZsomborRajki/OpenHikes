//
//  RouteSegmentsTests.swift
//  OpenHikesDataTests
//
//  The segments a hike's pauses cut it into (#1470): each walked run's own
//  distance, time and climb, the stop between two of them, and the routes
//  that have none to show.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Route segments")
struct RouteSegmentsTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// One thousandth of a degree of longitude on the equator.
    private static let step = RouteGeometry.distanceMeters(
        from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        to: CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
    )

    /// A point `longitude` thousandths of a degree along the equator.
    private static func point(
        _ longitude: Double,
        at seconds: TimeInterval? = nil,
        elevation: Double? = nil,
        resumed: Bool = false
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: 0,
            longitude: longitude / 1000,
            elevation: elevation,
            timestamp: seconds.map(start.addingTimeInterval),
            boundary: resumed ? .paused : nil
        )
    }

    private static func segments(_ route: [RouteCoordinate], distance: Double? = nil) -> [RouteSegment] {
        RouteSegments.segments(of: route, distanceMeters: distance ?? route.lengthMeters)
    }

    /// To the shop in ten minutes, twenty minutes inside, home in twelve.
    private static let shopWalk = [
        point(0, at: 0, elevation: 500),
        point(4, at: 300, elevation: 520),
        point(8, at: 600, elevation: 540),
        point(8, at: 1800, elevation: 540, resumed: true),
        point(5, at: 2160, elevation: 530),
        point(0, at: 2520, elevation: 500),
    ]

    @Test("a walk with one stop is two segments, each with its own figures")
    func walkWithOneStop() throws {
        let segments = Self.segments(Self.shopWalk)

        try #require(segments.count == 2)
        #expect(segments[0].distanceMeters.isApproximatelyEqual(to: 8 * Self.step, absoluteTolerance: 0.01))
        #expect(segments[0].seconds == 600)
        #expect(segments[0].elevationGainMeters == 40)
        #expect(segments[0].stopSeconds == 1200)
        #expect(segments[1].distanceMeters.isApproximatelyEqual(to: 8 * Self.step, absoluteTolerance: 0.01))
        #expect(segments[1].seconds == 720)
        #expect(segments[1].elevationGainMeters == 0)
        #expect(segments[1].stopSeconds == nil, "nothing follows the last segment")
    }

    @Test("a segment's average speed is its distance over its own time")
    func averageSpeed() throws {
        let first = try #require(Self.segments(Self.shopWalk).first)
        let speed = try #require(first.averageSpeedMetersPerSecond)

        #expect(speed.isApproximatelyEqual(to: 8 * Self.step / 600, absoluteTolerance: 0.001))
        #expect(RouteSegment(distanceMeters: 100).averageSpeedMetersPerSecond == nil)
        #expect(RouteSegment(distanceMeters: 100, seconds: 0).averageSpeedMetersPerSecond == nil)
    }

    /// Ten steps with a clock on the last two only, as a GPX file whose
    /// receiver found its time late.
    @Test("a segment stamped on part of its length is as fast as that part")
    func partlyStamped() throws {
        let partly = (0...10).map { step in
            Self.point(Double(step), at: step >= 8 ? Double(step) * 60 : nil)
        }
        let route = partly + [Self.point(10, at: 1800, resumed: true), Self.point(14, at: 2040)]

        let first = try #require(Self.segments(route).first)
        let speed = try #require(first.averageSpeedMetersPerSecond)
        #expect(first.seconds == 120)
        #expect(speed.isApproximatelyEqual(to: 2 * Self.step / 120, absoluteTolerance: 0.0001))
    }

    @Test("a route with no pause has no segments to show")
    func onePiece() {
        #expect(Self.segments([Self.point(0, at: 0), Self.point(5, at: 600), Self.point(9, at: 1200)]).isEmpty)
        #expect(Self.segments([]).isEmpty)
        #expect(Self.segments([Self.point(0, at: 0)]).isEmpty)
    }

    /// The hiker paused, was driven somewhere a single fix was kept, paused
    /// again and walked on: the fix is no segment, and the stop it stands in
    /// runs from the segment before it to the one after.
    @Test("a lone fix between two pauses is no segment, and its stop is one stop")
    func loneFix() throws {
        let route = [
            Self.point(0, at: 0),
            Self.point(3, at: 300),
            Self.point(20, at: 900, resumed: true),
            Self.point(40, at: 1500, resumed: true),
            Self.point(43, at: 1800),
        ]

        let segments = Self.segments(route)

        try #require(segments.count == 2)
        #expect(segments[0].stopSeconds == 1200)
        #expect(segments[1].seconds == 300)
    }

    @Test("a route that begins on a lone fix has no stop before its first segment")
    func leadingLoneFix() {
        let route = [
            Self.point(0, at: 0),
            Self.point(1, at: 600, resumed: true),
            Self.point(4, at: 900),
        ]

        #expect(Self.segments(route).isEmpty, "one walked run is one piece")
    }

    /// An imported GPX with two `<trkseg>` and no `<time>`.
    @Test("a route with no clock has segments with distances alone")
    func noClock() throws {
        let route = [Self.point(0), Self.point(3), Self.point(3, resumed: true), Self.point(7)]

        let segments = Self.segments(route)

        try #require(segments.count == 2)
        #expect(segments[0].seconds == nil)
        #expect(segments[0].stopSeconds == nil)
        #expect(segments[0].elevationGainMeters == nil)
        #expect(segments[1].distanceMeters.isApproximatelyEqual(to: 4 * Self.step, absoluteTolerance: 0.01))
    }

    /// A recording's distance is shorter than its line, by the wander its
    /// stops took back.
    @Test("the segments add up to the hike's own distance")
    func segmentsAddUpToTheHike() {
        let line = Self.shopWalk.lengthMeters
        let segments = Self.segments(Self.shopWalk, distance: line * 0.9)

        let total = segments.reduce(0) { $0 + $1.distanceMeters }
        #expect(total.isApproximatelyEqual(to: line * 0.9, absoluteTolerance: 0.01))
        #expect(
            segments[0].distanceMeters.isApproximatelyEqual(to: segments[1].distanceMeters, absoluteTolerance: 0.01)
        )
    }

    /// A device that starts a `<trkseg>` at every lost signal.
    @Test("a route cut into more pieces than a walk has stops shows none")
    func heavilySegmentedFile() {
        func route(pieces: Int) -> [RouteCoordinate] {
            (0..<pieces).flatMap { piece in
                [
                    Self.point(Double(piece * 2), resumed: piece > 0),
                    Self.point(Double(piece * 2 + 1)),
                ]
            }
        }

        #expect(Self.segments(route(pieces: RouteSegments.maximumCount)).count == RouteSegments.maximumCount)
        #expect(Self.segments(route(pieces: RouteSegments.maximumCount + 1)).isEmpty)
    }

    @Test("the builder fed a point at a time gives what a walk of the route gives")
    func builderMatchesTheWalk() {
        var builder = RouteSegments.Builder()
        var previous: RouteCoordinate?
        for point in Self.shopWalk {
            builder.consume(point, segmentMeters: previous.map(point.legMeters(from:)) ?? 0)
            previous = point
        }

        #expect(builder.finish(distanceMeters: Self.shopWalk.lengthMeters) == Self.segments(Self.shopWalk))
    }
}

// swiftlint:enable no_magic_numbers
