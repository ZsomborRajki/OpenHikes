//
//  TrackJournalBackdatedPauseTests.swift
//  OpenHikesTests
//
//  A pause counted from a moment already behind it (#1470): an auto-pause is
//  decided minutes into a stop, and the journal is cut back to where the stop
//  began, so that it reads as a pause by hand at that moment would have.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Track journal: a backdated pause")
struct TrackJournalBackdatedPauseTests {
    private static let secondsPerPoint: TimeInterval = 10

    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The point taken `index` tens of seconds into the walk.
    private func point(_ index: Int, flags: RecordingPointFlags = []) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + Double(index) * 0.0001,
            longitude: 12.86,
            timestamp: time(index),
            horizontalAccuracy: 8,
            flags: flags
        )
    }

    private func time(_ index: Int) -> Date {
        start.addingTimeInterval(Double(index) * Self.secondsPerPoint)
    }

    /// A journal holding points 0 to `count - 1`.
    private func journal(in directory: URL, points count: Int) async throws -> TrackJournal {
        let journal = TrackJournal(directory: directory, clock: TestClock(start).read)
        try await journal.start(sessionID: UUID(), startedAt: start)
        for index in 0..<count {
            try await journal.append(point(index))
        }
        return journal
    }

    @Test("the points after the stop began are taken back, and the pause starts there")
    func pointsAfterTheStopAreTakenBack() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await journal(in: directory, points: 12)

        try await journal.pause(at: time(7), discardingPointsAfter: time(7))

        let session = try #require(try await journal.loadSession())
        #expect(session.points.map(\.timestamp) == (0...7).map(time))
        #expect(session.metadata.pausedIntervals == [RecordingPauseInterval(startedAt: time(7), endedAt: nil)])
        let size = try FileManager.default.attributesOfItem(atPath: journal.journalURL.path)[.size] as? Int
        #expect(size == TrackJournal.headerByteCount + 8 * TrackJournal.recordByteCount)
    }

    /// The walk away is written behind the cut, where the stop's wander was.
    @Test("a point appended after the cut follows the last point kept")
    func appendingAfterTheCut() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await journal(in: directory, points: 12)

        try await journal.pause(at: time(7), discardingPointsAfter: time(7))
        try await journal.resume(at: time(40))
        try await journal.append(point(40, flags: .resumed))
        try await journal.append(point(41))
        try await journal.flush()

        let session = try #require(try await journal.loadSession())
        #expect(session.points.map(\.timestamp) == (0...7).map(time) + [time(40), time(41)])
        #expect(session.points[8].flags.contains(.resumed))
        #expect(session.metadata.pausedIntervals == [RecordingPauseInterval(startedAt: time(7), endedAt: time(40))])
    }

    /// A relaunch reads the same file, so its replay reaches the boundary the
    /// live recording showed.
    @Test("a journal reopened after a backdated pause reads as it was left")
    func reopenedJournal() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await journal(in: directory, points: 12)
        try await journal.pause(at: time(7), discardingPointsAfter: time(7))
        try await journal.close()

        let relaunched = TrackJournal(directory: directory, clock: TestClock(start).read)
        try await relaunched.reopenForAppending()
        let session = try #require(try await relaunched.loadSession())

        #expect(session.points.count == 8)
        #expect(session.metadata.pausedIntervals.last?.endedAt == nil)
    }

    /// A widget fix is merged whenever the app next looks, so it can sit
    /// behind points taken after it: the one record after the cut that is
    /// not itself after the stop began.
    @Test("a record behind the cut that is older than the stop is kept")
    func olderRecordBehindTheCut() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await journal(in: directory, points: 10)
        let late = RecordingPoint(
            latitude: 47.6301,
            longitude: 12.86,
            timestamp: time(3).addingTimeInterval(5),
            horizontalAccuracy: 20,
            flags: .widgetSourced
        )
        try await journal.append(late)
        try await journal.append(point(10))

        try await journal.pause(at: time(6), discardingPointsAfter: time(6))

        let session = try #require(try await journal.loadSession())
        #expect(session.points.map(\.timestamp) == (0...6).map(time) + [late.timestamp])
    }

    @Test("a stop that began after every point takes nothing back")
    func nothingToTakeBack() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await journal(in: directory, points: 5)

        try await journal.pause(at: time(9), discardingPointsAfter: time(9))

        let session = try #require(try await journal.loadSession())
        #expect(session.points.count == 5)
        #expect(session.metadata.pausedIntervals.first?.startedAt == time(9))
    }

    /// The widget samples while a recording is taking fixes, and for the
    /// first minutes of a stop it still is. Once the pause is counted from
    /// where the stop began, a fix the widget took since is the stop's.
    @Test("a widget fix taken inside a pause is not merged into the track")
    func widgetFixInsideAPause() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try await journal(in: directory, points: 12)
        try await journal.pause(at: time(7), discardingPointsAfter: time(7))
        func widgetFix(at date: Date) -> RecordingPoint {
            RecordingPoint(
                latitude: 47.6307,
                longitude: 12.86,
                timestamp: date,
                horizontalAccuracy: 20,
                flags: .widgetSourced
            )
        }

        let duringOpenPause = try await journal.mergeWidgetFixes([widgetFix(at: time(20))])
        try await journal.resume(at: time(40))
        let duringClosedPause = try await journal.mergeWidgetFixes([widgetFix(at: time(30))])
        let afterResume = try await journal.mergeWidgetFixes([widgetFix(at: time(50))])

        #expect(duringOpenPause == 0)
        #expect(duringClosedPause == 0)
        #expect(afterResume == 1)
    }

    @Test("a pause's two ends are outside it")
    func pauseIntervalEnds() {
        let pause = RecordingPauseInterval(startedAt: time(7), endedAt: time(40))
        let open = RecordingPauseInterval(startedAt: time(7), endedAt: nil)

        #expect(!pause.contains(time(7)))
        #expect(pause.contains(time(8)))
        #expect(!pause.contains(time(40)))
        #expect(open.contains(time(400)))
        #expect(!open.contains(time(6)))
    }
}
