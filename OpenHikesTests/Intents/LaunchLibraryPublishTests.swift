//
//  LaunchLibraryPublishTests.swift
//  OpenHikesTests
//
//  The launch reads the library once and hands the one list to the App
//  Group's catalogue and to Spotlight. Each read fetches every hike into a
//  context of its own, and the two consumers used to make that read for
//  themselves from two detached tasks at once, so a launch held the library
//  twice, in two readings free to disagree (#1025).
//
//  Counted through the coordinator's read seam, `LibraryTotalsSweep.Reads`,
//  and asserted on what each consumer was handed. The consumers are injected
//  because the app's are the App Group, the watch link and the system's
//  Spotlight index, none of which a suite may touch.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Launch library publish")
final class LaunchLibraryPublishTests {
    private struct ReadFailure: Error {}

    /// How many times the library was fetched, and what each consumer got.
    nonisolated final class Log: Sendable {
        nonisolated struct Entries: Sendable {
            var reads = 0
            var catalogs: [[FinishedHikeReport]] = []
            var spotlights: [[FinishedHikeReport]] = []
        }

        private let entries = Mutex(Entries())

        var recorded: Entries { entries.withLock { $0 } }

        func record(_ change: @Sendable (inout Entries) -> Void) {
            entries.withLock { change(&$0) }
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

    @Test("the library is read once, and both consumers are handed that one list")
    func oneReadFeedsEveryConsumer() async throws {
        try insertHike(title: "Older", daysAgo: 2)
        try insertHike(title: "Newer", daysAgo: 1)
        let log = Log()

        await SharedHikeCatalogPublisher.publishLibrary(
            from: coordinator(reading: countingReads(into: log)),
            to: consumers(into: log)
        )

        let recorded = log.recorded
        #expect(recorded.reads == 1)
        #expect(recorded.catalogs.map { $0.map(\.title) } == [["Newer", "Older"]])
        #expect(recorded.spotlights == recorded.catalogs)
    }

    /// An empty list would replace the catalogue and the index with an empty
    /// library; a failed read must leave both as they were.
    @Test("a library that cannot be read reaches neither the catalogue nor Spotlight")
    func aFailedReadReachesNoConsumer() async throws {
        try insertHike(title: "Thumsee Loop")
        let log = Log()
        let failing = LibraryTotalsSweep.Reads(
            hikes: { _ in
                log.record { $0.reads += 1 }
                throw ReadFailure()
            },
            walks: LibraryTotalsSweep.Reads.store.walks
        )

        await SharedHikeCatalogPublisher.publishLibrary(
            from: coordinator(reading: failing),
            to: consumers(into: log)
        )

        let recorded = log.recorded
        #expect(recorded.reads == 1)
        #expect(recorded.catalogs.isEmpty)
        #expect(recorded.spotlights.isEmpty)
    }

    // MARK: - Harness

    private func countingReads(into log: Log) -> LibraryTotalsSweep.Reads {
        LibraryTotalsSweep.Reads(
            hikes: { context in
                log.record { $0.reads += 1 }
                return try LibraryTotalsSweep.Reads.store.hikes(context)
            },
            walks: LibraryTotalsSweep.Reads.store.walks
        )
    }

    private func consumers(into log: Log) -> SharedHikeCatalogPublisher.LibraryConsumers {
        SharedHikeCatalogPublisher.LibraryConsumers(
            catalog: { reports in log.record { $0.catalogs.append(reports) } },
            spotlight: { reports in log.record { $0.spotlights.append(reports) } }
        )
    }

    private func coordinator(reading reads: LibraryTotalsSweep.Reads) -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: StubRecordingLocationSource(),
            defaults: UserDefaults(
                suiteName: "launch-library-publish-\(UUID().uuidString)"
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

    /// Saved rather than inserted, because the coordinator answers through a
    /// fresh `ModelContext`.
    private func insertHike(title: String, daysAgo: Double = 0) throws {
        let start = now.addingTimeInterval(-daysAgo * 24 * 3600)
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.64, longitude: 12.86, timestamp: start.addingTimeInterval(1800)),
        ]
        context.insert(Hike(title: title, distanceMeters: 1000, date: start, route: route))
        try context.save()
    }
}
