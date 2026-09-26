//
//  WatchRecordingJournalBufferTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch recording journal cadence")
struct WatchRecordingJournalBufferTests {
    @Test("Fixes wait until there are enough of them")
    func fixesWaitForACount() {
        var buffer = WatchRecordingJournalBuffer()
        for step in 0..<(WatchRecordingJournalBuffer.maximumPendingFixes - 1) {
            #expect(buffer.add(.fix(Self.fix(seconds: Double(step))), at: Self.time(Double(step))).isEmpty)
        }
        let due = buffer.add(.fix(Self.fix(seconds: 20)), at: Self.time(20))
        #expect(due.count == WatchRecordingJournalBuffer.maximumPendingFixes)
        #expect(buffer.pending.isEmpty)
    }

    @Test("A fix does not wait longer than the interval")
    func fixesWaitForATime() {
        var buffer = WatchRecordingJournalBuffer()
        #expect(buffer.add(.fix(Self.fix(seconds: 0)), at: Self.time(0)).isEmpty)
        #expect(buffer.add(.fix(Self.fix(seconds: 10)), at: Self.time(10)).isEmpty)
        let interval = WatchRecordingJournalBuffer.maximumPendingSeconds
        let due = buffer.add(.fix(Self.fix(seconds: interval)), at: Self.time(interval))
        #expect(due.count == 3)
    }

    @Test("A pause is written at once, behind the fixes before it")
    func pauseFlushesInOrder() {
        var buffer = WatchRecordingJournalBuffer()
        let fix = WatchRecordingJournalEntry.fix(Self.fix(seconds: 0))
        _ = buffer.add(fix, at: Self.time(0))
        let due = buffer.add(.paused(Self.time(1)), at: Self.time(1))
        #expect(due == [fix, .paused(Self.time(1))])
    }

    @Test("The clock starts again after every write")
    func intervalRestartsAfterAWrite() {
        var buffer = WatchRecordingJournalBuffer()
        _ = buffer.add(.fix(Self.fix(seconds: 0)), at: Self.time(0))
        _ = buffer.add(.resumed(Self.time(1)), at: Self.time(1))
        #expect(buffer.add(.fix(Self.fix(seconds: 25)), at: Self.time(25)).isEmpty)
        #expect(buffer.drain().count == 1)
        #expect(buffer.drain().isEmpty)
    }

    private static func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private static func fix(seconds: TimeInterval) -> WatchRecordedFix {
        WatchRecordedFix(latitude: 47.55, longitude: 12.90, timestamp: time(seconds), horizontalAccuracy: 5)
    }
}
