//
//  HikeIntentQueryTests.swift
//  OpenHikesTests
//
//  The reading half of the intents: what the last hike was. What a day adds
//  up to is `HikeIntentTotalsTests`'.
//
//  These need no recorder at all — only a store with rows in it — so the one
//  they are handed never records anything. What they are actually pinning is
//  which rows count: a recording in progress owns a persisted row from the
//  moment it starts, and the question has to look straight past it.
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

    // MARK: - Harness

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
        configure: (Hike) -> Void = { _ in /* no-op */ }
    ) throws {
        let hike = Hike(title: title, distanceMeters: 1000)
        context.insert(hike)
        hike.date = now.addingTimeInterval(-Double(daysAgo) * 24 * 3600)
        configure(hike)
        try context.save()
    }
}
