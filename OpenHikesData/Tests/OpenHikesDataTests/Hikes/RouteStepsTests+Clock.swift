//
//  RouteStepsTests+Clock.swift
//  OpenHikesDataTests
//
//  The time a line keeps through its steps, and the steps that would make
//  nothing of it: a pause a new way draws over, or one standing at the edge
//  of a stretch, a clock carried through a step that clears it, a cut inside
//  a way drawn with no times, and a line doubled back once too often.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

extension RouteStepsTests {
    /// The line, with a pause of eleven minutes between its fifth and sixth
    /// points: nine minutes walked in all.
    static let pausedLine: [RouteCoordinate] = (0...10).map { index in
        let paused = index >= 5 ? 600.0 : 0
        return point(Double(index), at: Double(index) * 60 + paused, resumed: index == 5)
    }

    // MARK: A pause under a new way

    @Test("a stretch drawn over a pause keeps the time it stood paused, as a pause where the stretch begins")
    func aPauseDrawnOver() throws {
        #expect(RouteTrim.recordedSeconds(of: Self.pausedLine) == 540, "precondition: nine minutes walked")
        let stretch = (Self.step * 3)...(Self.step * 6)

        let straightened = RouteSteps.applying(.replace(stretch, with: .straight), to: Self.pausedLine)

        #expect(RouteTrim.recordedSeconds(of: straightened) == 540, "the pause still leaves its time out")
        let pause = try #require(straightened.firstIndex(where: \.isPauseBoundary) as Int?)
        #expect(straightened.filter(\.isPauseBoundary).count == 1, "one pause, as there was")
        #expect(pause == 4, "standing on the point the stretch begins at")
        #expect(Self.places([straightened[pause]]) == Self.places([Self.pausedLine[3]]))
        #expect(straightened[pause].timestamp == Self.pausedLine[3].timestamp?.addingTimeInterval(660))
        // The pause stood still on the line; the straight way across is
        // ground, from the fourth point to the eighth.
        #expect(straightened.lengthMeters.isApproximatelyEqual(to: Self.step * 10, absoluteTolerance: 0.01))

        let around = RouteSteps.applying(.replace(stretch, with: Self.detour), to: Self.pausedLine)
        #expect(RouteTrim.recordedSeconds(of: around) == 540)
        let unpaused = RouteSteps.applying(.replace(stretch, with: .straight), to: Self.line)
        let paused = unpaused.contains(where: \.isPauseBoundary)
        #expect(!paused, "a stretch with no pause in it gets none")
    }

    // MARK: A clock carried

    @Test("the time a step takes off is carried through a step that clears the clock")
    func aClockCarried() {
        let taken = (Self.step * 3)...(Self.step * 6)

        let removed = RouteSteps.applying([.pause(taken)], to: Self.line)
        let removedThenTurned = RouteSteps.applying([.pause(taken), .reverse], to: Self.line)
        let closed = RouteSteps.applying([.closeLoop(.straight)], to: Self.line)

        #expect(removed.recordedSeconds == 420)
        #expect(RouteTrim.recordedSeconds(of: removedThenTurned.route) == 0, "precondition: the clock is gone")
        #expect(removedThenTurned.recordedSeconds == 420)
        #expect(closed.recordedSeconds == 600, "a way home nobody recorded adds no time")
        #expect(RouteSteps.applying([], to: Self.line).recordedSeconds == 600)
    }

    // MARK: Nothing to make

    @Test("a line that already ends where it began is not doubled back, across a pause that moved it or not")
    func noWayBackFromHome() {
        // Out along the equator and carried back home inside a pause.
        let home = Self.point(0.2, at: 3600, resumed: true)
        let carried = Self.line + [home]
        #expect(RouteShape.of(route: carried) == nil, "precondition: a pause that moved the walk leaves no shape")
        #expect(RouteSteps.endsMeet(carried))

        #expect(RouteSteps.applying(.outAndBack, to: carried) == carried)
        let twice = RouteSteps.applying([.outAndBack, .outAndBack], to: Self.line)
        #expect(twice.route.count == Self.line.count * 2 - 1)
        #expect(!twice.lastStepChangedLine)
        #expect(RouteSteps.applying([.outAndBack], to: Self.line).lastStepChangedLine)
    }

    @Test("steps never leave a line more than twice its points and the paths they carry")
    func aLineDoubledOnce() {
        let count = 7000
        let long = (0..<count).map { Self.point(Double($0) / 100) }
        let length = long.lengthMeters
        // Doubled back, then cut short of home, so it may be doubled again.
        let steps: [RouteStep] = [.outAndBack, .trim(0...(length * 2 - 500), endPauses: 0), .outAndBack]

        let applied = RouteSteps.applying(steps, to: long)

        #expect(RouteSteps.applying(Array(steps.prefix(2)), to: long).route == applied.route)
        #expect(!applied.lastStepChangedLine)
        #expect(applied.route.count <= RouteSteps.maximumPoints(from: count))
    }

