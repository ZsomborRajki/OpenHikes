//
//  LibraryFootprintTests.swift
//  OpenHikesTests
//
//  Where *Totals* takes a stretch of ground to lie: the box around a hike's
//  line over its clock, and around the stretches a walk covered, and when
//  two such boxes meet. Which clocks that keeps from a walk is
//  `LibraryTotalsSameGroundTests`.
//
//  A walk's stretches are placed through blocks of its trail's points
//  (`LibraryFootprint.Line`), and held here to the box of every point they
//  pass, taken one by one, on lines and stretches laid down at random.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Library footprints")
struct LibraryFootprintTests {
    private static let margin = LibraryTotals.sameGroundMarginMeters
    private static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func at(_ minutes: Int) -> Date {
        origin.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Whether `footprint` is the box given, to well under a metre.
    private static func isBox(
        _ footprint: LibraryFootprint?,
        south: Double,
        north: Double,
        west: Double,
        span: Double
    ) -> Bool {
        guard let footprint else { return false }
        let tolerance = 1e-9
        return footprint.southLat.isApproximatelyEqual(to: south, absoluteTolerance: tolerance)
            && footprint.northLat.isApproximatelyEqual(to: north, absoluteTolerance: tolerance)
            && footprint.westLon.isApproximatelyEqual(to: west, absoluteTolerance: tolerance)
            && footprint.lonSpan.isApproximatelyEqual(to: span, absoluteTolerance: tolerance)
    }

    // MARK: Meeting

    @Test("boxes meet when they overlap, or come within the margin")
    func boxesMeetWithinTheMargin() {
        // A trail drawn along a meridian has no width; a recording 50 m east
        // of it has to meet it all the same.
        let meridian = LibraryFootprint(southLat: 47.55, northLat: 47.60, westLon: 12.95, lonSpan: 0)
        let beside = LibraryFootprint(southLat: 47.55, northLat: 47.60, westLon: 12.9507, lonSpan: 0)
        let alps = LibraryFootprint(southLat: 47.55, northLat: 47.60, westLon: 12.95, lonSpan: 0.05)
        let zurich = LibraryFootprint(southLat: 47.36, northLat: 47.40, westLon: 8.50, lonSpan: 0.05)
        // 150 m north of the trail's end, and 300 m.
        let north = LibraryFootprint(southLat: 47.60135, northLat: 47.61, westLon: 12.95, lonSpan: 0)
        let further = LibraryFootprint(southLat: 47.6027, northLat: 47.61, westLon: 12.95, lonSpan: 0)

        #expect(meridian.meets(beside, within: Self.margin))
        #expect(!meridian.meets(beside, within: 0))
        #expect(meridian.meets(north, within: Self.margin))
        #expect(!meridian.meets(further, within: Self.margin))
        #expect(!alps.meets(zurich, within: Self.margin))
        #expect(alps.meets(alps, within: 0))
    }

    @Test("boxes either side of the antimeridian meet across it")
    func boxesMeetAcrossTheAntimeridian() {
        let east = LibraryFootprint(southLat: -17.80, northLat: -17.70, westLon: 179.95, lonSpan: 0.1)
        let west = LibraryFootprint(southLat: -17.80, northLat: -17.70, westLon: -179.98, lonSpan: 0.02)
        let farWest = LibraryFootprint(southLat: -17.80, northLat: -17.70, westLon: -170, lonSpan: 0.02)

        #expect(east.meets(west, within: 0))
        #expect(west.meets(east, within: 0))
        #expect(!east.meets(farWest, within: Self.margin))
        #expect(!farWest.meets(east, within: Self.margin))
    }

    /// A box from the equator to 60° N, whose middle is at 30°, beside a
    /// short one at 60°, 0.003° of longitude apart: 167 m there. Measured at
    /// each box's own middle latitude, the tall box saw 289 m and the short
    /// one 167 m, so whether they met hung on which was asked.
    @Test("whether two boxes meet is the same answer either way round")
    func meetingIsSymmetric() {
        let tall = LibraryFootprint(southLat: 0, northLat: 60, westLon: 10, lonSpan: 0)
        let short = LibraryFootprint(southLat: 59.99, northLat: 60, westLon: 10.003, lonSpan: 0)

        #expect(tall.meets(short, within: Self.margin))
        #expect(short.meets(tall, within: Self.margin))
    }

    @Test("near a pole every longitude is within the margin")
    func everyLongitudeMeetsAtThePole() {
        let station = LibraryFootprint(southLat: -90, northLat: -89.999, westLon: 0, lonSpan: 0)
        let across = LibraryFootprint(southLat: -90, northLat: -89.999, westLon: -180, lonSpan: 0)

        #expect(station.meets(across, within: Self.margin))
        #expect(across.meets(station, within: Self.margin))
    }

    // MARK: A hike's line over its clock

    @Test("a clocked line lies from its first stamped point to its last")
    func clockedPartIsBetweenTheStamps() {
        let line = [
            RouteCoordinate(latitude: 46.0, longitude: 11.0),
            RouteCoordinate(latitude: 47.0, longitude: 12.0, timestamp: Self.at(0)),
            RouteCoordinate(latitude: 47.5, longitude: 12.4),
            RouteCoordinate(latitude: 47.2, longitude: 12.2, timestamp: Self.at(60)),
            RouteCoordinate(latitude: 49.0, longitude: 14.0),
        ]

        #expect(Self.isBox(LibraryFootprint(clockedPartOf: line), south: 47.0, north: 47.5, west: 12.0, span: 0.4))
        #expect(LibraryFootprint(clockedPartOf: [line[0], line[2], line[4]]) == nil, "a line with no stamp")
        #expect(LibraryFootprint(clockedPartOf: []) == nil)
    }

    @Test("a line across the antimeridian lies in the narrow arc over it")
    func lineAcrossTheAntimeridianIsNarrow() {
        let line = [
            RouteCoordinate(latitude: -17.70, longitude: 179.95, timestamp: Self.at(0)),
            RouteCoordinate(latitude: -17.71, longitude: -179.95, timestamp: Self.at(60)),
        ]

        let footprint = LibraryFootprint(clockedPartOf: line)

        #expect(Self.isBox(footprint, south: -17.71, north: -17.70, west: 179.95, span: 0.1))
    }

    @Test("a point that is not a place says nothing about where a line lies")
    func pointsThatAreNotPlacesArePassedOver() {
        let line = [
            RouteCoordinate(latitude: .nan, longitude: 12.0, timestamp: Self.at(0)),
            RouteCoordinate(latitude: 47.0, longitude: 12.0, timestamp: Self.at(30)),
            RouteCoordinate(latitude: 47.1, longitude: .infinity, timestamp: Self.at(45)),
            RouteCoordinate(latitude: 47.2, longitude: 12.1, timestamp: Self.at(60)),
        ]

        #expect(Self.isBox(LibraryFootprint(clockedPartOf: line), south: 47.0, north: 47.2, west: 12.0, span: 0.1))
        #expect(LibraryFootprint(clockedPartOf: [line[0]]) == nil)
    }

    // MARK: What a walk covered

    /// Due north, a kilometre a step, from 47° N.
    private static let trail = (0...4).map { step in
        RouteCoordinate(latitude: 47.0 + Double(step) * 0.009, longitude: 12.0)
    }

    @Test("a walk lies over the stretches it covered, between the line's points")
    func coveredStretchesLieWhereTheyWent() throws {
        let profile = RouteProfile(route: Self.trail)
        let leg = profile.distances[1]

        let footprint = try #require(LibraryFootprint.Line(profile).footprint(covering: [leg / 2...leg * 1.5]))

        #expect(footprint.southLat.isApproximatelyEqual(to: 47.0045, absoluteTolerance: 1e-6))
        #expect(footprint.northLat.isApproximatelyEqual(to: 47.0135, absoluteTolerance: 1e-6))
        #expect(footprint.lonSpan == 0)
        #expect(LibraryFootprint.Line(profile).footprint(covering: []) == nil, "a walk that covered nothing")
        #expect(LibraryFootprint.Line(RouteProfile(route: [])).footprint(covering: [0...leg]) == nil)
    }

    @Test("two stretches lie in one box that holds both, and nothing past them")
    func twoStretchesLieInOneBox() throws {
        let profile = RouteProfile(route: Self.trail)
        let distances = profile.distances

        let footprint = try #require(
            LibraryFootprint.Line(profile).footprint(covering: [0...distances[1], distances[3]...distances[3]])
        )

        #expect(footprint.southLat == 47.0)
        #expect(footprint.northLat.isApproximatelyEqual(to: 47.027, absoluteTolerance: 1e-9))
    }

