//
//  MeasuredPathTests.swift
//  OpenHikesTests
//
//  The polyline measured along its length that the names along lines and
//  the one-way arrows are placed on: how far along it each point is, and
//  the point a distance along it, held to its ends and passing over a step
//  of no length.
//

import CoreGraphics
@testable import OpenHikes
import Testing

@Suite("Measured path")
struct MeasuredPathTests {
    /// Ten pixels east, the corner again, then ten pixels south.
    private let corner = MeasuredPath([
        .zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10),
    ])

    @Test("each point is as far along as the one before and the step to it, a repeated point adding nothing")
    func distancesRunOn() {
        #expect(corner.distances == [0, 10, 10, 20])
        #expect(corner.length == 20)
    }

    @Test("a point along the line lies on the first segment that reaches that far", arguments: [
        (5, CGPoint(x: 5, y: 0)),
        (10, CGPoint(x: 10, y: 0)),
        (15, CGPoint(x: 10, y: 5)),
        (20, CGPoint(x: 10, y: 10)),
    ] as [(CGFloat, CGPoint)])
    func pointAlong(distance: CGFloat, expected: CGPoint) {
        #expect(corner.point(at: distance) == expected)
    }

    @Test("a distance before the start or past the end is held to that end")
    func heldToItsEnds() {
        #expect(corner.point(at: -3) == .zero)
        #expect(corner.point(at: 0) == .zero)
        #expect(corner.point(at: 25) == CGPoint(x: 10, y: 10))
        #expect(MeasuredPath([CGPoint(x: 3, y: 4)]).point(at: 5) == CGPoint(x: 3, y: 4))
        #expect(MeasuredPath([]).point(at: 5) == .zero)
    }
}
