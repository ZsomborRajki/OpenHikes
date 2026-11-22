//
//  RouteEditWorkoutTests.swift
//  OpenHikesTests
//
//  The workout Health holds for a hike whose line was edited: taken out and
//  written again from the line the hike has now, and only where this phone
//  wrote one and the hiker still wants hikes in Health.
//
//  Two workouts for one walk is what every path here must not leave, so the
//  order is asserted and not only the outcome.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@MainActor
@Suite("Route edit workout")
struct RouteEditWorkoutTests {
    private enum Line {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        static let pointCount = 11
        static let baseElevation: Double = 600
        static let climbPerPoint: Double = 5
    }

    private static let route: [RouteCoordinate] = (0..<Line.pointCount).map { index in
        RouteCoordinate(
            latitude: Line.latitude + Double(index) * Line.spacing,
            longitude: Line.longitude,
            elevation: Line.baseElevation + Double(index) * Line.climbPerPoint,
            timestamp: Line.start.addingTimeInterval(Double(index) * Line.secondsPerPoint)
        )
    }

    /// A hike this phone wrote to Health, with the switch still on.
    private struct Harness {
        let container: ModelContainer
        let hike: Hike
        let writer = StubWorkoutWriter()
        let queue = HikeWorkoutQueue()
        let defaults: UserDefaults

        var health: RouteEditWorkout.Health {
            health(writing: writer)
        }

        func health(writing writer: any HikeWorkoutWriting) -> RouteEditWorkout.Health {
            RouteEditWorkout.Health(writer: writer, queue: queue, container: container, defaults: defaults) { .idle }
        }

        init(savesToHealth: Bool = true, wroteToHealth: Bool = true) throws {
            container = try Fixture.modelContainer()
            hike = Fixture.hike(in: container.mainContext, route: RouteEditWorkoutTests.route)
            defaults = try #require(UserDefaults(suiteName: "RouteEditWorkoutTests-\(UUID().uuidString)"))
            defaults.set(savesToHealth, forKey: SettingsKey.savesHikesToHealth)
            if wroteToHealth {
                HikeLocalState.forHike(hike.id, in: container.mainContext).wroteToHealth = true
            }
            try container.mainContext.save()
        }
    }

    @Test("an edit takes the old workout out and writes one of the new line")
    func replacesTheWorkout() async throws {
        let harness = try Harness()
        let trimmed = Array(Self.route[0...6])

        await RouteEditWorkout.replace(
            of: harness.hike.id,
            with: trimmed,
            distanceMeters: 660,
            through: harness.health
        ).value

        #expect(harness.writer.deletedToReplace == [harness.hike.id])
        #expect(harness.writer.deleted.isEmpty, "a hike's own deletion can lose the workout")
        let request = try #require(harness.writer.written.first)
        #expect(harness.writer.written.count == 1)
        #expect(request.hikeID == harness.hike.id)
        #expect(request.startedAt == Line.start)
        #expect(request.endedAt == Line.start.addingTimeInterval(6 * Line.secondsPerPoint))
        #expect(request.pauses.isEmpty)
        #expect(request.distanceMeters == 660)
        #expect(request.elevationGainMeters?.isApproximatelyEqual(to: 30, absoluteTolerance: 0.01) == true)
        #expect(request.route == trimmed)
    }

    @Test("a workout that could not be taken out is not written a second time")
    func aFailedDeleteWritesNothing() async throws {
        let harness = try Harness()
        harness.writer.deleteFailure = .unavailable

        await RouteEditWorkout.replace(
            of: harness.hike.id,
            with: Array(Self.route[0...6]),
            distanceMeters: 660,
            through: harness.health
        ).value

        #expect(harness.writer.deletedToReplace == [harness.hike.id])
        #expect(harness.writer.written.isEmpty)
    }

    @Test("a line with no clock is no workout, and the one there is left alone")
    func aLineWithNoClock() async throws {
        let harness = try Harness()
        let unstamped = Self.route.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }

        await RouteEditWorkout.replace(
            of: harness.hike.id,
            with: unstamped,
            distanceMeters: 660,
            through: harness.health
        ).value

