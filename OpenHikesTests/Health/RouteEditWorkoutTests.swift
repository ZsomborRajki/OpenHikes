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
        let defaults: UserDefaults

        var health: RouteEditWorkout.Health {
            RouteEditWorkout.Health(writer: writer, container: container, defaults: defaults) { .idle }
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

        await RouteEditWorkout.replace(of: harness.hike.id, with: trimmed, distanceMeters: 660, through: harness.health)

        #expect(harness.writer.deleted == [harness.hike.id])
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
        )

        #expect(harness.writer.deleted == [harness.hike.id])
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
        )

        #expect(harness.writer.deleted.isEmpty)
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

        #expect(harness.writer.deleted == [harness.hike.id])
        let request = try #require(harness.writer.written.first)
        #expect(request.route == harness.hike.route)
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
        #expect(harness.writer.deleted.isEmpty)
        #expect(harness.writer.written.isEmpty)
    }
}
