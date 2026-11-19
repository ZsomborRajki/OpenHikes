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

    // MARK: The line beside a line

    /// On a picture whose y runs down, the right of a line running east is
    /// below it: where a name that reads along it has its foot.
    @Test("the line beside a line running east lies below it, as far off as asked")
    func offsetOfAStraightLine() {
        let beside = MeasuredPath.offset([.zero, CGPoint(x: 10, y: 0)], by: 4)

        #expect(beside == [CGPoint(x: 0, y: 4), CGPoint(x: 10, y: 4)])
    }

    @Test("read the other way, the line beside it lies on the other side")
    func offsetFollowsTheDirection() {
        let beside = MeasuredPath.offset([CGPoint(x: 10, y: 0), .zero], by: 4)

        #expect(beside == [CGPoint(x: 10, y: -4), CGPoint(x: 0, y: -4)])
    }

    /// East, then south: a turn to the right, so the line beside it runs
    /// inside the corner and is shorter by twice the offset.
    @Test("inside a corner the line beside it turns sooner, and is the shorter for it")
    func offsetInsideACorner() {
        let line = [CGPoint.zero, CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 20)]

        let beside = MeasuredPath.offset(line, by: 4)

        #expect(beside == [CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4), CGPoint(x: 16, y: 20)])
        #expect(MeasuredPath(beside).length == MeasuredPath(line).length - 8)
    }

    @Test("outside a corner it turns later, and is the longer")
    func offsetOutsideACorner() {
        let line = [CGPoint.zero, CGPoint(x: 20, y: 0), CGPoint(x: 20, y: -20)]

        let beside = MeasuredPath.offset(line, by: 4)

        #expect(beside == [CGPoint(x: 0, y: 4), CGPoint(x: 24, y: 4), CGPoint(x: 24, y: -20)])
    }

    /// A stream's kink shorter than the offset: shifted point by point, the
    /// line beside it would run backwards there, and so would a name's
    /// letters.
    @Test("a kink tighter than the offset is left out rather than run backwards")
    func offsetNeverRunsBackwards() {
        let line = [CGPoint.zero, CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 2), CGPoint(x: 40, y: 2)]

        let beside = MeasuredPath.offset(line, by: 8)

        #expect(beside.first == CGPoint(x: 0, y: 8))
        #expect(beside.last == CGPoint(x: 40, y: 10))
        #expect(zip(beside, beside.dropFirst()).allSatisfy { $0.x <= $1.x }, "never back toward the west")
    }

    @Test("no offset, or a line of one point, is the line as it was")
    func offsetOfNothing() {
        let line = [CGPoint.zero, CGPoint(x: 10, y: 0)]

        #expect(MeasuredPath.offset(line, by: 0) == line)
        #expect(MeasuredPath.offset([CGPoint(x: 3, y: 4)], by: 5) == [CGPoint(x: 3, y: 4)])
        #expect(MeasuredPath.offset([], by: 5).isEmpty)
    }
}
