//
//  WatchTrailAnswerTests.swift
//  OpenHikesTests
//
//  The phone's answer to a watch asking for a trail. The answer reads the
//  hike's route, which is external storage decoded whole, and it used to read
//  it inside `MainActor.run`: a stall on the phone in the hiker's hand for
//  every trail the watch asked for (#1025). So *where* the read runs is
//  pinned, through the fetch seam `PinnedTrailReadTests` uses, beside the two
//  answers that send nothing.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Synchronization
import Testing

@Suite("Answering a watch's trail request")
final class WatchTrailAnswerTests {
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

    /// The caller is the main actor itself, as the session coordinator is, so
    /// a read that stays on its caller's executor fails.
    @Test("the trail a watch asks for is read off the main thread, even for a main-actor caller")
    func theTrailIsReadOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let hike = Fixture.hike(in: context, title: "Thumsee Loop")
        try context.save()
        let request = WatchTrailRequest(hikeID: hike.id)
        let log = FetchLog()
        let asked = Date.now

        let package = await WatchTrailPackaging.answer(
            to: request,
            from: container,
            fetch: { context, hikeID in
                log.record()
                return try SharedHikeCatalogPublisher.fetchHike(context, hikeID)
            }
        )

        #expect(log.ranOnMainThread == [false])
        #expect(package?.hikeID == hike.id)
        #expect(package?.title == "Thumsee Loop")
        #expect(package?.requestID == request.id)
        // Stamped as the read began, which the watch orders two copies of
        // one trail by — see `WatchTrailPackaging.package(from:readAt:requestID:)`.
        #expect(package.map { $0.sentAt >= asked } == true)
    }

    /// A watch asking whether the copy it holds is still the phone's.
    @Test("a trail the watch already holds is not sent again")
    func aHeldTrailIsNotSentAgain() async throws {
        let hike = Fixture.hike(in: context)
        try context.save()
        let first = try #require(await WatchTrailPackaging.answer(
            to: WatchTrailRequest(hikeID: hike.id),
            from: container
        ))
        let held = try WatchLink.trailPackage(from: WatchLink.message(first))

        let again = await WatchTrailPackaging.answer(
            to: WatchTrailRequest(hikeID: hike.id, holding: held),
            from: container
        )

        #expect(again == nil)
    }

    /// A hike deleted since the watch's list was published: the watch draws
    /// its waiting state, and the next digest takes the row off its list.
    @Test("a hike that is gone answers nothing")
    func aDeletedHikeAnswersNothing() async {
        let package = await WatchTrailPackaging.answer(
            to: WatchTrailRequest(hikeID: UUID()),
            from: container
        )

        #expect(package == nil)
    }
}
