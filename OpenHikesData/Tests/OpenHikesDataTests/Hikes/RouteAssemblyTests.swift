//
//  RouteAssemblyTests.swift
//  OpenHikesDataTests
//
//  A saved recording's line rebuilt from its pieces: the same line while
//  every stretch stands as it was saved, the stretch's other points when its
//  answer changes, and the line there was when it changes back.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Route assembly")
struct RouteAssemblyTests {
    /// A point `step` thousandths of a degree north, `east` of them east.
    private static func point(_ step: Double, east: Double = 0, inferred: Bool = false) -> RouteCoordinate {
        RouteCoordinate(
            latitude: step / 1000,
            longitude: east / 1000,
            provenance: inferred ? .inferred : nil
        )
    }

    /// The trail, straight north: seven points.
    private static let saved = (0...6).map { point(Double($0)) }
    /// The fixes that were recorded, a little east of it.
    private static let raw = (0...6).map { point(Double($0), east: 0.3) }

    /// The stretch from the third point to the fifth was moved onto the
    /// trail, with the line either side left alone.
    private static let snapped = RouteAssembly(
        pieces: [.kept(0...2), .check(0), .kept(4...6)],
        checks: [RouteCheck(id: 0, kind: .snapped, savedChoice: .matched, savedRange: 2...4, rawRange: 2...4)]
    )

    @Test("with every stretch as it was saved, the line is the saved line")
    func asSaved() {
        let line = Self.snapped.line(saved: Self.saved, raw: Self.raw)

        #expect(line.route == Self.saved)
        #expect(line.checkRanges == [0: 2...4])
        #expect(Self.snapped.isAsSaved)
    }

    @Test("a stretch handed back to GPS is drawn with its fixes, between the line either side")
    func gpsStretch() {
        var assembly = Self.snapped
        assembly.checks[0].choice = .gps

        let line = assembly.line(saved: Self.saved, raw: Self.raw)

        // The trail up to the stretch, the three fixes, the trail after it:
        // where the two meet they are different places, so both are kept.
        #expect(line.route == Array(Self.saved[0...2]) + Array(Self.raw[2...4]) + Array(Self.saved[4...6]))
        #expect(line.checkRanges == [0: 3...5])
        #expect(!assembly.isAsSaved)
    }

    @Test("an answer changed and changed back gives the line there was")
    func thereAndBack() {
        var assembly = Self.snapped
        assembly.checks[0].choice = .gps
        assembly.checks[0].isChecked = true
        let back = assembly.asSaved

        #expect(back.line(saved: Self.saved, raw: Self.raw).route == Self.saved)
        #expect(back.checks[0].isChecked, "a look is kept when the answer goes back")
    }

    @Test("an ambiguous stretch takes one of its routes, and is its fixes otherwise")
    func alternative() {
        let detour = [Self.point(2), Self.point(3, east: -2), Self.point(4)]
        var assembly = RouteAssembly(
            pieces: [.kept(0...2), .check(4), .kept(4...6)],
            checks: [
                RouteCheck(
                    id: 4,
                    kind: .ambiguous,
                    savedChoice: .gps,
                    savedRange: 2...4,
                    rawRange: 2...4,
                    alternatives: [RouteCheck.Alternative(id: 1, points: detour)]
                ),
            ]
        )
        #expect(assembly.checks[0].availableChoices == [.gps, .alternative(1)])
        #expect(assembly.line(saved: Self.saved, raw: []).route == Self.saved)

        assembly.checks[0].choice = .alternative(1)
        let line = assembly.line(saved: Self.saved, raw: [])

        // The detour starts and ends where the line already is, so each of
        // those points is written once.
        #expect(line.route == [0, 1, 2].map { Self.point(Double($0)) } + [detour[1]] + Array(Self.saved[4...6]))
        #expect(line.checkRanges == [4: 2...4])

        assembly.checks[0].choice = .alternative(9)
        #expect(assembly.line(saved: Self.saved, raw: []).route == Self.saved, "a route it never had changes nothing")
    }

    @Test("a straight line across a gap is still a guess")
    func gapByGPS() throws {
        var assembly = RouteAssembly(
            pieces: [.kept(0...2), .check(0), .kept(4...6)],
            checks: [
                RouteCheck(
                    id: 0,
                    kind: .gap,
                    savedChoice: .matched,
                    savedRange: 2...4,
                    rawRange: 2...3,
                    unobservedSeconds: 900
                ),
            ]
        )
        assembly.checks[0].choice = .gps

        let line = assembly.line(saved: Self.saved, raw: Self.raw)

        let range = try #require(line.checkRanges[0])
        #expect(line.route[range.upperBound].isInferred)
        #expect(!line.route[range.lowerBound].isInferred)
    }

    @Test("a gap nothing crosses is a notice, with one way to draw it")
    func unbridgedGap() {
        let check = RouteCheck(
            id: 0,
            kind: .gap,
            savedChoice: .gps,
            savedRange: 2...3,
            rawRange: 2...3,
            isBridged: false
        )

        #expect(check.availableChoices == [.gps])
        #expect(!check.isQuestion)
    }

    @Test("two stretches that meet share the point they meet at")
    func adjacentChecks() {
        var assembly = RouteAssembly(
            pieces: [.check(0), .check(1), .kept(4...6)],
            checks: [
                RouteCheck(id: 0, kind: .snapped, savedChoice: .matched, savedRange: 0...2, rawRange: 0...2),
                RouteCheck(id: 1, kind: .snapped, savedChoice: .matched, savedRange: 2...4, rawRange: 2...4),
            ]
        )
        #expect(assembly.line(saved: Self.saved, raw: Self.raw).route == Self.saved)
        #expect(assembly.uncheckedCount == 2)

        assembly.checks[0].choice = .gps
        assembly.checks[0].isChecked = true
        let line = assembly.line(saved: Self.saved, raw: Self.raw)

        // No stray point of the trail before the first fix: the line begins
        // where the recording did.
        #expect(line.route == Array(Self.raw[0...2]) + Array(Self.saved[2...6]))
        #expect(line.checkRanges == [0: 0...2, 1: 3...5])
        #expect(assembly.uncheckedCount == 1)
    }

    @Test("it survives the trip through a record's field")
    func coding() throws {
        var assembly = Self.snapped
        assembly.checks[0].choice = .gps
        assembly.checks[0].trailName = "Soleleitungsweg"

        let decoded = try JSONDecoder().decode(RouteAssembly.self, from: JSONEncoder().encode(assembly))

        #expect(decoded == assembly)
    }

    @Test("a stretch naming points the line does not have draws nothing, and breaks nothing")
    func outOfRange() {
        let assembly = RouteAssembly(
            pieces: [.kept(0...2), .check(0), .kept(4...40)],
            checks: [RouteCheck(id: 0, kind: .snapped, savedChoice: .matched, savedRange: 20...24, rawRange: 2...4)]
        )

        let line = assembly.line(saved: Self.saved, raw: Self.raw)

        #expect(line.route == Array(Self.saved[0...2]))
        #expect(line.checkRanges.isEmpty)
    }

    @Test("a trace too short to hold a stretch leaves the stretch as it was saved")
    func aShortTraceLosesNothing() {
        var assembly = Self.snapped
        assembly.checks[0].choice = .gps

        let line = assembly.line(saved: Self.saved, raw: Array(Self.raw.prefix(2)))

        #expect(line.route == Self.saved)
        #expect(line.checkRanges[0] == 2...4)
    }
}

// swiftlint:enable no_magic_numbers
