//
//  RouteCarriedEndsTests.swift
//  OpenHikesDataTests
//
//  The ends of a line the hiker did not walk: found by Core Motion's tag, by
//  speed where there is none, and by a pause that moved, and left alone where
//  they are no real stretch or there is no walk between them.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Route carried ends")
struct RouteCarriedEndsTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Metres in one degree of longitude on the equator.
    private static let metersPerDegree = RouteGeometry.distanceMeters(
        from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        to: CLLocationCoordinate2D(latitude: 0, longitude: 1)
    )

    /// Builds a line eastward along the equator, a fix every ten seconds.
    private struct Line {
        private(set) var route: [RouteCoordinate] = []
        private var meters = 0.0
        private var seconds = 0.0

        init() { append(motion: nil, boundary: nil) }

        private mutating func append(motion: RouteMotion?, boundary: RouteBoundary?, stamped: Bool = true) {
            route.append(RouteCoordinate(
                latitude: 0,
                longitude: meters / RouteCarriedEndsTests.metersPerDegree,
                timestamp: stamped ? RouteCarriedEndsTests.start.addingTimeInterval(seconds) : nil,
                motion: motion,
                boundary: boundary
            ))
        }

        /// `meters` on foot, at a hiker's pace.
        mutating func walk(_ distance: Double, tagged motion: RouteMotion? = nil, stamped: Bool = true) {
            move(distance, metersPerFix: 12, motion: motion, stamped: stamped)
        }

        /// `meters` at a car's speed, tagged by Core Motion or not.
        mutating func drive(_ distance: Double, tagged: Bool = false) {
            move(distance, metersPerFix: 150, motion: tagged ? .nonPedestrian : nil, stamped: true)
        }

        /// A pause that ends `meters` further on, an hour later.
        mutating func pause(moving distance: Double) {
            meters += distance
            seconds += 3600
            append(motion: nil, boundary: .paused)
        }

        private mutating func move(_ distance: Double, metersPerFix: Double, motion: RouteMotion?, stamped: Bool) {
            let fixes = Int((distance / metersPerFix).rounded(.up))
            for _ in 0..<fixes {
                meters += distance / Double(fixes)
                seconds += 10
                append(motion: motion, boundary: nil, stamped: stamped)
            }
        }
    }

    private static func ends(of line: Line) -> (ends: RouteCarriedEnds, total: Double) {
        let distances = RouteTrim.distances(along: line.route)
        return (RouteCarriedEnds.found(in: line.route, distances: distances), distances.last ?? 0)
    }

    @Test("a hike with the drive home recorded after it ends with a carried stretch")
    func driveHomeBySpeed() throws {
        var line = Line()
        line.walk(4000)
        line.drive(9000)

        let (ends, total) = Self.ends(of: line)

        #expect(ends.leading == nil)
        let trailing = try #require(ends.trailing)
        #expect(trailing.range.lowerBound.isApproximatelyEqual(to: 4000, absoluteTolerance: 1))
        #expect(trailing.range.upperBound == total)
        #expect(trailing.carriedMeters.isApproximatelyEqual(to: 9000, absoluteTolerance: 1))
        #expect(ends.walkedRange(of: total).upperBound.isApproximatelyEqual(to: 4000, absoluteTolerance: 1))
    }

    @Test("Core Motion's tag finds a drive too slow to tell by speed")
    func slowDriveByMotion() throws {
        var line = Line()
        line.walk(3000)
        // A forest road at walking pace, which only the tag gives away.
        line.walk(1500, tagged: .nonPedestrian)

        let (ends, _) = Self.ends(of: line)

        let trailing = try #require(ends.trailing)
        #expect(trailing.range.lowerBound.isApproximatelyEqual(to: 3000, absoluteTolerance: 1))
    }

    @Test("a tagged drive is found on a line with no times")
    func motionNeedsNoClock() {
        var line = Line()
        line.walk(3000, stamped: false)
        line.walk(1500, tagged: .nonPedestrian, stamped: false)

        #expect(Self.ends(of: line).ends.trailing != nil)
    }

    @Test("a drive to the trailhead is the leading stretch")
    func driveToTheTrailhead() throws {
        var line = Line()
        line.drive(6000, tagged: true)
        line.walk(5000)

        let (ends, total) = Self.ends(of: line)

        #expect(ends.trailing == nil)
        let leading = try #require(ends.leading)
        #expect(leading.range.lowerBound == 0)
        #expect(leading.range.upperBound.isApproximatelyEqual(to: 6000, absoluteTolerance: 1))
        let walked = ends.walkedRange(of: total)
        #expect(walked.lowerBound.isApproximatelyEqual(to: 6000, absoluteTolerance: 1))
        #expect(walked.upperBound == total)
    }

    @Test("a stop on the drive and the steps from the car are part of it")
    func shortWalksInsideADrive() throws {
        var line = Line()
        line.walk(4000)
        line.drive(3000)
        line.walk(80)
        line.drive(5000)
        line.walk(60)

        let (ends, total) = Self.ends(of: line)

        let trailing = try #require(ends.trailing)
        #expect(trailing.range.lowerBound.isApproximatelyEqual(to: 4000, absoluteTolerance: 1))
        #expect(trailing.range.upperBound == total)
        #expect(trailing.carriedMeters.isApproximatelyEqual(to: 8000, absoluteTolerance: 1))
    }

    @Test("a drive followed by a real walk is not the end of the line")
    func aWalkAfterTheDriveKeepsIt() {
        var line = Line()
        line.walk(4000)
        line.drive(5000)
        line.walk(900)

        #expect(Self.ends(of: line).ends.isEmpty)
    }

    @Test("a recording paused through the drive ends with the pause")
    func pauseThatMoved() throws {
        var line = Line()
        line.walk(4000)
        line.pause(moving: 12_000)
        line.walk(50)

        let (ends, total) = Self.ends(of: line)

        let trailing = try #require(ends.trailing)
        #expect(trailing.range.lowerBound.isApproximatelyEqual(to: 4000, absoluteTolerance: 1))
        #expect(trailing.range.upperBound == total)
        #expect(trailing.carriedMeters.isApproximatelyEqual(to: 12_000, absoluteTolerance: 1))
    }

    @Test("a pause where the hiker stayed put is not a drive")
    func pauseInPlace() {
        var line = Line()
        line.walk(4000)
        line.pause(moving: 20)
        line.walk(50)

        #expect(Self.ends(of: line).ends.isEmpty)
    }

    @Test("a few fast fixes are not a carried stretch")
    func aSpikeIsNoDrive() {
        var line = Line()
        line.walk(4000)
        line.drive(300)

        #expect(Self.ends(of: line).ends.isEmpty)
    }

    @Test("a line carried from end to end has no ends to take off")
    func aRideIsNotAWalk() {
        var ride = Line()
        ride.drive(20_000, tagged: true)
        var shortWalk = Line()
        shortWalk.drive(6000)
        shortWalk.walk(250)
        shortWalk.drive(6000)

        #expect(Self.ends(of: ride).ends.isEmpty)
        #expect(Self.ends(of: shortWalk).ends.isEmpty)
    }

    @Test("a walked line has none, and neither has a line too short to read")
    func nothingCarried() {
        var line = Line()
        line.walk(8000)

        #expect(Self.ends(of: line).ends.isEmpty)
        #expect(RouteCarriedEnds.found(in: [], distances: []).isEmpty)
        #expect(RouteCarriedEnds.found(in: Line().route, distances: [0]).isEmpty)
    }
}

// swiftlint:enable no_magic_numbers