        #expect(harness.writer.deletedToReplace.isEmpty)
        #expect(harness.writer.written.isEmpty)
    }

    @Test("only a hike this phone wrote, and only while the switch is on")
    func whenAReplacementIsOwed() throws {
        let written = try Harness()
        let switchedOff = try Harness(savesToHealth: false)
        let neverWritten = try Harness(wroteToHealth: false)

        #expect(RouteEditWorkout.isOwed(for: written.hike, in: written.defaults))
        #expect(!RouteEditWorkout.isOwed(for: switchedOff.hike, in: switchedOff.defaults))
        #expect(!RouteEditWorkout.isOwed(for: neverWritten.hike, in: neverWritten.defaults))
    }

    @Test("saving a trim replaces the workout, once the save has landed")
    func aSavedTrimReplacesTheWorkout() async throws {
        let harness = try Harness()
        let session = RouteTrimSession()
        await session.load(Self.route)
        session.move(.end, to: session.totalMeters * 0.6)
        let destination = RouteTrimSession.Destination(
            hike: harness.hike,
            context: harness.container.mainContext,
            health: harness.health
        ) { Self.route }

        #expect(await session.save(to: destination))
        await session.workoutReplacement?.value

        #expect(harness.writer.deletedToReplace == [harness.hike.id])
        let request = try #require(harness.writer.written.first)
        #expect(request.route == harness.hike.route)
        #expect(request.distanceMeters == harness.hike.distanceMeters)
    }

    @Test("a cut saved with Reverse still comes off the workout, written from the line before it was turned")
    func aCutTurnedRound() async throws {
        let harness = try Harness()
        let session = RouteTrimSession()
        await session.load(Self.route)
        let kept = session.totalMeters * 0.6
        session.move(.end, to: kept)
        await session.reverse()
        let destination = RouteTrimSession.Destination(
            hike: harness.hike,
            context: harness.container.mainContext,
            health: harness.health
        ) { Self.route }

        #expect(await session.save(to: destination))
        await session.workoutReplacement?.value

        #expect(harness.hike.route.allSatisfy { $0.timestamp == nil }, "precondition: the hike's line has no clock")
        #expect(harness.writer.deletedToReplace == [harness.hike.id])
        let request = try #require(harness.writer.written.first)
        #expect(request.route == RouteTrim.trimmed(Self.route, keeping: 0...kept))
    }

    @Test("a cut made after Reverse comes off the workout too")
    func aCutAfterTurningRound() async throws {
        let harness = try Harness()
        let session = RouteTrimSession()
        await session.load(Self.route)
        await session.reverse()
        // Turned round, the start is the walk's end: four tenths of the line
        // off it leaves the walk's first six.
        session.move(.start, to: session.totalMeters * 0.4)
        let destination = RouteTrimSession.Destination(
            hike: harness.hike,
            context: harness.container.mainContext,
            health: harness.health
        ) { Self.route }

        #expect(await session.save(to: destination))
        await session.workoutReplacement?.value

        let request = try #require(harness.writer.written.first)
        #expect(request.route == Array(Self.route[0...6]))
        #expect(request.distanceMeters == harness.hike.distanceMeters)
    }

    @Test("a hike Health never held is saved without asking Health anything")
    func aSavedTrimWithNothingOwed() async throws {
        let harness = try Harness(wroteToHealth: false)
        let session = RouteTrimSession()
        await session.load(Self.route)
        session.move(.end, to: session.totalMeters * 0.6)
        let destination = RouteTrimSession.Destination(
            hike: harness.hike,
            context: harness.container.mainContext,
            health: harness.health
        ) { Self.route }

        #expect(await session.save(to: destination))

        #expect(session.workoutReplacement == nil)
        #expect(harness.writer.deletedToReplace.isEmpty)
        #expect(harness.writer.written.isEmpty)
    }

    /// A trim's workout still being written when the hiker comes back and
    /// reverts. Side by side, the revert deleted and wrote while the trim's
    /// write was held, and that write then landed beside it: two workouts.
    ///
    /// The last operation asked of the queue reads what Health has answered.
    /// It runs once the revert has finished if the revert took its turn, and
    /// as soon as the held write is let go if it did not.
    @Test("a revert waits for the trim's workout still being written")
    func replacementsTakeTurns() async throws {
        let harness = try Harness()
        let writer = HeldReplacementWriter()
        let health = harness.health(writing: writer)
        let trimmed = Array(Self.route[0...6])

        let trim = RouteEditWorkout.replace(of: harness.hike.id, with: trimmed, distanceMeters: 660, through: health)
        await writer.untilWriting()
        let revert = RouteEditWorkout.replace(
            of: harness.hike.id,
            with: Self.route,
            distanceMeters: 1100,
            through: health
        )
        let after = harness.queue.enqueue(for: harness.hike.id) { writer.note() }
        writer.finish()
        await after.value
        await trim.value
        await revert.value

        #expect(writer.noted == [.deleted, .wrote(trimmed), .deleted, .wrote(Self.route)])
    }
}

/// A writer whose first write is held until a suite lets it answer, and
/// which notes each call as it answers, so a call that started late but
/// answered early shows.
@MainActor
private final class HeldReplacementWriter: HikeWorkoutWriting {
    enum Answer: Equatable {
        case deleted
        case wrote([RouteCoordinate])
    }

    private(set) var answered: [Answer] = []
    /// What had answered when a suite last called ``note()``.
    private(set) var noted: [Answer] = []
    private var isHolding = true
    private var entered: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func write(_ request: HikeWorkoutRequest) async {
        if isHolding {
            isHolding = false
            hasEntered = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { held = $0 }
        }
        answered.append(.wrote(request.route))
    }

    func deleteWorkout(of hikeID: UUID) {
        Issue.record("an edit made a hike's deletion")
    }

    func deleteWorkoutToReplace(of hikeID: UUID) async {
        await Task.yield()
        answered.append(.deleted)
    }

    /// Returns once the first write has been entered and is waiting.
    func untilWriting() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entered = $0 }
    }

    /// Lets the held write answer.
    func finish() {
        held?.resume()
        held = nil
    }

    func note() {
        noted = answered
    }
}
