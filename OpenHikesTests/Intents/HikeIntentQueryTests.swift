//
//  HikeIntentQueryTests.swift
//  OpenHikesTests
//
//  The reading half of the intents: what the last hike was. What a day adds
//  up to is `HikeIntentTotalsTests`'.
//
//  The last hike is the latest outing *Totals* counts (#942), not the newest
//  row: a trail drawn or saved has not been walked, and a walk along a trail
//  saved long ago is dated by the trail. So these build libraries out of
//  recordings with a clock, plans without one and walks along saved trails,
//  and pin what is said back — whose name, how far, for how long, on which
//  day — rather than only which row sorts first. Which outings count at all
//  is `LibraryTotalsTests`' to pin.
//
//  These need no recorder at all — only a store with rows in it — so the one
//  they are handed never records anything.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Hike intent queries")
final class HikeIntentQueryTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let clock = TestClock()
    private let calendar = Calendar(identifier: .gregorian)
    // periphery:ignore - as in `HikeIntentCoordinatorTests`.
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    @Test("a plan saved after the last recording does not take its place")
    func aSavedPlanIsNotTheLastHike() async throws {
        let walked = daysAgo(1)
        try insertHike(title: "Kalvarienberg", distanceMeters: 4000, clock: (walked, walked.addingTimeInterval(3600)))
        try insertHike(title: "Unwalked plan", distanceMeters: 20_000, clock: nil, date: now)

        let last = try await coordinator().lastOuting()

        #expect(last.title == "Kalvarienberg")
        #expect(last.distance.value == 4000)
        #expect(last.duration == 3600)
        #expect(last.date == walked)
    }

    @Test("a walk along a trail saved long ago is the last hike, by what it covered")
    func aWalkOnAnOlderTrailIsTheLastHike() async throws {
        let trail = try insertHike(title: "Thumsee Loop", distanceMeters: 8000, clock: nil, date: daysAgo(90))
        let recorded = daysAgo(2)
        try insertHike(
            title: "Kalvarienberg", distanceMeters: 4000, clock: (recorded, recorded.addingTimeInterval(3600))
        )
        let walked = daysAgo(1)
        // A quarter of an hour of it paused: the time said is the walk's
        // active time, as its History row says it, not its wall clock.
        try insertWalk(
            on: trail, from: walked, to: walked.addingTimeInterval(3600), coveredMeters: 3000, activeSeconds: 2700
        )

        let last = try await coordinator().lastOuting()

        #expect(last.id == trail.id)
        #expect(last.title == "Thumsee Loop")
        #expect(last.distance.value == 3000)
        #expect(last.duration == 2700)
        #expect(last.date == walked)
    }

    @Test("the latest of a trail's walks is the one reported, whole or part")
    func theLatestOfRepeatedWalksIsReported() async throws {
        let trail = try insertHike(title: "Thumsee Loop", distanceMeters: 2000, clock: nil, date: daysAgo(30))
        let whole = daysAgo(3)
        try insertWalk(on: trail, from: whole, to: whole.addingTimeInterval(1800), coveredMeters: 2000)
        let part = daysAgo(1)
        try insertWalk(on: trail, from: part, to: part.addingTimeInterval(900), coveredMeters: 800)

        let last = try await coordinator().lastOuting()

        #expect(last.distance.value == 800)
        #expect(last.duration == 900)
        #expect(last.date == part)
    }

    @Test("the most recent of several recordings is reported, over its own clock")
    func theMostRecentRecordingIsReported() async throws {
        for (title, days) in [("Older", 3.0), ("Newest", 1.0), ("Middle", 2.0)] {
            let start = daysAgo(days)
            try insertHike(
                title: title, distanceMeters: days * 1000, clock: (start, start.addingTimeInterval(days * 3600))
            )
        }

        let last = try await coordinator().lastOuting()

        #expect(last.title == "Newest")
        #expect(last.distance.value == 1000)
        #expect(last.duration == 3600)
    }

    @Test("an afternoon recorded and followed at once is the recording")
    func aFollowedRecordingIsTheRecording() async throws {
        let trail = try insertHike(title: "Thumsee Loop", distanceMeters: 6000, clock: nil, date: daysAgo(30))
        let start = daysAgo(1)
        try insertHike(title: "Kalvarienberg", distanceMeters: 5000, clock: (start, start.addingTimeInterval(3600)))
        // Started after the recording, so newest-first would pick it — but
        // every minute of it is the recording's, and it is not an outing.
        try insertWalk(
            on: trail, from: start.addingTimeInterval(600), to: start.addingTimeInterval(3000), coveredMeters: 4000
        )

        let last = try await coordinator().lastOuting()

        #expect(last.title == "Kalvarienberg")
        #expect(last.distance.value == 5000)
    }

    @Test("a trail saved from the community is not the last hike, clock or not")
    func aCommunityTrailIsNotTheLastHike() async throws {
        let walked = daysAgo(1)
        try insertHike(title: "Kalvarienberg", distanceMeters: 4000, clock: (walked, walked.addingTimeInterval(3600)))
        let shared = (start: now, end: now.addingTimeInterval(3600))
        try insertHike(title: "Shared, timed", distanceMeters: 7000, clock: shared) { hike in
            hike.importedFromListingID = "timed"
        }
        try insertHike(title: "Shared, untimed", distanceMeters: 5000, clock: nil, date: now) { hike in
            hike.importedFromListingID = "untimed"
        }

        #expect(try await coordinator().lastOuting().title == "Kalvarienberg")
    }

    @Test("a library of plans alone says nothing has been walked, not that it is empty")
    func aLibraryOfPlansIsNotEmpty() async throws {
        try insertHike(title: "Drawn", distanceMeters: 12_000, clock: nil, date: daysAgo(2))
        try insertHike(title: "Shared", distanceMeters: 5000, clock: nil, date: now) { hike in
            hike.importedFromListingID = "untimed"
        }

        await #expect(throws: HikeIntentFailure.nothingWalkedYet) {
            try await coordinator().lastOuting()
        }
    }

    @Test("a recording in progress is not anybody's last hike")
    func aDraftIsNotTheLastHike() async throws {
        let walked = daysAgo(1)
        try insertHike(title: "Finished", distanceMeters: 4000, clock: (walked, walked.addingTimeInterval(3600)))
        let underWay = (start: now, end: now.addingTimeInterval(600))
        try insertHike(title: "Being walked now", distanceMeters: 1200, clock: underWay) { hike in
            hike.isRecording = true
        }

        #expect(try await coordinator().lastOuting().title == "Finished")
    }

    @Test("an empty store says so rather than inventing a hike")
    func anEmptyStoreIsReported() async {
        await #expect(throws: HikeIntentFailure.noHikesYet) {
            try await coordinator().lastOuting()
        }
    }

    @Test("a custom name is what gets reported, not the recorded title")
    func aRenamedHikeReportsItsName() async throws {
        let walked = daysAgo(1)
        try insertHike(
            title: "2026-07-04 14:12", distanceMeters: 4000, clock: (walked, walked.addingTimeInterval(3600))
        ) { hike in
            hike.customName = "Kalvarienberg"
        }

        #expect(try await coordinator().lastOuting().title == "Kalvarienberg")
    }

    // MARK: - Harness

    private lazy var now: Date = calendar.startOfDay(for: clock.now)
        .addingTimeInterval(12 * 3600)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 3600)
    }

    private func coordinator() -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: StubRecordingLocationSource(),
            defaults: UserDefaults(
                suiteName: "hike-intent-queries-\(UUID().uuidString)"
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
    /// Saved rather than merely inserted, and that is the point rather than
    /// bookkeeping: the coordinator answers every query through a *fresh*
    /// `ModelContext`, so a row left pending in this one is a row no intent can
    /// see. A test that skipped the save would be asserting against a store the
    /// app never has.
    @discardableResult private func insertHike(
        title: String,
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
            title: title,
            distanceMeters: distanceMeters,
            date: clock?.start ?? date ?? now,
            route: route
        )
        context.insert(hike)
        configure(hike)
        try context.save()
        return hike
    }

    /// A walk along `trail`, active for the whole of it unless told
    /// otherwise.
    private func insertWalk(
        on trail: Hike,
        from start: Date,
        to end: Date,
        coveredMeters: Double,
        activeSeconds: TimeInterval? = nil
    ) throws {
        context.insert(
            HikeWalk(
                hikeID: trail.id,
                startedAt: start,
                endedAt: end,
                activeSeconds: activeSeconds ?? end.timeIntervalSince(start),
                coveredIntervals: [0, coveredMeters],
                furthestDistanceMeters: coveredMeters,
                routeDistanceMeters: trail.distanceMeters,
                endReason: .reachedEnd
            )
        )
        try context.save()
    }
}
