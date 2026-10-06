//
//  RouteShadeBlendTests.swift
//  OpenHikesTests
//
//  Where the blend between two coloured stretches is drawn: over the place
//  they meet, reaching the same distance into each, never past the middle of
//  a short one, and nowhere two stretches do not actually meet or do not
//  differ. `DirectionalPolylineRendererTests+Shades` checks the drawing.
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
        let reach = RouteShadeBlend.blendMeters
        #expect(Self.meters(at: start).isApproximatelyEqual(to: 200 - reach, absoluteTolerance: 0.01))
        #expect(Self.meters(at: end).isApproximatelyEqual(to: 200 + reach, absoluteTolerance: 0.01))
        #expect(piece.points.contains { Self.meters(at: $0).isApproximatelyEqual(to: 200, absoluteTolerance: 0.01) })
    }

    /// The shortest stretch has to show its own colour somewhere, so a
    /// blend may take half of it from each end and no more.
    @Test("a blend reaches no further than the middle of a short stretch")
    func shortStretchIsHalved() throws {
        let pieces = RouteShadeBlend.pieces(between: [
            Self.stretch(0, 200, Self.red), Self.stretch(200, 230, Self.blue),
        ])

        let end = try #require(pieces.first??.points.last)
        #expect(Self.meters(at: end).isApproximatelyEqual(to: 215, absoluteTolerance: 0.01))
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