    /// A pause leaves the line at one place and takes it up at another, at
    /// the same distance along it, so a stretch that ends there could have
    /// ended at either, and is taken to reach both.
    @Test("a stretch ending at a pause lies over both sides of it")
    func stretchEndingAtAPauseHoldsBothSides() throws {
        var line = Self.trail
        line[2].latitude = 47.5
        line[2].boundary = .paused
        let profile = RouteProfile(route: line)

        let footprint = try #require(LibraryFootprint.Line(profile).footprint(covering: [0...profile.distances[1]]))

        #expect(profile.distances[1] == profile.distances[2], "precondition: the pause has no length")
        #expect(footprint.northLat == 47.5)
    }

    /// Lines of up to a dozen blocks, some across the antimeridian and some
    /// with pauses, and stretches that start and end anywhere, past either
    /// end and on a point included: the blocks give the box the points give
    /// one by one, to the bit.
    @Test("a walk placed through blocks lies where every point it passed lies", arguments: [1, 64, 1679])
    func blocksPlaceAStretchAsItsPointsDo(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<200 {
            let count = Int.random(in: 0...(12 * LibraryFootprint.Line.blockLength + 1), using: &generator)
            let longitude = Bool.random(using: &generator) ? 179.9 : 12.0
            var heading = 0.0
            let line = (0..<count).map { index in
                heading += Double.random(in: -0.6...0.6, using: &generator)
                var point = RouteCoordinate(
                    latitude: 47 + Double(index) * 0.0003 * cos(heading),
                    longitude: longitude + Double(index) * 0.0003 * sin(heading)
                )
                if index > 0, Int.random(in: 0..<40, using: &generator) == 0 {
                    point.boundary = .paused
                }
                return point
            }
            let profile = RouteProfile(route: line)
            let blocks = LibraryFootprint.Line(profile)
            let total = profile.totalDistanceMeters
            let stretches = (0..<Int.random(in: 1...3, using: &generator)).map { _ in
                // Half of them from one point to another, so that a stretch
                // often ends on a point at a block's edge or beside it.
                guard count > 0, Bool.random(using: &generator) else {
                    let start = Double.random(in: -50...(total + 50), using: &generator)
                    return start...(start + Double.random(in: 0...(total / 2 + 1), using: &generator))
                }
                let ends = [Int.random(in: 0..<count, using: &generator), Int.random(in: 0..<count, using: &generator)]
                return profile.distances[ends.min() ?? 0]...profile.distances[ends.max() ?? 0]
            }

            let pointByPoint = LibraryFootprint(points: stretches.flatMap { Self.pointsPassed(by: $0, along: profile) })

            #expect(blocks.footprint(covering: stretches) == pointByPoint, "seed \(seed), \(count) points")
        }
    }

