//
//  PinnedTrailReadTests.swift
//  OpenHikesTests
//
//  The launch sweep's read of each trail a placed widget is pinned to. It
//  reads the hike's route, which is external storage decoded whole, and a
//  long recording is the likeliest thing to pin, so *where* the read runs is
//  the property worth pinning. It used to run inside `MainActor.run`, one
//  route-sized stall per pinned widget at every launch (#1025).
//
//  Asserted through the read's fetch seam, as `HikeIntentLibrarySweepTests`
//  asserts the library read: the fetch records the thread it ran on, and the
//  route decode runs after it in the same context.
//
//  The read also says *what* it found, because the sweep after it acts on
//  the difference: a hike that is gone loses its pin's snapshot and map, and
//  a read that failed keeps them (#1378). `PinnedTrailSweepTests` holds the
//  sweep to that.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Pinned trail read")
final class PinnedTrailReadTests {
    /// What a store that cannot answer throws.
    nonisolated struct Refusal: Error {}

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

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    /// The caller is the main actor itself, so a read that stays on its
    /// caller's executor fails.
    @Test("a pinned trail is read off the main thread, even for a main-actor caller")
    func thePinnedTrailIsReadOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let hike = Fixture.hike(in: context, title: "Thumsee Loop")
        try context.save()
        let log = FetchLog()

        let read = await SharedHikeCatalogPublisher.routeInput(
            for: hike.id,
            in: container,
            fetch: { context, hikeID in
                log.record()
                return try SharedHikeCatalogPublisher.fetchHike(context, hikeID)
            }
        )

        #expect(log.ranOnMainThread == [false])
        let input = try #require(read.input)
        #expect(input.hikeID == hike.id)
        #expect(input.title == "Thumsee Loop")
        #expect(input.route == Fixture.ridgeRoute)
    }

    /// A widget pinned to a hike deleted since it was configured: nothing to
    /// draw, and the prune after the sweep takes its file.
    @Test("a pinned hike that is gone reads as gone")
    func aDeletedHikeReadsAsGone() async {
        let read = await SharedHikeCatalogPublisher.routeInput(for: UUID(), in: container)

        guard case .gone = read else {
            Issue.record("a row the store does not hold must read as gone, not as \(read)")
            return
        }
    }

    /// A store that could not answer says nothing about the row, so the
    /// sweep must not hear it as a deletion and take a pinned widget's trail.
    @Test("a fetch that fails reads as a failure, not as a hike that is gone")
    func aFailedFetchIsNotADeletion() async throws {
        let hike = Fixture.hike(in: context, title: "Thumsee Loop")
        try context.save()

        let read = await SharedHikeCatalogPublisher.routeInput(
            for: hike.id,
            in: container,
            fetch: { _, _ in throw Refusal() }
        )

        guard case .failed = read else {
            Issue.record("a fetch that throws must read as failed, not as \(read)")
            return
        }
    }
}
