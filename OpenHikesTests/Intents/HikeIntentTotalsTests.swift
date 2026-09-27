//
//  HikeIntentTotalsTests.swift
//  OpenHikesTests
//
//  What "Distance Hiked Today" adds up (#751): the outings *Totals* counts,
//  placed on the day they were walked — not every `Hike` whose `date` falls
//  in the day. A trail drawn this morning has not been walked, and a walk
//  this morning along a trail saved last year has.
//
//  Which outings count is `LibraryTotalsTests`' to pin. These pin that the
//  intent reads through the same rules, and cuts the day at the hiker's own
//  midnight.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Hike intent totals")
final class HikeIntentTotalsTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let calendar = Calendar(identifier: .gregorian)
    // periphery:ignore - as in `HikeIntentCoordinatorTests`.
    private var recorder: HikeRecorder?

    /// Noon, so an hour either side of "now" stays inside today.
    private lazy var midnight: Date = calendar.startOfDay(for: .now)
    private lazy var now: Date = midnight.addingTimeInterval(12 * 3600)

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    @Test("a trail drawn today and never walked adds nothing")
    func anUnwalkedDrawingIsNotAHike() async throws {
        try insertHike(distanceMeters: 1112, clock: nil)

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 0)
        #expect(totals.distance.value == 0)
    }

    @Test("a trail saved from the community today adds nothing, clock or not")
    func aCommunityImportIsNotAHike() async throws {
        try insertHike(distanceMeters: 5000, clock: nil) { $0.importedFromListingID = "untimed" }
        try insertHike(distanceMeters: 7000, clock: (now, now.addingTimeInterval(3600))) { hike in
            hike.importedFromListingID = "timed"
        }

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 0)
    }

    @Test("a recording and a timed GPX walked today both count")
    func clockedHikesCount() async throws {
        try insertHike(distanceMeters: 4000, clock: (now.addingTimeInterval(-7200), now.addingTimeInterval(-3600)))
        try insertHike(distanceMeters: 2500, clock: (now.addingTimeInterval(-600), now))

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 2)
        #expect(totals.distance.value == 6500)
    }

    @Test("a recording still being walked is not counted")
    func aDraftIsNotCounted() async throws {
        try insertHike(distanceMeters: 4000, clock: (now.addingTimeInterval(-3600), now))
        try insertHike(distanceMeters: 1200, clock: (now.addingTimeInterval(-600), now)) { hike in
            hike.isRecording = true
        }

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 1)
        #expect(totals.distance.value == 4000)
    }

    @Test("a walk today along a trail saved long ago counts, by what it covered")
    func aWalkOnAnOlderTrailCounts() async throws {
        let longAgo = midnight.addingTimeInterval(-90 * 24 * 3600)
        let trail = try insertHike(distanceMeters: 8000, clock: nil, date: longAgo)
        try insertWalk(on: trail, from: now.addingTimeInterval(-3600), to: now, coveredMeters: 3000)

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 1)
        #expect(totals.distance.value == 3000)
    }

    @Test("a trail walked twice today is two hikes")
    func repeatedWalksAreEachCounted() async throws {
        let trail = try insertHike(distanceMeters: 2000, clock: nil)
        try insertWalk(
            on: trail, from: now.addingTimeInterval(-7200), to: now.addingTimeInterval(-5400), coveredMeters: 2000
        )
        try insertWalk(on: trail, from: now.addingTimeInterval(-3600), to: now, coveredMeters: 800)

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 2)
        #expect(totals.distance.value == 2800)
    }

    @Test("an afternoon recorded and followed at once counts once")
    func aFollowedRecordingCountsOnce() async throws {
        let trail = try insertHike(distanceMeters: 6000, clock: nil)
        try insertHike(distanceMeters: 5000, clock: (now.addingTimeInterval(-3600), now))
        try insertWalk(
            on: trail, from: now.addingTimeInterval(-3000), to: now.addingTimeInterval(-600), coveredMeters: 4000
        )

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 1)
        #expect(totals.distance.value == 5000)
    }

    @Test("a recording is placed by its first stamp, a walk by its start")
    func theDayBoundaryIsTheCalendarDay() async throws {
        // Started a minute before midnight and walked into today: yesterday's.
        // Ended before the walk below starts, so its clock takes nothing out.
        try insertHike(
            distanceMeters: 3000, clock: (midnight.addingTimeInterval(-60), midnight.addingTimeInterval(30))
        )
        // Saved yesterday, walked a minute after midnight: today's.
        let trail = try insertHike(distanceMeters: 2000, clock: nil, date: midnight.addingTimeInterval(-3600))
        try insertWalk(
            on: trail, from: midnight.addingTimeInterval(60), to: midnight.addingTimeInterval(1800), coveredMeters: 1500
        )

        let totals = try await coordinator().totalsForToday()

        #expect(totals.hikeCount == 1)
        #expect(totals.distance.value == 1500)
    }

    @Test("Siri and the Totals screen count the same outings")
    func agreesWithLibraryTotals() async throws {
        let trail = try insertHike(distanceMeters: 6000, clock: nil)
        try insertHike(distanceMeters: 1112, clock: nil)
        try insertHike(distanceMeters: 4000, clock: (now.addingTimeInterval(-7200), now.addingTimeInterval(-5400)))
        try insertWalk(on: trail, from: now.addingTimeInterval(-3600), to: now, coveredMeters: 2500)

        let totals = try await coordinator().totalsForToday()
        let library = try await LibraryTotalsSweep.read(from: container)
        let screen = LibraryTotals.Figures(LibraryTotals.outings(hikes: library.hikes, walks: library.walks))

        #expect(totals.hikeCount == screen.outings)
        #expect(totals.distance.value == screen.distanceMeters)
    }

    // MARK: - Harness

    private func coordinator() -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: StubRecordingLocationSource(),
            defaults: UserDefaults(
                suiteName: "hike-intent-totals-\(UUID().uuidString)"
            ) ?? .standard,
            powerMonitor: PowerStateMonitor(
                read: { PowerState() },
                observesNotifications: false
            ),
            journalDirectory: nil,
            automaticallyRecovers: false
        )
        recorder = instance
        return HikeIntentCoordinator(
            recorder: instance,
            container: container,
            calendar: calendar,
            clock: { [now] in now }
        )
    }

    /// A hike whose route carries `clock` as its first and last stamps, or
    /// no stamps at all — a drawn or planned line — when it is `nil`. Dated
    /// as the app dates it: by its first stamp, else by `date`.
    ///
    /// Saved, because the coordinator reads through a context of its own.
    @discardableResult private func insertHike(
        distanceMeters: Double,
        clock: (start: Date, end: Date)?,
        date: Date? = nil,
        configure: (Hike) -> Void = { _ in /* no-op */ }
    ) throws -> Hike {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: clock?.start),
            RouteCoordinate(latitude: 47.64, longitude: 12.86, timestamp: clock?.end),
        ]
        let hike = Hike(
            title: "Hike",
            distanceMeters: distanceMeters,
            date: clock?.start ?? date ?? now,
            route: route
        )
        context.insert(hike)
        configure(hike)
        try context.save()
        return hike
    }

    private func insertWalk(on trail: Hike, from start: Date, to end: Date, coveredMeters: Double) throws {
        context.insert(
            HikeWalk(
                hikeID: trail.id,
                startedAt: start,
                endedAt: end,
                activeSeconds: end.timeIntervalSince(start),
                coveredIntervals: [0, coveredMeters],
                furthestDistanceMeters: coveredMeters,
                routeDistanceMeters: trail.distanceMeters,
                endReason: .reachedEnd
            )
        )
        try context.save()
    }
}