    /// Every stretch from one point to another of a line two blocks and a
    /// bit long, heading north so that each point further on is a new
    /// northern edge: a block taken whole one point too soon, or too late,
    /// shows.
    @Test("a stretch from any point to any other lies where the points between lie")
    func everyStretchBetweenPointsLiesWhereItsPointsDo() {
        let count = 2 * LibraryFootprint.Line.blockLength + 3
        let line = (0..<count).map { index in
            RouteCoordinate(
                latitude: 47 + Double(index) * 0.0003,
                longitude: 12 + (index.isMultiple(of: 2) ? 0.0002 : 0)
            )
        }
        let profile = RouteProfile(route: line)
        let blocks = LibraryFootprint.Line(profile)
        var mismatches: [ClosedRange<Int>] = []

        for first in 0..<count {
            for last in first..<count {
                let stretch = profile.distances[first]...profile.distances[last]
                let pointByPoint = LibraryFootprint(points: Self.pointsPassed(by: stretch, along: profile))
                if blocks.footprint(covering: [stretch]) != pointByPoint {
                    mismatches.append(first...last)
                }
            }
        }

        #expect(mismatches.isEmpty)
    }

    /// The ends of `stretch` and every point of the line whose distance lies
    /// within it, found by looking at each.
    private static func pointsPassed(
        by stretch: ClosedRange<Double>,
        along profile: RouteProfile
    ) -> [CLLocationCoordinate2D] {
        let ends = [stretch.lowerBound, stretch.upperBound].compactMap(profile.coordinate(atDistance:))
        let passed = profile.coordinates.indices
            .filter { stretch.contains(profile.distances[$0]) }
            .map { profile.coordinates[$0] }
        return ends + passed
    }
}