    // MARK: A pause at the edge

    /// Five points walked, a ride inside a pause to forty steps east, and
    /// three points walked on from there.
    static let rideLine: [RouteCoordinate] = (0...4).map { point(Double($0), at: Double($0) * 60) }
        + [point(40, at: 2040, resumed: true)]
        + (41...43).map { point(Double($0), at: 2040 + Double($0 - 40) * 60) }

    @Test("a pause at the edge of a stretch stays on its side, so the ride is never drawn as walked ground")
    func aRideAtTheEdge() {
        let walked = Self.rideLine.lengthMeters
        #expect(walked.isApproximatelyEqual(to: Self.step * 7, absoluteTolerance: 0.01), "precondition")

        let afterTheRide = (Self.step * 4)...(Self.step * 6)
        let beforeTheRide = (Self.step * 2)...(Self.step * 4)
        let fromTheRide = RouteSteps.applying(.replace(afterTheRide, with: .straight), to: Self.rideLine)
        let toTheRide = RouteSteps.applying(.replace(beforeTheRide, with: .straight), to: Self.rideLine)

        #expect(fromTheRide.lengthMeters.isApproximatelyEqual(to: walked, absoluteTolerance: 0.01))
        #expect(toTheRide.lengthMeters.isApproximatelyEqual(to: walked, absoluteTolerance: 0.01))
        #expect(fromTheRide.filter(\.isPauseBoundary).count == 1)
        #expect(toTheRide.filter(\.isPauseBoundary).count == 1)

        // Driven to the trailhead inside a pause, then walked: a stretch from
        // the very start begins where the walk did.
        let driven = [Self.point(0, at: 0), Self.point(30, at: 1800, resumed: true)]
            + (31...33).map { Self.point(Double($0), at: 1800 + Double($0 - 30) * 60) }
        let redrawn = RouteSteps.applying(.replace(0...Self.step, with: .straight), to: driven)
        #expect(redrawn.lengthMeters.isApproximatelyEqual(to: Self.step * 3, absoluteTolerance: 0.01))
        #expect(Array(redrawn.prefix(2)) == Array(driven.prefix(2)), "the drive is still a pause")
    }

    // MARK: A way drawn with no times

    @Test("a cut or a stretch taken out inside a way drawn with no times takes off its share of the crossing")
    func aCutInsideAWayRound() throws {
        let around = (Self.step * 3)...(Self.step * 6)
        let detoured = RouteSteps.applying(.replace(around, with: Self.detour), to: Self.line)
        #expect(RouteTrim.recordedSeconds(of: detoured) == 600, "precondition")
        let distances = RouteTrim.distances(along: detoured)
        // From the fourth point, over the two of the way round, back to the
        // seventh: three minutes.
        let crossing = distances[6] - distances[3]
        let inside = distances[4] + 20

        let taken = RouteSteps.applying(.pause(inside...(inside + 20)), to: detoured)
        let cut = RouteSteps.applying(.trim(0...inside, endPauses: 0), to: detoured)

        let share = 180 * 20 / crossing
        #expect(RouteTrim.recordedSeconds(of: taken).isApproximatelyEqual(to: 600 - share, absoluteTolerance: 0.01))
        let kept = 180 + 180 * (inside - distances[3]) / crossing
        #expect(RouteTrim.recordedSeconds(of: cut).isApproximatelyEqual(to: kept, absoluteTolerance: 0.01))
        #expect(try #require(cut.last).isInferred, "the time is read, the point still a guess")
    }

    // MARK: What a step moves

    @Test("a stretch redrawn up to either end leaves the walk beginning and ending where it did")
    func aRedrawnEndIsNotMoved() {
        let toTheEnd = RouteSteps.applying([.replace((Self.step * 8)...Self.total, with: .straight)], to: Self.line)
        let fromTheStart = RouteSteps.applying([.replace(0...(Self.step * 2), with: Self.detour)], to: Self.line)

        #expect(toTheEnd.route.last?.isInferred == true, "precondition: the last leg is the guess")
        #expect(!toTheEnd.movesStart && !toTheEnd.movesEnd)
        #expect(!fromTheStart.movesStart && !fromTheStart.movesEnd)
    }

    @Test("the line a workout is written from is the one before its clock was taken away")
    func theClockedLine() {
        let cut = RouteStep.trim(0...(Self.step * 6), endPauses: 0)

        let cutThenTurned = RouteSteps.applying([cut, .reverse], to: Self.line)

        #expect(cutThenTurned.clockedRoute == RouteSteps.applying(cut, to: Self.line))
        #expect(RouteSteps.applying([cut], to: Self.line).clockedRoute.isEmpty)
        #expect(RouteSteps.applying([.reverse, cut], to: Self.line).clockedRoute == Self.line)
    }
}

// swiftlint:enable no_magic_numbers
