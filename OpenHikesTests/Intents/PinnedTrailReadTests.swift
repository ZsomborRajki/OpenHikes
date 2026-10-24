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

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Pinned trail read")
final class PinnedTrailReadTests {
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

        let input = await SharedHikeCatalogPublisher.routeInput(
            for: hike.id,
            in: container,
            fetch: { context, hikeID in
                log.record()
                return try SharedHikeCatalogPublisher.fetchHike(context, hikeID)
            }
        )

        #expect(log.ranOnMainThread == [false])
        #expect(input?.hikeID == hike.id)
        #expect(input?.title == "Thumsee Loop")
        #expect(input?.route == Fixture.ridgeRoute)
    }

    /// A widget pinned to a hike deleted since it was configured: nothing to
    /// draw, and the prune after the sweep takes its file.
    @Test("a pinned hike that is gone reads as nothing")
    func aDeletedHikeReadsAsNothing() async {
        let input = await SharedHikeCatalogPublisher.routeInput(for: UUID(), in: container)

        #expect(input == nil)
    }
}
