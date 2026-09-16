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
}
