//
//  RouteStepsTests+Clock.swift
//  OpenHikesDataTests
//
//  The time a line keeps through its steps, and the steps that would make
//  nothing of it: a pause a new way draws over, a clock carried through a
//  step that clears it, and a line doubled back once too often.
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
}

// swiftlint:enable no_magic_numbers
