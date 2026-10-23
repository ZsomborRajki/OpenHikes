//
//  RouteShadeBlendTests.swift
//  OpenHikesTests
//
//  Where the blend between two coloured stretches is drawn: over the place
//  they meet, reaching the same share of the shorter stretch into each, so
//  further between long stretches than between short ones, and nowhere two
//  stretches do not actually meet or do not differ.
//  `DirectionalPolylineRendererTests+Shades` checks the drawing.
//

import CoreGraphics
import CoreLocation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

@Suite("Route shade blend")
struct RouteShadeBlendTests {
    private static let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private static let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    private static let latitude = 47.6
    /// Map points along a line of latitude, east from a fixed start.
    private static let mapPointsPerMeter = MKMapPointsPerMeterAtLatitude(latitude)
    private static let origin = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: 12.9))

    /// A straight stretch east from `fromMeters` to `toMeters`, a point every
    /// ten metres.
    private static func stretch(
        _ fromMeters: Double,
        _ toMeters: Double,
        _ color: CGColor
    ) -> DirectionalPolylineRenderer.Shade {
        let points = stride(from: fromMeters, through: toMeters, by: 10).map { meters in
            MKMapPoint(x: origin.x + meters * mapPointsPerMeter, y: origin.y)
        }
        return .init(polyline: MKPolyline(points: points, count: points.count), color: color)
    }

    private static func meters(at point: MKMapPoint) -> Double {
        (point.x - origin.x) / mapPointsPerMeter
    }

    @Test("two stretches that meet in different colours blend across the point they share")
    func meetingStretchesBlend() throws {
        let pieces = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 200, Self.red), Self.stretch(200, 400, Self.blue),
        ])

        let piece = try #require(pieces.count == 1 ? pieces[0] : nil)
        let start = try #require(piece.points.first)
        let end = try #require(piece.points.last)
        let reach = RouteShadeBlend.reachShare * 200
        #expect(Self.meters(at: start).isApproximatelyEqual(to: 200 - reach, absoluteTolerance: 0.01))
        #expect(Self.meters(at: end).isApproximatelyEqual(to: 200 + reach, absoluteTolerance: 0.01))
        #expect(piece.points.contains { Self.meters(at: $0).isApproximatelyEqual(to: 200, absoluteTolerance: 0.01) })
    }

    /// The colour is half one and half the other where the stretches meet,
    /// and the short stretch keeps its middle in its own colour — so the
    /// blend reaches as far into the long one as into the short one.
    @Test("a blend reaches a share of the shorter stretch into each side")
    func reachFollowsTheShorterStretch() throws {
        let pieces = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 400, Self.red), Self.stretch(400, 480, Self.blue),
        ])

        let start = try #require(pieces.first??.points.first)
        let end = try #require(pieces.first??.points.last)
        let reach = RouteShadeBlend.reachShare * 80
        #expect(Self.meters(at: start).isApproximatelyEqual(to: 400 - reach, absoluteTolerance: 0.01))
        #expect(Self.meters(at: end).isApproximatelyEqual(to: 400 + reach, absoluteTolerance: 0.01))
    }

    /// Steepness stretches are hundreds of metres long, and a blend of a
    /// fixed few tens of metres was too short to draw with a whole hike on
    /// screen — see `RouteShadeBlend.swift`'s header.
    @Test("a blend between long stretches reaches further than one between short ones")
    func longStretchesBlendFurther() throws {
        let short = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 100, Self.red), Self.stretch(100, 200, Self.blue),
        ])
        let long = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 1000, Self.red), Self.stretch(1000, 2000, Self.blue),
        ])

        let shortStart = try #require(short.first??.points.first)
        let longStart = try #require(long.first??.points.first)
        let share = RouteShadeBlend.reachShare
        #expect((100 - Self.meters(at: shortStart)).isApproximatelyEqual(to: share * 100, absoluteTolerance: 0.01))
        #expect((1000 - Self.meters(at: longStart)).isApproximatelyEqual(to: share * 1000, absoluteTolerance: 0.01))
    }

    @Test("stretches that do not meet, or meet in one colour, do not blend")
    func noBlendWithoutAChange() {
        let gap = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 200, Self.red), Self.stretch(210, 400, Self.blue),
        ])
        let same = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 200, Self.red), Self.stretch(200, 400, Self.red),
        ])

        // One entry per neighbouring pair, so the renderer can draw each in
        // its place — and here neither pair has a piece.
        #expect(gap.count == 1 && gap.allSatisfy { $0 == nil })
        #expect(same.count == 1 && same.allSatisfy { $0 == nil })
    }
}
