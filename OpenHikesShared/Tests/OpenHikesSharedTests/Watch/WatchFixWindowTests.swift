//
//  WatchFixWindowTests.swift
//  OpenHikesSharedTests
//
//  The window and the accumulator together, the way `WatchRecorder` puts them
//  together: a batch is sorted, each fix is asked of the window, and only what
//  it admits is offered to the accumulator. The recorder itself has no test
//  bundle to be driven from — see the repository instructions on the watch.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch fix window")
struct WatchFixWindowTests {
    @Test("A cached fix from before Start neither starts the walk nor lengthens it")
    func aCachedFixBeforeStartIsRefused() throws {
        var walk = WatchWalkAccumulator()
        let window = WatchFixWindow(opensAt: Fixture.start)
        // The issue's reproduction: an hour-old fix first, then the first real
        // one ten seconds into the recording, a kilometre north of it.
        let kept = Fixture.offer(
            [(0, -3600), (0.01, 10)],
            to: &walk,
            through: window
        )
        #expect(kept == 1)
        #expect(walk.fixes.allSatisfy { $0.timestamp >= Fixture.start })
        #expect(walk.activeSeconds == 0)
        #expect(walk.distanceMeters == 0)

        Fixture.offer([(0.0101, 20)], to: &walk, through: window)
        let recorded = try #require(
            walk.recordedWalk(
                sessionID: UUID(),
                startedAt: Fixture.start,
                endedAt: Fixture.start.addingTimeInterval(20)
            )
        )
        #expect(recorded.activeSeconds <= recorded.endedAt.timeIntervalSince(recorded.startedAt))
        #expect(recorded.distanceMeters < 20)
    }

    @Test("A batch that is all from before Start keeps nothing")
    func anAllCachedBatchKeepsNothing() {
        var walk = WatchWalkAccumulator()
        let kept = Fixture.offer(
            [(0, -600), (0.001, -300), (0.002, -1)],
            to: &walk,
            through: WatchFixWindow(opensAt: Fixture.start)
        )
        #expect(kept == 0)
        #expect(walk.fixes.isEmpty)
        #expect(
            walk.recordedWalk(
                sessionID: UUID(),
                startedAt: Fixture.start,
                endedAt: Fixture.start.addingTimeInterval(60)
            ) == nil
        )
    }

    @Test("A late batch taken during the recording is kept whole")
    func aDelayedBatchFromTheRecordingIsKept() {
        var walk = WatchWalkAccumulator()
        // Taken at 0 s to 40 s, delivered together whenever the screen next
        // woke — the timestamps are what the window reads, not the delivery.
        let kept = Fixture.offer(
            [(0, 0), (0.0001, 10), (0.0002, 20), (0.0003, 30), (0.0004, 40)],
            to: &walk,
            through: WatchFixWindow(opensAt: Fixture.start)
        )
        #expect(kept == 5)
        #expect(walk.activeSeconds == 40)
        #expect(walk.distanceMeters > 40 && walk.distanceMeters < 50)
    }

    @Test("A fix taken during a pause does not open the leg after it")
    func aFixFromThePauseIsRefusedAfterResume() {
        var walk = WatchWalkAccumulator()
        var window = WatchFixWindow(opensAt: Fixture.start)
        Fixture.offer([(0, 0), (0.0001, 10)], to: &walk, through: window)
        walk.pause()
        // Paused at 10 s, resumed at 600 s. The batch delivered after the
        // resume still holds a fix from 300 s, halfway through the pause.
        window.reopen(at: Fixture.start.addingTimeInterval(600))
        let kept = Fixture.offer(
            [(0.005, 300), (0.0051, 610), (0.0052, 620)],
            to: &walk,
            through: window
        )
        #expect(kept == 2)
        // Ten seconds before the pause and ten after the resume: the leg opens
        // at 610 s, so none of the pause is counted as walking.
        #expect(walk.activeSeconds == 20)
        #expect(walk.fixes.first(where: \.resumesAfterPause)?.timestamp == Fixture.start.addingTimeInterval(610))
    }

    @Test("A resume never reopens the window earlier than it already was")
    func reopeningNeverMovesBack() {
        var window = WatchFixWindow(opensAt: Fixture.start)
        window.reopen(at: Fixture.start.addingTimeInterval(-60))
        #expect(window.opensAt == Fixture.start)
        #expect(!window.admits(Fixture.start.addingTimeInterval(-1)))
        #expect(window.admits(Fixture.start))
    }

    private enum Fixture {
        static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        static let latitude = 47.0
        static let longitude = 12.0

        /// Offers a batch of `(degrees north of the fixture, seconds after
        /// Start)` fixes the way the recorder does, and returns how many
        /// were kept.
        @discardableResult static func offer(
            _ batch: [(north: Double, seconds: TimeInterval)],
            to walk: inout WatchWalkAccumulator,
            through window: WatchFixWindow
        ) -> Int {
            var kept = 0
            for fix in batch.sorted(by: { $0.seconds < $1.seconds }) {
                let timestamp = start.addingTimeInterval(fix.seconds)
                guard window.admits(timestamp) else { continue }
                let accepted = walk.accept(
                    latitude: latitude + fix.north,
                    longitude: longitude,
                    timestamp: timestamp,
                    horizontalAccuracy: 5
                )
                if accepted { kept += 1 }
            }
            return kept
        }
    }
}
