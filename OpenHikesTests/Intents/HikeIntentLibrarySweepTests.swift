//
//  HikeIntentLibrarySweepTests.swift
//  OpenHikesTests
//
//  The read under the launch sweep: every finished hike, as the reports
//  Spotlight indexes and the App Group's catalogue lists. Each report reads
//  its route for the clock, and a route is external storage decoded whole, so
//  *where* the read runs is the property worth pinning (#999). The two sweeps
//  that used to make it were started off the main actor and hopped straight
//  back onto it for the read, which put a library's worth of decoding on the
//  main thread at every launch, twice. Since #1025 the launch makes it once,
//  which `LaunchLibraryPublishTests` pins.
//
//  Asserted through the coordinator's read seam rather than a stopwatch, as
//  `CloudSyncCoordinatorTests` asserts its own hop: the fetch records the
//  thread it ran on, and the projection that decodes each route runs after
//  it in the same context.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Hike intent library sweep")
final class HikeIntentLibrarySweepTests {
    private struct ReadFailure: Error {}

    /// Which threads the hike fetch ran on, one entry per call.
    nonisolated final class FetchLog: Sendable {
        private let threads = Mutex<[Bool]>([])

        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func record() {
            threads.withLock { $0.append(Thread.isMainThread) }
        }
    }

    private let container: ModelContainer
    private let context: ModelContext
    // periphery:ignore - as in `HikeIntentCoordinatorTests`.
    private var recorder: HikeRecorder?
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    /// The bug was a hop, not a slow loop: `MainActor.run` around the read,
    /// from a task that had left the main actor to make it. So the caller here
    /// is the main actor itself, and a read that stays on its caller's
    /// executor fails.
    @Test("the whole-library read leaves the main thread, even for a main-actor caller")
    func theLibraryIsReadOffTheMainThread() async throws {
        // `pthread_main_np` rather than `Thread.isMainThread`, which Swift
        // makes unavailable from an `async` context.
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        try insertHike(title: "Thumsee Loop")
        let log = FetchLog()
        let reads = LibraryTotalsSweep.Reads(
            hikes: { context in
                log.record()
                return try LibraryTotalsSweep.Reads.store.hikes(context)
            },
            walks: LibraryTotalsSweep.Reads.store.walks
        )

        let reports = try await coordinator(reading: reads).finishedHikes()

        #expect(reports.map(\.title) == ["Thumsee Loop"])
        #expect(log.ranOnMainThread == [false])
    }

    /// What the read used to ask the store for — no drafts, newest first —
    /// and each clock off its route's own stamps, now that the read is the
    /// whole library walked into values.
    @Test("the read is the finished hikes, newest first, each timed by its route's stamps")
    func theReadIsTheFinishedHikesNewestFirst() async throws {
        try insertHike(title: "Older", daysAgo: 3, clockSeconds: 3600)
        try insertHike(title: "Being walked now", daysAgo: 0) { $0.isRecording = true }
        try insertHike(title: "Newest", daysAgo: 1, clockSeconds: nil)
        try insertHike(title: "Middle", daysAgo: 2, clockSeconds: 5400)

        let reports = try await coordinator().finishedHikes()

        #expect(reports.map(\.title) == ["Newest", "Middle", "Older"])
        #expect(reports.map(\.duration) == [nil, 5400, 3600])
    }

    /// A sweep that read nothing would replace the catalogue and the index
    /// with an empty library; failing is what leaves both as they were.
    @Test("a library that cannot be read fails the sweep rather than reading as empty")
    func anUnreadableLibraryIsAFailure() async throws {
        try insertHike(title: "Thumsee Loop")
        let reads = LibraryTotalsSweep.Reads(
            hikes: { _ in throw ReadFailure() },
            walks: LibraryTotalsSweep.Reads.store.walks
        )

        await #expect(throws: HikeIntentFailure.storage) {
            try await self.coordinator(reading: reads).finishedHikes()
        }
    }

    // MARK: - Harness

    private func coordinator(reading reads: LibraryTotalsSweep.Reads = .store) -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: StubRecordingLocationSource(),
            defaults: UserDefaults(
                suiteName: "hike-intent-library-sweep-\(UUID().uuidString)"
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
            clock: { [now] in now },
            libraryReads: reads
        )
    }

    /// Saved rather than inserted, for the reason ``HikeIntentQueryTests``
    /// gives: the coordinator answers through a fresh `ModelContext`.
    private func insertHike(
        title: String,
        daysAgo: Double = 0,
        clockSeconds: TimeInterval? = 3600,
        configure: (Hike) -> Void = { _ in /* no-op */ }
    ) throws {
        let start = now.addingTimeInterval(-daysAgo * 24 * 3600)
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: clockSeconds.map { _ in start }),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),
            RouteCoordinate(
                latitude: 47.65,
                longitude: 12.86,
                timestamp: clockSeconds.map { start.addingTimeInterval($0) }
            ),
            RouteCoordinate(latitude: 47.66, longitude: 12.86),
        ]
        let hike = Hike(title: title, distanceMeters: 1000, date: start, route: route)
        context.insert(hike)
        configure(hike)
        try context.save()
    }
}
