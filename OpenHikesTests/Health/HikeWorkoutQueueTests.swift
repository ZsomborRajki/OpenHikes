//
//  HikeWorkoutQueueTests.swift
//  OpenHikesTests
//
//  One Health operation at a time for each hike, in the order asked, and no
//  hike waiting on another's.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Hike workout queue")
struct HikeWorkoutQueueTests {
    /// The second operation is asked for before the first is held up, so by
    /// the time the first is waiting the second would have run, had it not
    /// waited its turn.
    @Test("a hike's operations run one at a time, in the order they were asked")
    func oneAtATime() async {
        let queue = HikeWorkoutQueue()
        let gate = Gate()
        let log = Log()
        let hikeID = UUID()

        queue.enqueue(for: hikeID) {
            log.entries.append("first began")
            await gate.pass()
            log.entries.append("first ended")
        }
        let second = queue.enqueue(for: hikeID) { log.entries.append("second") }
        await gate.untilWaiting()
        #expect(log.entries == ["first began"])

        gate.open()
        await second.value
        #expect(log.entries == ["first began", "first ended", "second"])
    }

    @Test("another hike's operation does not wait for one held up", .timeLimit(.minutes(1)))
    func otherHikesDoNotWait() async {
        let queue = HikeWorkoutQueue()
        let gate = Gate()
        let log = Log()

        let held = queue.enqueue(for: UUID()) {
            await gate.pass()
            log.entries.append("held")
        }
        await gate.untilWaiting()
        await queue.enqueue(for: UUID()) { log.entries.append("other") }.value
        #expect(log.entries == ["other"])

        gate.open()
        await held.value
        #expect(log.entries == ["other", "held"])
    }

    @MainActor
    private final class Log {
        var entries: [String] = []
    }

    /// Holds whatever passes it until a suite opens it.
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var isWaiting = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var watcher: CheckedContinuation<Void, Never>?

        func pass() async {
            guard !isOpen else { return }
            isWaiting = true
            watcher?.resume()
            watcher = nil
            await withCheckedContinuation { waiter = $0 }
        }

        /// Returns once something is waiting at the gate.
        func untilWaiting() async {
            guard !isWaiting else { return }
            await withCheckedContinuation { watcher = $0 }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }
}
