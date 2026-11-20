//
//  RouteShapeTests.swift
//  OpenHikesDataTests
//
//  What kind of line a walk drew: a loop, there and back, or one way. A
//  recording's name says "Loop" on the strength of this, so each walk here is
//  one that a rule about the two ends alone, or about the farthest point,
//  would have named wrongly.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Route shape")
struct RouteShapeTests {
    private static let trailhead = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.98)

    /// A point so many meters east and north of the trailhead.
    private static func point(east: Double, north: Double) -> CLLocationCoordinate2D {
        let metersPerDegree = RouteGeometry.metersPerDegreeLatitude
        return CLLocationCoordinate2D(
            latitude: trailhead.latitude + north / metersPerDegree,
            longitude: trailhead.longitude
                + east / (metersPerDegree * cos(trailhead.latitude * .pi / 180))
        )
    }

    /// The line through these corners, in meters east and north.
    private static func line(_ corners: [(east: Double, north: Double)]) -> [CLLocationCoordinate2D] {
        corners.map { point(east: $0.east, north: $0.north) }
    }

    /// A circle walked once round from the trailhead, a point every ten
    /// degrees.
    private static func circle(diameter: Double) -> [CLLocationCoordinate2D] {
        let radius = diameter / 2
        return stride(from: 0.0, through: 360, by: 10).map { degrees in
            let angle = degrees * .pi / 180
            return point(east: radius * sin(angle), north: radius - radius * cos(angle))
        }
    }

    @Test("round a square and back to the start is a loop")
    func aSquareIsALoop() {
        let walk = Self.line([(0, 0), (0, 1000), (1000, 1000), (1000, 0), (0, 0)])

        #expect(RouteShape.of(walk) == .loop)
    }

    @Test("up a path and down it again is out and back")
    func thereAndBackIsOutAndBack() {
        let walk = Self.line([(0, 0), (0, 2000), (0, 0)])

        #expect(RouteShape.of(walk) == .outAndBack)
    }

    /// The farthest point of this walk is the second corner, four kilometers
    /// before it turns round. Split there, most of the way back would be
    /// ground the way out never covered, and the walk would read as a loop.
    @Test("a path that bends back on itself, walked there and back, is out and back")
    func aBentPathIsStillOutAndBack() {
        let wayOut: [(east: Double, north: Double)] = [(0, 0), (3000, 0), (3000, -3000), (-1000, -3000)]
        let walk = Self.line(wayOut + wayOut.reversed().dropFirst())

        #expect(RouteShape.of(walk) == .outAndBack)
    }

    @Test("a walk that ends somewhere else is point to point")
    func oneWayIsPointToPoint() {
        let walk = Self.line([(0, 0), (0, 2000), (1500, 2500)])

        #expect(RouteShape.of(walk) == .pointToPoint)
    }

    /// The recording is stopped at the car, not on the spot it was started.
    @Test("a loop stopped across the car park is a loop, and one stopped down the road is not")
    func theEndsMayBeACarParkApart() {
        let acrossTheCarPark = Self.line([(0, 0), (0, 1000), (1000, 1000), (1000, 0), (100, 0)])
        let downTheRoad = Self.line([(0, 0), (0, 1000), (1000, 1000), (1000, 0), (200, 0)])

        #expect(RouteShape.of(acrossTheCarPark) == .loop)
        #expect(RouteShape.of(downTheRoad) == .pointToPoint)
    }

    @Test("a loop with a short path to it is a loop")
    func aShortWayInLeavesALoop() {
        let walk = Self.line([
            (0, 0), (0, 500),
            (0, 1500), (1000, 1500), (1000, 500), (0, 500),
            (0, 0),
        ])

        #expect(RouteShape.of(walk) == .loop)
    }

    @Test("a long path to a small loop at its end is out and back")
    func aLongWayInIsOutAndBack() {
        let walk = Self.line([
            (0, 0), (0, 3000),
            (0, 3250), (250, 3250), (250, 3000), (0, 3000),
            (0, 0),
        ])

        #expect(RouteShape.of(walk) == .outAndBack)
    }

    /// Two passes along one path under trees are not drawn on one line.
    @Test("a way back drawn fifteen meters beside the way out is the same path")
    func aDriftedWayBackIsTheSamePath() {
        let walk = Self.line([(0, 0), (0, 2000), (15, 2000), (15, 0)])

        #expect(RouteShape.of(walk) == .outAndBack)
    }

    @Test("a way back eighty meters from the way out is another path")
    func theFarBankIsAnotherPath() {
        let walk = Self.line([(0, 0), (0, 2000), (80, 2000), (80, 0), (0, 0)])

        #expect(RouteShape.of(walk) == .loop)
    }

    /// Where the two halves of a loop meet, at its start and at its far
    /// side, each is beside the other. On a small loop that is the largest
    /// share it ever is.
    @Test("a small loop is a loop", arguments: [160.0, 200, 400])
    func aSmallLoopIsALoop(diameter: Double) {
        #expect(RouteShape.of(Self.circle(diameter: diameter)) == .loop)
    }

    @Test("a line that never left its start has no shape")
    func aLineThatWentNowhereHasNoShape() {
        #expect(RouteShape.of([]) == nil)
        #expect(RouteShape.of([Self.trailhead]) == nil)
        #expect(RouteShape.of(Self.line([(0, 0), (0, 100), (0, 0)])) == nil)
        #expect(RouteShape.of(Self.circle(diameter: 140)) == nil)
    }

    @Test("a coordinate that is not a number has no shape")
    func aBrokenCoordinateHasNoShape() {
        let broken = CLLocationCoordinate2D(latitude: .nan, longitude: 12.98)

        #expect(RouteShape.of([broken, Self.trailhead, broken]) == nil)
    }

    /// Past the sample budget the spacing grows with the line, and the cells
    /// with it, so the answer is the same one.
    @Test("a line longer than its sample budget is read the same way")
    func aVeryLongLineIsReadTheSameWay() {
        let farEnd = Double(RouteShape.maximumSamples) * RouteShape.sampleSpacingMeters * 2
        let thereAndBack = Self.line([(0, 0), (0, farEnd), (0, 0)])
        let round = Self.line([(0, 0), (0, farEnd), (farEnd, farEnd), (farEnd, 0), (0, 0)])

        #expect(RouteShape.of(thereAndBack) == .outAndBack)
        #expect(RouteShape.of(round) == .loop)
    }

    @Test("a walk across the antimeridian and back is out and back")
    func acrossTheAntimeridianAndBack() {
        let walk = [
            CLLocationCoordinate2D(latitude: 60, longitude: 179.99),
            CLLocationCoordinate2D(latitude: 60, longitude: -179.99),
            CLLocationCoordinate2D(latitude: 60, longitude: 179.99),
        ]

        #expect(RouteShape.of(walk) == .outAndBack)
    }
}

// swiftlint:enable no_magic_numbers
