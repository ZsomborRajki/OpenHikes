//
//  RouteTrimTests.swift
//  OpenHikesDataTests
//
//  A line with its ends cut off: what a trim keeps exactly as it was saved,
//  the point a cut between two points makes, and what it does at a pause.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Route trim")
struct RouteTrimTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// One thousandth of a degree of longitude on the equator.
    private static let step = RouteGeometry.distanceMeters(
        from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        to: CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
    )

    /// A point `longitude` thousandths of a degree along the equator.
    private static func point(
        _ longitude: Double,
        at seconds: TimeInterval? = nil,
        elevation: Double? = nil,
        resumed: Bool = false,
        inferred: Bool = false
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: 0,
            longitude: longitude / 1000,
            elevation: elevation,
            timestamp: seconds.map(start.addingTimeInterval),
            provenance: inferred ? .inferred : nil,
            boundary: resumed ? .paused : nil
        )
    }

    /// Five points a step apart, a minute and ten metres of climb between
    /// each.
    private static let line = (0...4).map { index in
        point(Double(index), at: Double(index) * 60, elevation: 500 + Double(index) * 10)
    }

    @Test("a trim that takes nothing off gives the line back as it was saved")
    func wholeLine() {
        let route = [Self.point(0, resumed: true, inferred: true), Self.point(1), Self.point(2)]

        #expect(RouteTrim.trimmed(route, keeping: 0...route.lengthMeters) == route)
        #expect(RouteTrim.trimmed(route, keeping: -50...1_000_000) == route)
    }

    @Test("a cut on a point keeps the points between the cuts untouched")
    func cutsOnPoints() {
        let kept = RouteTrim.trimmed(Self.line, keeping: Self.step...(3 * Self.step))

        #expect(kept == Array(Self.line[1...3]))
        #expect(kept.lengthMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
    }

    @Test("a cut between two points makes one there, with that spot's height and time")
    func cutsBetweenPoints() throws {
        let kept = RouteTrim.trimmed(Self.line, keeping: (0.5 * Self.step)...(3.25 * Self.step))

        try #require(kept.count == 5)
        #expect(Array(kept[1...3]) == Array(Self.line[1...3]))
        let first = try #require(kept.first)
        #expect(first.longitude.isApproximatelyEqual(to: 0.0005, absoluteTolerance: 1e-9))
        #expect(first.elevation?.isApproximatelyEqual(to: 505, absoluteTolerance: 0.001) == true)
        #expect(first.timestamp == Self.start.addingTimeInterval(30))
        let last = try #require(kept.last)
        #expect(last.longitude.isApproximatelyEqual(to: 0.00325, absoluteTolerance: 1e-9))
        #expect(last.elevation?.isApproximatelyEqual(to: 532.5, absoluteTolerance: 0.001) == true)
        #expect(last.timestamp == Self.start.addingTimeInterval(195))
        #expect(kept.lengthMeters.isApproximatelyEqual(to: 2.75 * Self.step, absoluteTolerance: 0.01))
    }

    @Test("a cut within half a metre of a point takes the point")
    func snapsToAPoint() {
        let kept = RouteTrim.trimmed(Self.line, keeping: (Self.step + 0.3)...(3 * Self.step - 0.3))

        #expect(kept == Array(Self.line[1...3]))
    }

    @Test("a made point has no height or time where an end of its leg has none")
    func madePointWithoutHeights() throws {
        let route = [Self.point(0, at: 0, elevation: 500), Self.point(2), Self.point(4, at: 240, elevation: 540)]

        let kept = RouteTrim.trimmed(route, keeping: Self.step...(3 * Self.step))

        try #require(kept.count == 3)
        #expect(kept[0].elevation == nil)
        #expect(kept[0].timestamp == nil)
        #expect(kept[2].elevation == nil)
        #expect(kept[2].timestamp == nil)
    }

    @Test("a made end is inferred where the leg it stands on was")
    func madeEndKeepsItsLegsProvenance() throws {
        let route = [Self.point(0), Self.point(2), Self.point(4, inferred: true)]

        let kept = RouteTrim.trimmed(route, keeping: 0...(3 * Self.step))

        #expect(try #require(kept.last).isInferred)
    }

    @Test("a new first point names no pause and no inference")
    func newFirstPointArrivesFromNowhere() throws {
        let route = [Self.point(0), Self.point(2, inferred: true), Self.point(4), Self.point(6)]

        let onAPoint = RouteTrim.trimmed(route, keeping: (2 * Self.step)...(6 * Self.step))
        let betweenPoints = RouteTrim.trimmed(route, keeping: Self.step...(6 * Self.step))

        #expect(try #require(onAPoint.first).provenance == nil)
        #expect(try #require(betweenPoints.first).provenance == nil)
        #expect(betweenPoints[1].isInferred, "the leg to the old second point is still the app's guess")
    }

    /// Out two steps, a pause that moved the hiker to step ten, on two more.
    private static let paused = [
        point(0, at: 0),
        point(1, at: 60),
        point(2, at: 120),
        point(10, at: 3600, resumed: true),
        point(11, at: 3660),
        point(12, at: 3720),
    ]

    @Test("a line cut at a pause ends on the fix before it")
    func endsBeforeAPause() {
        let kept = RouteTrim.trimmed(Self.paused, keeping: 0...(2 * Self.step))

        #expect(kept == Array(Self.paused[0...2]))
    }

    @Test("a line cut at a pause begins on the fix after it, and not as a pause")
    func beginsAfterAPause() throws {
        let kept = RouteTrim.trimmed(Self.paused, keeping: (2 * Self.step)...(4 * Self.step))

        try #require(kept.count == 3)
        #expect(kept[0].longitude == Self.paused[3].longitude)
        #expect(!kept[0].isPauseBoundary)
        #expect(Array(kept[1...]) == Array(Self.paused[4...]))
    }

    @Test("a pause between the cuts stays a pause")
    func keepsAPauseInside() {
        let kept = RouteTrim.trimmed(Self.paused, keeping: Self.step...(3 * Self.step))

        #expect(kept == Array(Self.paused[1...4]))
        #expect(kept.lengthMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
    }

    @Test("cuts that leave no line give nothing")
    func nothingLeft() {
        #expect(RouteTrim.trimmed(Self.line, keeping: Self.step...Self.step).isEmpty)
        #expect(RouteTrim.trimmed(Self.line, keeping: (Self.step + 0.1)...(Self.step + 0.2)).isEmpty)
        #expect(RouteTrim.trimmed([Self.point(0)], keeping: 0...10).isEmpty)
        #expect(RouteTrim.trimmed([], keeping: 0...10).isEmpty)
    }

    @Test("the recorded time is the gaps between stamped points, less a pause's")
    func recordedSeconds() {
        #expect(RouteTrim.recordedSeconds(of: Self.paused) == 240)
        #expect(RouteTrim.recordedSeconds(of: Self.line) == 240)
        #expect(RouteTrim.recordedSeconds(of: [Self.point(0), Self.point(1)]) == 0)
    }

    @Test("the distances are the route profile's own axis")
    func distancesMatchTheProfile() {
        let distances = RouteTrim.distances(along: Self.paused)

        #expect(distances == RouteProfile(route: Self.paused).distances)
        #expect(distances[2] == distances[3], "a paused leg has no length")
    }
}

// swiftlint:enable no_magic_numbers
