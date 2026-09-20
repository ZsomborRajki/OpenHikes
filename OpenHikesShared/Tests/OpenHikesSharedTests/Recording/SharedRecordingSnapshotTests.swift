//
//  SharedRecordingSnapshotTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Recording snapshot")
struct SharedRecordingSnapshotTests {
    @Test("the live recording payload round trips across processes")
    func codableRoundTrip() throws {
        let snapshot = SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: 4200,
            pointCount: 1284,
            polyline: [
                .init(latitude: 47.63, longitude: 12.86),
                .init(latitude: 47.64, longitude: 12.87),
            ],
            isCapturingFixes: false
        )

        let decoded = try JSONDecoder().decode(
            SharedRecordingSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded == snapshot)
        #expect(decoded.title == "Recording Paused")
        #expect(decoded.statusText.contains("pts"))
    }

    /// The status line is a distance and a point count, and the Home Screen
    /// widget draws the distance as a chip — so the part it speaks is the
    /// count alone. The Lock Screen families draw the whole line and keep
    /// both. See `TrailWidgetSpeech`.
    @Test("the point count is separable from the distance beside it")
    func pointCountStandsAlone() {
        let snapshot = SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: 1400,
            pointCount: 320,
            polyline: []
        )

        #expect(snapshot.pointCountText == "320 pts")
        #expect(snapshot.statusText.hasSuffix(snapshot.pointCountText))
        #expect(snapshot.statusText.contains(WidgetFormat.length(meters: 1400)))
    }
}
