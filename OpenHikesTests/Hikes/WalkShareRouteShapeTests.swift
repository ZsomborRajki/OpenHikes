//
//  WalkShareRouteShapeTests.swift
//  OpenHikesTests
//
//  The share card's route drawing: the trail fitted into a unit square with
//  north up, its shape kept rather than stretched, and the walked stretches
//  fitted into the same square so they land on the trail they were walked
//  along.
//

import CoreGraphics
import CoreLocation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Walk share route shape")
struct WalkShareRouteShapeTests {
    /// A trail twice as long north–south as it is wide, at the equator so a
    /// degree is the same length both ways.
    private static let tall = [
        CLLocationCoordinate2D(latitude: 0, longitude: 0),
        CLLocationCoordinate2D(latitude: 0.02, longitude: 0.01),
    ]

    @Test("the longer side spans the square and the other keeps its share")
    func keepsTheShape() throws {
        let shape = WalkShareRouteShape(fitting: Self.tall, walked: [])
        let start = try #require(shape.trail.first)
        let end = try #require(shape.trail.last)

        // South to north is the full height, measured downwards.
        #expect((start.y - end.y).isApproximatelyEqual(to: 1, absoluteTolerance: 1e-9))
        // Half as wide, less the hundredth of a degree's latitude correction.
        #expect((end.x - start.x).isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-6))
    }

    @Test("north is up and the narrow side is centred")
    func northIsUpAndCentred() throws {
        let shape = WalkShareRouteShape(fitting: Self.tall, walked: [])
        let south = try #require(shape.trail.first)
        let north = try #require(shape.trail.last)

        #expect(north.y < south.y)
        #expect(((south.x + north.x) / 2).isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-9))
    }

    @Test("a walked stretch lands on the trail it was walked along")
    func walkedSharesTheTrailsFrame() throws {
        let middle = CLLocationCoordinate2D(latitude: 0.01, longitude: 0.005)
        let shape = WalkShareRouteShape(fitting: Self.tall, walked: [[Self.tall[0], middle]])
        let stretch = try #require(shape.walked.first)
        let stretchEnd = try #require(stretch.last)

        #expect(stretchEnd.x.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-9))
        #expect(stretchEnd.y.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-9))
    }

    @Test("points too close to draw apart are dropped, the ends never")
    func thinsButKeepsTheEnds() {
        let points = (0...100).map { CGPoint(x: CGFloat($0) * 0.0001, y: 0) } + [CGPoint(x: 1, y: 1)]
        let thinned = WalkShareRouteShape.thinned(points)

        #expect(thinned.count < points.count)
        #expect(thinned.first == points.first)
        #expect(thinned.last == points.last)
    }

    @Test("no trail is an empty drawing, and a trail standing still is a point in the middle")
    func degenerateTrails() throws {
        #expect(WalkShareRouteShape(fitting: [], walked: []) == .empty)

        let still = CLLocationCoordinate2D(latitude: 47, longitude: 12)
        let point = try #require(WalkShareRouteShape(fitting: [still, still], walked: []).trail.first)
        #expect(point == CGPoint(x: 0.5, y: 0.5))
    }
}
