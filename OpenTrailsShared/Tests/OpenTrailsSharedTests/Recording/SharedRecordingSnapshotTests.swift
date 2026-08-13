//
//  SharedRecordingSnapshotTests.swift
//  OpenTrailsSharedTests
//

import Foundation
@testable import OpenTrailsShared
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

@Suite("Pending recording fixes")
struct PendingRecordingFixStoreTests {
    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pending-recording-fixes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test("the widget file is capped and keeps the newest anchors")
    func cappedStore() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingRecordingFixStore(directory: directory)
        let sessionID = UUID()

        for index in 0..<205 {
            try store.append(
                SharedRecordingFix(
                    sessionID: sessionID,
                    latitude: 47.63,
                    longitude: 12.86,
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    horizontalAccuracy: 50
                )
            )
        }

        let fixes = try store.load()
        #expect(fixes.count == PendingRecordingFixStore.maximumEntryCount)
        #expect(fixes.first?.timestamp == Date(timeIntervalSince1970: 5))
        #expect(fixes.last?.timestamp == Date(timeIntervalSince1970: 204))
    }

    @Test("the app removes only fixes it folded into the journal")
    func selectiveRemoval() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingRecordingFixStore(directory: directory)
        let first = SharedRecordingFix(
            sessionID: UUID(),
            latitude: 47.63,
            longitude: 12.86,
            timestamp: .now,
            horizontalAccuracy: 30
        )
        let second = SharedRecordingFix(
            sessionID: UUID(),
            latitude: 47.64,
            longitude: 12.87,
            timestamp: .now,
            horizontalAccuracy: 30
        )
        try store.append(first)
        try store.append(second)

        try store.remove(ids: [first.id])

        #expect(try store.load() == [second])
    }

    @Test("widget location sampling is limited per recording session")
    func sampleGate() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingRecordingFixStore(directory: directory)
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let interval: TimeInterval = 15 * 60

        #expect(
            try store.claimSample(
                sessionID: sessionID,
                at: start,
                minimumInterval: interval
            )
        )
        #expect(
            try !store.claimSample(
                sessionID: sessionID,
                at: start.addingTimeInterval(interval - 1),
                minimumInterval: interval
            )
        )
        #expect(
            try store.claimSample(
                sessionID: sessionID,
                at: start.addingTimeInterval(interval),
                minimumInterval: interval
            )
        )

        try store.clear(sessionID: sessionID)

        #expect(
            try store.claimSample(
                sessionID: sessionID,
                at: start.addingTimeInterval(interval),
                minimumInterval: interval
            )
        )
    }

    @Test("Stop cleanup and widget append share one session transaction")
    func recordingStateTransaction() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingRecordingFixStore(directory: directory)
        let recordingURL = directory.appendingPathComponent(
            "recording-snapshot.json"
        )
        let sessionID = UUID()
        let snapshot = SharedRecordingSnapshot(
            sessionID: sessionID,
            startedAt: .now,
            distanceMeters: 100,
            pointCount: 10,
            polyline: [],
            isCapturingFixes: true
        )
        let fix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.63,
            longitude: 12.86,
            timestamp: .now,
            horizontalAccuracy: 50
        )

        try store.saveRecording(snapshot, to: recordingURL)
        #expect(
            try store.append(
                fix,
                validatingRecordingAt: recordingURL
            )
        )
        #expect(try store.load() == [fix])

        try store.clearRecordingState(
            recordingURL: recordingURL,
            sessionID: sessionID
        )

        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: recordingURL.path))
        #expect(
            try !store.append(
                fix,
                validatingRecordingAt: recordingURL
            )
        )
    }
}
