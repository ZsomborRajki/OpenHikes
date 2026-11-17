//
//  HikeSegmentFiguresTests.swift
//  OpenHikesTests
//
//  One segment of a hike in the words its row draws and speaks (#1470), and
//  that a saved hike's segments are built in the pass that builds the rest
//  of its figures.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike segment figures")
struct HikeSegmentFiguresTests {
    private static let metric = Locale(identifier: "de_DE")
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("a segment with a clock and heights says all four figures")
    func everyFigure() {
        let segment = RouteSegment(distanceMeters: 2100, seconds: 1930, elevationGainMeters: 45)
        let figures = HikeSegmentFigures(segment, locale: Self.metric)

        let speed = HikeFormat.speed(Measurement(value: 2100.0 / 1930, unit: .metersPerSecond), locale: Self.metric)
        #expect(figures.distance == "2,1 km")
        #expect(figures.pace == "\(HikeFormat.duration(1930)) · \(speed)")
        #expect(figures.climb == "45 m")
        #expect(figures.spoken.contains(HikeFormat.spokenDuration(1930)))
        #expect(figures.spoken.contains(speed))
        #expect(figures.spoken.contains("of climb"), "the arrow drawn beside the climb is said in words")
    }

    /// An imported GPX with two `<trkseg>` and no `<time>`.
    @Test("a segment with no clock and no heights says its length alone")
    func lengthAlone() {
        let figures = HikeSegmentFigures(RouteSegment(distanceMeters: 800), locale: Self.metric)

        #expect(figures.distance == "800 m")
        #expect(figures.pace == nil)
        #expect(figures.climb == nil)
        #expect(!figures.spoken.contains(","), "one figure, and nothing joined to it")
    }

    @Test("a segment reads in the units of the reader's region")
    func imperial() {
        let segment = RouteSegment(distanceMeters: 3218.688, seconds: 3600, elevationGainMeters: 30.48)
        let figures = HikeSegmentFigures(segment, locale: Locale(identifier: "en_US"))

        #expect(figures.distance == "2 mi")
        #expect(figures.climb == "100 ft")
    }

    @Test("a hike's segments are built with the rest of its figures")
    func preparedWithTheDetail() async throws {
        func point(_ longitude: Double, at seconds: TimeInterval, resumed: Bool = false) -> RouteCoordinate {
            RouteCoordinate(
                latitude: 47.63,
                longitude: longitude,
                timestamp: Self.start.addingTimeInterval(seconds),
                boundary: resumed ? .paused : nil
            )
        }
        let route = [
            point(12.860, at: 0),
            point(12.865, at: 300),
            point(12.865, at: 1500, resumed: true),
            point(12.870, at: 1800),
        ]

        let prepared = try await HikeDetailPreparation.prepare(route: route, distanceMeters: route.lengthMeters)

        try #require(prepared.segments.count == 2)
        #expect(prepared.segments[0].stopSeconds == 1200)
        #expect(prepared.segments[1].seconds == 300)
    }

    @Test("a hike in one piece has no segments to draw")
    func onePiece() async throws {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.63, longitude: 12.87),
        ]

        let prepared = try await HikeDetailPreparation.prepare(route: route, distanceMeters: route.lengthMeters)

        #expect(prepared.segments.isEmpty)
    }
}
