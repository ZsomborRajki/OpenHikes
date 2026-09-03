//
//  HikeIntentQueryTests.swift
//  OpenHikesTests
//
//  The reading half of the intents: what the last hike was, and what a day
//  adds up to.
//
//  These need no recorder at all — only a store with rows in it — so the one
//  they are handed never records anything. What they are actually pinning is
//  which rows count: a recording in progress owns a persisted row from the
//  moment it starts, and both questions have to look straight past it.
//

import Foundation
@testable import OpenHikes
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

    @Test("the last hike is the most recent finished one")
    func lastHikeIsTheMostRecent() throws {
        try insert(title: "Older", daysAgo: 3)
        try insert(title: "Newest", daysAgo: 1)
        try insert(title: "Middle", daysAgo: 2)

        #expect(try coordinator().lastFinishedHike().title == "Newest")
    }

    @Test("a recording in progress is not anybody's last hike")
    func aDraftIsNotTheLastHike() throws {
        try insert(title: "Finished", daysAgo: 1)
        try insert(title: "Being walked now", daysAgo: 0) { hike in
            hike.isRecording = true
        }

        #expect(try coordinator().lastFinishedHike().title == "Finished")
    }

    @Test("an empty store says so rather than inventing a hike")
    func anEmptyStoreIsReported() {
        #expect(throws: HikeIntentFailure.noHikesYet) {
            try coordinator().lastFinishedHike()
        }
    }

    @Test("a custom name is what gets reported, not the recorded title")
    func aRenamedHikeReportsItsName() throws {
        try insert(title: "2026-07-04 14:12", daysAgo: 1) { hike in
            hike.customName = "Kalvarienberg"
        }

        #expect(try coordinator().lastFinishedHike().title == "Kalvarienberg")
    }

    @Test("today's total adds up only today's hikes")
    func todaysTotalCoversToday() throws {
        try insert(title: "This morning", daysAgo: 0, distanceMeters: 4000)
        try insert(title: "Also today", daysAgo: 0, distanceMeters: 2500)
        try insert(title: "Yesterday", daysAgo: 1, distanceMeters: 9000)

        let totals = try coordinator().totalsForToday()

        #expect(totals.hikeCount == 2)
        #expect(totals.distance.value == 6500)
    }

    @Test("today's total excludes the recording still being walked")
    func todaysTotalExcludesADraft() throws {
        try insert(title: "Finished", daysAgo: 0, distanceMeters: 4000)
        try insert(title: "In progress", daysAgo: 0, distanceMeters: 1200) { hike in
            hike.isRecording = true
        }

        let totals = try coordinator().totalsForToday()

        #expect(totals.hikeCount == 1)
        #expect(totals.distance.value == 4000)
    }

    @Test("a hike just before midnight belongs to its own day")
    func theDayBoundaryIsTheCalendarDay() throws {
        // The last minute of yesterday, which a naive "twenty-four hours back"
        // window would count as today.
        try insert(title: "Late last night", secondsAgo: 60, distanceMeters: 3000)

        let totals = try coordinator().totalsForToday()

        #expect(totals.hikeCount == 0)
    }

    @Test("a day with nothing in it reports nothing rather than failing")
    func anEmptyDayIsAnAnswer() throws {
        try insert(title: "Last week", daysAgo: 7, distanceMeters: 8000)

        let totals = try coordinator().totalsForToday()

        #expect(totals.hikeCount == 0)
        #expect(totals.distance.value == 0)
    }

    // MARK: - Harness

    /// Midnight is the interesting boundary, so the clock is pinned just past
    /// it: `secondsAgo: 60` then lands in the previous calendar day.
    private lazy var now: Date = calendar.startOfDay(for: clock.now)
        .addingTimeInterval(30)

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

    /// Saved rather than merely inserted, and that is the point rather than
    /// bookkeeping: the coordinator answers every query through a *fresh*
    /// `ModelContext`, so a row left pending in this one is a row no intent can
    /// see. A test that skipped the save would be asserting against a store the
    /// app never has.
    private func insert(
        title: String,
        daysAgo: Int = 0,
        secondsAgo: TimeInterval = 0,
        distanceMeters: Double = 1000,
        configure: (Hike) -> Void = { _ in /* no-op */ }
    ) throws {
        let hike = Hike(title: title, distanceMeters: distanceMeters)
        context.insert(hike)
        hike.date = now
            .addingTimeInterval(-Double(daysAgo) * 24 * 3600)
            .addingTimeInterval(-secondsAgo)
        configure(hike)
        try context.save()
    }
}
