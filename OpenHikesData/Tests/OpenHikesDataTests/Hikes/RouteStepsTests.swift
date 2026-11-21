//
//  RouteStepsTests.swift
//  OpenHikesDataTests
//
//  What *Edit Route* does to a line beyond its two cuts: a stretch drawn
//  along another path, straightened or taken out, and the whole line turned
//  round, started somewhere else, closed or doubled back.
//
//  What is defended is that a guess says it is one, that the ground nobody
//  touched keeps every point and every time it had, and that a step which
//  does not fit a line leaves the line alone.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Route steps")
struct RouteStepsTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// One thousandth of a degree of longitude on the equator.
    private static let step = RouteGeometry.distanceMeters(
        from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        to: CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
    )

    /// A point `longitude` thousandths of a degree along the equator, and
    /// `north` thousandths off it.
    private static func point(
        _ longitude: Double,
        north: Double = 0,
        at seconds: TimeInterval? = nil,
        resumed: Bool = false
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: north / 1000,
            longitude: longitude / 1000,
            timestamp: seconds.map(start.addingTimeInterval),
            boundary: resumed ? .paused : nil
        )
    }

    /// Eleven points a step apart, a minute between each.
    private static let line = (0...10).map { point(Double($0), at: Double($0) * 60) }
    private static let total = step * 10

    /// A way round to the north of the line, between its third and sixth
    /// steps.
    private static let detour = RoutePath([
        CLLocationCoordinate2D(latitude: 0.001, longitude: 0.004),
        CLLocationCoordinate2D(latitude: 0.001, longitude: 0.005),
    ])

    private static func places(_ route: [RouteCoordinate]) -> [[Double]] {
        route.map { [$0.latitude, $0.longitude] }
    }

    // MARK: A stretch

    @Test("a stretch drawn along another path is a guess, and the ground either side is as it was")
    func aStretchReplaced() {
        let route = RouteSteps.applying(.replace((Self.step * 3)...(Self.step * 6), with: Self.detour), to: Self.line)

        #expect(route.count == 4 + 2 + 5)
        #expect(Array(route[0...3]) == Array(Self.line[0...3]))
        #expect(Array(route[7...10]) == Array(Self.line[7...10]))
        #expect(Self.places(Array(route[4...5])) == [[0.001, 0.004], [0.001, 0.005]])
        #expect(route[4...5].allSatisfy { $0.isInferred && $0.timestamp == nil })
        // The leg back onto the line is the last of the guess.
        #expect(route[6].isInferred)
        #expect(route[6].timestamp == Self.line[6].timestamp)
        #expect(!route[3].isInferred)
        #expect(!route[7].isInferred)
        #expect(RouteTrim.recordedSeconds(of: route) == 600, "the hiker was walking for as long as it took to cross")
    }

    @Test("a stretch straightened is the two points either side of it, joined")
    func aStretchStraightened() {
        let route = RouteSteps.applying(.replace((Self.step * 3)...(Self.step * 6), with: .straight), to: Self.line)

        #expect(route == Array(Self.line[0...3]) + [Self.inferred(Self.line[6])] + Array(Self.line[7...10]))
    }

    private static func inferred(_ point: RouteCoordinate) -> RouteCoordinate {
        var guess = point
        guess.provenance = .inferred
        return guess
    }

    @Test("a stretch that begins and ends between points makes a point at each end, with its time")
    func aStretchBetweenPoints() {
        let route = RouteSteps.applying(.replace((Self.step * 2.5)...(Self.step * 6.5), with: .straight), to: Self.line)

        #expect(route.count == 3 + 1 + 1 + 4)
        let left = route[3]
        let rejoined = route[4]
        #expect(left.longitude.isApproximatelyEqual(to: 0.0025, absoluteTolerance: 1e-9))
        #expect(left.timestamp == Self.start.addingTimeInterval(150))
        #expect(rejoined.longitude.isApproximatelyEqual(to: 0.0065, absoluteTolerance: 1e-9))
        #expect(rejoined.timestamp == Self.start.addingTimeInterval(390))
        #expect(rejoined.isInferred)
    }

    @Test("a path that names the line's own points at its ends does not draw them twice")
    func aPathWithItsEnds() {
        let withEnds = RoutePath([
            Self.line[3].clCoordinate,
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0.004),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0.005),
            Self.line[6].clCoordinate,
        ])

        let route = RouteSteps.applying(.replace((Self.step * 3)...(Self.step * 6), with: withEnds), to: Self.line)

        let plain = RouteSteps.applying(.replace((Self.step * 3)...(Self.step * 6), with: Self.detour), to: Self.line)
        #expect(route == plain)
    }

    @Test("a stretch that reaches both ends leaves the two ends and the path between")
    func theWholeLineReplaced() {
        let route = RouteSteps.applying(.replace(0...Self.total, with: Self.detour), to: Self.line)

        #expect(route.count == 4)
        #expect(route.first == Self.line.first)
        #expect(route.last == Self.inferred(Self.line[10]))
    }

    @Test("a stretch taken out is a pause: no distance, no trail, and no time")
    func aStretchTakenOut() {
        let route = RouteSteps.applying(.pause((Self.step * 3)...(Self.step * 6)), to: Self.line)

        #expect(route.count == 4 + 5)
        #expect(route[4].isPauseBoundary)
        #expect(route[4].longitude == Self.line[6].longitude)
        #expect(!route[4].isInferred, "nobody has guessed where the hiker went: they were told not to ask")
        #expect(route.lengthMeters.isApproximatelyEqual(to: Self.step * 7, absoluteTolerance: 0.01))
        #expect(RouteTrim.recordedSeconds(of: route) == 420)
    }

    @Test("a stretch taken out of an end is a cut")
    func aStretchTakenOutOfAnEnd() {
        let fromTheStart = RouteSteps.applying(.pause(0...(Self.step * 3)), to: Self.line)
        let offTheEnd = RouteSteps.applying(.pause((Self.step * 6)...Self.total), to: Self.line)

        #expect(fromTheStart == RouteTrim.trimmed(Self.line, keeping: (Self.step * 3)...Self.total))
        #expect(offTheEnd == RouteTrim.trimmed(Self.line, keeping: 0...(Self.step * 6)))
        #expect(fromTheStart.allSatisfy { !$0.isPauseBoundary })
    }

    // MARK: The whole line

    @Test("a line turned round keeps its ground and loses its clock, and a pause stays on its leg")
    func turnedRound() {
        var paused = Self.line
        paused[5].boundary = .paused

        let route = RouteSteps.applying(.reverse, to: paused)

        #expect(Self.places(route) == Self.places(paused.reversed()))
        #expect(route.allSatisfy { $0.timestamp == nil })
        // The leg between the fourth and fifth steps, arrived at from the
        // other side.
        #expect(route.indices.filter { route[$0].isPauseBoundary } == [6])
        #expect(route.lengthMeters.isApproximatelyEqual(to: paused.lengthMeters, absoluteTolerance: 0.01))
        #expect(Self.places(RouteSteps.applying(.reverse, to: route)) == Self.places(paused))
        #expect(RouteSteps.applying(.reverse, to: route).indices.filter { index in
            RouteSteps.applying(.reverse, to: route)[index].isPauseBoundary
        } == [5])
    }

    /// A square with a side of four steps, walked from its south-west corner
    /// and back to it.
    private static let loop: [RouteCoordinate] = [
        point(0), point(2), point(4),
        point(4, north: 2), point(4, north: 4),
        point(2, north: 4), point(0, north: 4),
        point(0, north: 2), point(0),
    ].enumerated().map { index, corner in
        var stamped = corner
        stamped.timestamp = start.addingTimeInterval(Double(index) * 60)
        return stamped
    }

    @Test("a loop begun somewhere else is the same ground from there, closed, with no clock")
    func aLoopBegunElsewhere() throws {
        let length = Self.loop.lengthMeters

        let route = RouteSteps.applying(.startAt(Self.step * 4), to: Self.loop)

        #expect(route.count == Self.loop.count)
        let begun = try #require(route.first)
        let ended = try #require(route.last)
        #expect(Self.places([begun, ended]) == [[0, 0.004], [0, 0.004]])
        #expect(route.lengthMeters.isApproximatelyEqual(to: length, absoluteTolerance: 0.01))
        #expect(route.allSatisfy { $0.timestamp == nil })
        #expect(route.allSatisfy { !$0.isInferred })
    }

    @Test("the gap a loop left between its ends is a guess once it is in the middle of the line")
    func anOpenLoopBegunElsewhere() {
        let open = Array(Self.loop.dropLast()) + [Self.point(0, north: 0.5)]

        let route = RouteSteps.applying(.startAt(Self.step * 4), to: open)

        #expect(route.count == open.count + 1)
        let guesses = route.filter(\.isInferred)
        #expect(guesses.count == 1)
        #expect(Self.places(guesses) == [[0, 0]], "the leg from where the loop stopped to where it began")
    }

    @Test("a line is closed along a path, or straight, and a closed one is left alone")
    func closingALoop() throws {
        let home = try #require(Self.line.first)

        let straight = RouteSteps.applying(.closeLoop(.straight), to: Self.line)
        let round = RouteSteps.applying(.closeLoop(Self.detour), to: Self.line)

        #expect(straight.count == Self.line.count + 1)
        #expect(Array(straight.dropLast()) == Self.line)
        let closing = try #require(straight.last)
        #expect(Self.places([closing]) == Self.places([home]))
        #expect(straight.last?.isInferred == true)
        #expect(straight.last?.timestamp == nil)
        #expect(round.count == Self.line.count + 3)
        #expect(round.suffix(3).filter(\.isInferred).count == 3)
        #expect(RouteSteps.applying(.closeLoop(.straight), to: Self.loop) == Self.loop)
    }

    @Test("an out and back is the line and the same way back, which nobody recorded")
    func outAndBack() {
        let route = RouteSteps.applying(.outAndBack, to: Self.line)

        #expect(route.count == Self.line.count * 2 - 1)
        #expect(Array(route.prefix(Self.line.count)) == Self.line)
        #expect(Self.places(Array(route.suffix(Self.line.count))) == Self.places(Self.line.reversed()))
        #expect(route.suffix(Self.line.count - 1).allSatisfy { $0.isInferred && $0.timestamp == nil })
        #expect(route.lengthMeters.isApproximatelyEqual(to: Self.total * 2, absoluteTolerance: 0.01))
        #expect(RouteTrim.recordedSeconds(of: route) == 600)
    }

    // MARK: In order

    @Test("steps apply in the order they were made, each to the line the one before left")
    func stepsInOrder() {
        let cutThenTurned = RouteSteps.applying(
            [.trim(0...(Self.step * 6), endPauses: 0), .reverse],
            to: Self.line
        )
        let turnedThenCut = RouteSteps.applying(
            [.reverse, .trim(0...(Self.step * 6), endPauses: 0)],
            to: Self.line
        )

        #expect(Self.places(cutThenTurned.route) == Self.places(Self.line[0...6].reversed()))
        #expect(Self.places(turnedThenCut.route) == Self.places(Self.line[4...10].reversed()))
        #expect(RouteSteps.applying([], to: Self.line).route == Self.line)
    }

    @Test("a step says whether it moved where the hike begins and ends")
    func whichEndsMove() {
        func ends(_ steps: [RouteStep]) -> [Bool] {
            let applied = RouteSteps.applying(steps, to: Self.line)
            return [applied.movesStart, applied.movesEnd]
        }

        #expect(ends([.replace((Self.step * 3)...(Self.step * 6), with: Self.detour)]) == [false, false])
        #expect(ends([.pause((Self.step * 3)...(Self.step * 6))]) == [false, false])
        #expect(ends([.trim((Self.step * 2)...Self.total, endPauses: 0)]) == [true, false])
        #expect(ends([.trim(0...(Self.step * 6), endPauses: 0)]) == [false, true])
        #expect(ends([.pause(0...(Self.step * 3))]) == [true, false])
        #expect(ends([.reverse]) == [true, true])
        #expect(ends([.outAndBack]) == [false, true])
        #expect(ends([.closeLoop(.straight)]) == [false, true])
        #expect(ends([]) == [false, false])
    }

    @Test("a step that does not fit the line leaves the line as it was")
    func aStepThatDoesNotFit() {
        let beyond = (Self.total + 10)...(Self.total + 20)

        #expect(RouteSteps.applying(.replace(beyond, with: Self.detour), to: Self.line) == Self.line)
        #expect(RouteSteps.applying(.pause(beyond), to: Self.line) == Self.line)
        #expect(RouteSteps.applying(.pause(0...Self.total), to: Self.line) == Self.line, "that would leave no line")
        #expect(RouteSteps.applying(.startAt(0), to: Self.loop) == Self.loop)
        #expect(RouteSteps.applying(.startAt(Self.loop.lengthMeters), to: Self.loop) == Self.loop)
        #expect(RouteSteps.applying(.trim(beyond, endPauses: 0), to: Self.line) == Self.line)
        #expect(RouteSteps.applying(.reverse, to: [Self.line[0]]) == [Self.line[0]])
        let unmoved = RouteSteps.applying([.pause(beyond)], to: Self.line)
        #expect(!unmoved.movesStart && !unmoved.movesEnd)
    }

    // MARK: What travels

    @Test("steps are kept and read back as they were, and a path to a decimetre")
    func stepsRoundTrip() throws {
        let steps: [RouteStep] = [
            .trim(10...900, endPauses: 2),
            .replace(100...400, with: Self.detour),
            .pause(500...600),
            .reverse,
            .startAt(120),
            .closeLoop(.straight),
            .outAndBack,
        ]

        let read = try JSONDecoder().decode([RouteStep].self, from: JSONEncoder().encode(steps))

        #expect(read == steps)
        #expect(RouteSteps.pathCoordinateCount(of: steps) == 2)
        let fine = RoutePath([CLLocationCoordinate2D(latitude: 47.123456789, longitude: 12.987654321)])
        #expect(fine.flat == [47.123457, 12.987654])
        #expect(fine.count == 1)
        #expect(fine.points.first?.isInferred == true)
    }

    @Test("time with no stamp inside it is recorded time, unless a pause is inside it too")
    func recordedTimeAcrossUnstampedPoints() {
        let across = [Self.point(0, at: 0), Self.point(1), Self.point(2), Self.point(3, at: 180)]
        let paused = [Self.point(0, at: 0), Self.point(1), Self.point(2, resumed: true), Self.point(3, at: 180)]
        let backwards = [Self.point(0, at: 180), Self.point(1), Self.point(2, at: 0)]

        #expect(RouteTrim.recordedSeconds(of: across) == 180)
        #expect(RouteTrim.recordedSeconds(of: paused) == 0)
        #expect(RouteTrim.recordedSeconds(of: backwards) == 0)
        #expect(RouteTrim.recordedSeconds(of: [Self.point(0), Self.point(1)]) == 0)
    }
}

// swiftlint:enable no_magic_numbers
