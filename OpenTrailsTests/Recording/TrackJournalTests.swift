//
//  TrackJournalTests.swift
//  OpenTrailsTests
//

import Foundation
import Testing
@testable import OpenTrails

@Suite("Track journal")
struct TrackJournalTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "recording-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func point(_ index: Int) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + Double(index) * 0.0001,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(Double(index) * 10),
            elevation: 600 + Double(index),
            horizontalAccuracy: 8,
            course: 15,
            speed: 1.2,
            flags: index == 5 ? .resumed : []
        )
    }

    @Test("points and metadata round-trip through the fixed-width file")
    func roundTrip() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(start)
        let journal = TrackJournal(directory: directory, clock: clock.read)
        let sessionID = UUID()

        let options = RecordingSessionOptions(
            accuracyProfile: .balanced,
            snapToTrails: false,
            improveAccuracyOnline: false,
            keepRawGPSTrack: false
        )
        try await journal.start(
            sessionID: sessionID,
            startedAt: start,
            recordingOptions: options
        )
        for index in 0..<12 {
            clock.advance(by: 1)
            try await journal.append(point(index))
        }
        try await journal.flush()

        let session = try #require(try await journal.loadSession())
        #expect(session.metadata.sessionID == sessionID)
        #expect(session.metadata.recordingOptions == options)
        #expect(session.points.count == 12)
        #expect(abs(session.points[7].latitude - point(7).latitude) < 1e-12)
        #expect(session.points[5].flags.contains(.resumed))
        #expect(session.points[7].elevation == 607)

        let size = try FileManager.default.attributesOfItem(
            atPath: journal.journalURL.path
        )[.size] as? NSNumber
        #expect(
            size?.intValue
                == TrackJournal.headerByteCount
                    + 12 * TrackJournal.recordByteCount
        )
    }

    @Test("widget anchors merge once and retain their source flag")
    func widgetFixMerge() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TrackJournal(directory: directory)

        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.append(point(0))
        try await journal.flush()

        let nearDuplicate = RecordingPoint(
            latitude: 47.6301,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(3),
            horizontalAccuracy: 60,
            flags: [.widgetSourced]
        )
        let anchor = RecordingPoint(
            latitude: 47.631,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(30),
            horizontalAccuracy: 60,
            flags: [.widgetSourced]
        )

        #expect(
            try await journal.mergeWidgetFixes(
                [nearDuplicate, anchor]
            ) == 1
        )
        #expect(try await journal.mergeWidgetFixes([anchor]) == 0)

        let session = try #require(try await journal.loadSession())
        #expect(session.points.count == 2)
        #expect(session.points.last?.flags.contains(.widgetSourced) == true)
    }

    @Test("reading an open journal does not make a stale session recent")
    func loadingDoesNotRefreshMetadata() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(start)
        let journal = TrackJournal(directory: directory, clock: clock.read)

        try await journal.start(sessionID: UUID(), startedAt: start)
        let original = try #require(
            try await journal.loadSession()
        ).metadata.lastUpdatedAt
        clock.advance(by: 24 * 60 * 60)

        let reloaded = try #require(try await journal.loadSession())

        #expect(reloaded.metadata.lastUpdatedAt == original)
    }

    @Test("a torn tail record is ignored without losing complete points")
    func tornTailRecovery() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TrackJournal(directory: directory)

        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.append(point(0))
        try await journal.append(point(1))
        try await journal.flush()

        let handle = try FileHandle(forWritingTo: journal.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 13))
        try handle.close()

        let recovered = try #require(try await journal.loadSession())
        #expect(recovered.points.count == 2)
    }

    @Test("reopening truncates a torn tail before appending new points")
    func tornTailIsTruncatedBeforeResume() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TrackJournal(directory: directory)

        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.append(point(0))
        try await journal.append(point(1))
        try await journal.flush()

        let handle = try FileHandle(forWritingTo: journal.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 13))
        try handle.close()

        let recoveredJournal = TrackJournal(directory: directory)
        try await recoveredJournal.reopenForAppending()
        try await recoveredJournal.append(point(2))
        try await recoveredJournal.flush()

        let recovered = try #require(
            try await recoveredJournal.loadSession()
        )
        #expect(recovered.points.count == 3)
        for (actual, expected) in zip(
            recovered.points,
            [point(0), point(1), point(2)]
        ) {
            #expect(abs(actual.latitude - expected.latitude) < 1e-12)
            #expect(abs(actual.longitude - expected.longitude) < 1e-12)
            #expect(actual.timestamp == expected.timestamp)
            #expect(actual.elevation == expected.elevation)
            #expect(abs(actual.horizontalAccuracy - expected.horizontalAccuracy) < 0.001)
            #expect(abs((actual.course ?? 0) - (expected.course ?? 0)) < 0.001)
            #expect(abs((actual.speed ?? 0) - (expected.speed ?? 0)) < 0.001)
            #expect(actual.flags == expected.flags)
        }
    }

    @Test("pause intervals are completed when recording resumes")
    func pauseMetadata() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TrackJournal(directory: directory)

        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.pause(at: start.addingTimeInterval(60))
        try await journal.resume(at: start.addingTimeInterval(120))

        let session = try #require(try await journal.loadSession())
        let pause = try #require(session.metadata.pausedIntervals.first)
        #expect(pause.startedAt == start.addingTimeInterval(60))
        #expect(pause.endedAt == start.addingTimeInterval(120))
    }
}
