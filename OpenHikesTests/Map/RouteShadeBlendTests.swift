//
//  RouteShadeBlendTests.swift
//  OpenHikesTests
//
//  Where the blend between two coloured stretches is drawn: over the place
//  they meet, reaching the same share of the shorter stretch into each, so
//  further between long stretches than between short ones, in spans that keep
//  its colours where their distance along a bending line puts them, and
//  nowhere two stretches do not actually meet or do not differ.
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

    /// A stretch along straight legs through `corners`, in metres east and
    /// north of ``origin``, a point every ten metres.
    private static func stretch(
        through corners: [(east: Double, north: Double)],
        _ color: CGColor
    ) -> DirectionalPolylineRenderer.Shade {
        let point = { (east: Double, north: Double) in
            MKMapPoint(x: origin.x + east * mapPointsPerMeter, y: origin.y - north * mapPointsPerMeter)
        }
        var points = corners.first.map { [point($0.east, $0.north)] } ?? []
        for (from, to) in zip(corners, corners.dropFirst()) {
            let steps = max(1, Int((hypot(to.east - from.east, to.north - from.north) / 10).rounded(.up)))
            for step in 1...steps {
                let along = Double(step) / Double(steps)
                points.append(point(
                    from.east + (to.east - from.east) * along,
                    from.north + (to.north - from.north) * along
                ))
            }
        }
        return .init(polyline: MKPolyline(points: points, count: points.count), color: color)
    }

    private static func meters(at point: MKMapPoint) -> Double {
        (point.x - origin.x) / mapPointsPerMeter
    }

    /// How far through a gradient laid from `start` to `end` it colours
    /// `point`: where the point falls along the line between them, held at
    /// either end as the drawing holds it.
    private static func share(of point: MKMapPoint, from start: MKMapPoint, to end: MKMapPoint) -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let across = ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)
        return min(max(across, 0), 1)
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

    /// One gradient laid straight across a piece that bends colours a point
    /// by where it lies across the ground, not along the line: through this
    /// hairpin it put the half-and-half mix 139 m before the point the
    /// stretches share. In spans, every point of the piece is drawn within
    /// the tolerance of its place in the fade, and the shared point exactly
    /// half and half.
    @Test("a blend that bends is drawn in spans that follow the line")
    func bentBlendFollowsTheLine() throws {
        let pieces = RouteShadeBlend.pieces(between: [
            Self.stretch(through: [(-1000, 0), (0, 0)], Self.red),
            Self.stretch(through: [(0, 0), (80, 0), (80, 50), (-150, 50), (-150, 690)], Self.blue),
        ])

        let piece = try #require(pieces.count == 1 ? pieces[0] : nil)
        let points = piece.points
        let along = zip(points, points.dropFirst()).reduce(into: [0.0]) { along, pair in
            along.append(along[along.count - 1] + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y))
        }
        let length = try #require(along.last)
        let meeting = try #require(points.firstIndex { $0.x == Self.origin.x && $0.y == Self.origin.y })
        #expect(piece.spans.contains { $0.range.upperBound == meeting }, "a span should end where the stretches meet")
        for span in piece.spans {
            for index in span.range {
                let drawn = Self.share(of: points[index], from: span.gradientStart, to: span.gradientEnd)
                let fade = along[index] / length
                #expect(
                    drawn.isApproximatelyEqual(to: fade, absoluteTolerance: RouteShadeBlend.spanTolerance),
                    "point \(index) is \(fade) of the way along the piece, and drawn \(drawn) of the way through"
                )
                if index == meeting {
                    #expect(drawn.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-9))
                }
            }
        }
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
