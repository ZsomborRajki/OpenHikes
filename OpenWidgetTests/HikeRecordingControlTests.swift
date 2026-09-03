//
//  HikeRecordingControlTests.swift
//  OpenWidgetTests
//
//  The control projects the app's shared recording payload rather than
//  keeping a second recording flag of its own.
//

import Foundation
import OpenHikesShared
import Testing

@Suite("Hike recording control")
struct HikeRecordingControlTests {
    @Test("no shared recording offers start")
    func missingSnapshotIsIdle() {
        #expect(HikeRecordingControlState(snapshot: nil) == .idle)
    }

    @Test("an active shared recording offers stop")
    func activeSnapshotIsRecording() {
        #expect(
            HikeRecordingControlState(
                snapshot: Self.snapshot(isCapturingFixes: true)
            ) == .recording
        )
    }

    @Test("a paused shared recording still offers stop")
    func pausedSnapshotIsRecording() {
        #expect(
            HikeRecordingControlState(
                snapshot: Self.snapshot(isCapturingFixes: false)
            ) == .recording
        )
    }

    private static func snapshot(
        isCapturingFixes: Bool
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: 1200,
            pointCount: 12,
            polyline: [],
            isCapturingFixes: isCapturingFixes,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_100)
        )
    }
}
