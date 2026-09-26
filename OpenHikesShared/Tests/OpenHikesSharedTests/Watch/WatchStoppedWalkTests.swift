//
//  WatchStoppedWalkTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch stopped walk")
struct WatchStoppedWalkTests {
    @Test("A refused write keeps the walk, and a retry queues that same walk exactly once")
    func refusedWriteIsRetried() {
        let queue = Queue(refusing: 1)
        let walk = Fixture.walk()

        let stopped = WatchStoppedWalk.settle(walk, writing: queue.enqueue)
        #expect(stopped == .unsaved(walk))
        #expect(queue.walks.isEmpty)

        // Storage recovers; the hiker presses Retry, then presses it again
        // before the screen has caught up.
        let retried = stopped.retried(writing: queue.enqueue)
        let again = retried.retried(writing: queue.enqueue)

        #expect(retried == .saved(walk))
        #expect(again == .saved(walk))
        #expect(queue.walks.map(\.sessionID) == [Fixture.sessionID])
        #expect(queue.walks.first?.fixes == walk.fixes)
        #expect(queue.attempts == 2)
    }

    @Test("A retry that is refused again still holds the walk")
    func refusedRetryStillHolds() {
        let queue = Queue(refusing: 2)
        let stopped = WatchStoppedWalk.settle(Fixture.walk(), writing: queue.enqueue)
            .retried(writing: queue.enqueue)

        #expect(stopped == .unsaved(Fixture.walk()))
        #expect(stopped.holdsUnsavedWalk)
        #expect(queue.walks.isEmpty)
    }

    @Test("Only an unsaved walk holds off a new recording")
    func onlyUnsavedHolds() {
        let queue = Queue(refusing: 0)
        let saved = WatchStoppedWalk.settle(Fixture.walk(), writing: queue.enqueue)
        let tooShort = WatchStoppedWalk.settle(nil, writing: queue.enqueue)

        #expect(saved == .saved(Fixture.walk()))
        #expect(!saved.holdsUnsavedWalk)
        #expect(tooShort == .tooShort)
        #expect(!tooShort.holdsUnsavedWalk)
        // Nothing to write is not a write.
        #expect(queue.attempts == 1)
    }

    @Test("Retrying something that is not unsaved writes nothing")
    func retryWithoutUnsavedWalkWritesNothing() {
        let queue = Queue(refusing: 0)
        #expect(WatchStoppedWalk.tooShort.retried(writing: queue.enqueue) == .tooShort)
        #expect(WatchStoppedWalk.saved(Fixture.walk()).retried(writing: queue.enqueue) == .saved(Fixture.walk()))
        #expect(queue.attempts == 0)
    }

    /// A disk queue that refuses its first `refusing` writes, keyed by session
    /// the way `WatchStore` names its files.
    private final class Queue {
        private var refusalsLeft: Int
        private(set) var attempts = 0
        private var stored: [UUID: WatchRecordedWalk] = [:]

        init(refusing refusals: Int) { refusalsLeft = refusals }

        var walks: [WatchRecordedWalk] { Array(stored.values) }

        func enqueue(_ walk: WatchRecordedWalk) -> Bool {
            attempts += 1
            guard refusalsLeft == 0 else {
                refusalsLeft -= 1
                return false
            }
            stored[walk.sessionID] = walk
            return true
        }
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let sessionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID()

        static func walk() -> WatchRecordedWalk {
            let fixes = (0..<3).map { step in
                WatchRecordedFix(
                    latitude: 47.55 + Double(step) * 0.0001,
                    longitude: 12.90,
                    timestamp: start.addingTimeInterval(Double(step) * 8),
                    horizontalAccuracy: 5
                )
            }
            return WatchRecordedWalk(
                sessionID: sessionID,
                startedAt: start,
                endedAt: start.addingTimeInterval(16),
                distanceMeters: 22,
                activeSeconds: 16,
                fixes: fixes
            )
        }
    }
}
