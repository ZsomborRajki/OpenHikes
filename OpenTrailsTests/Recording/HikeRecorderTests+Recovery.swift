//
//  HikeRecorderTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
@testable import OpenTrails
import OpenTrailsShared
import SwiftData
import Testing

extension HikeRecorderTests {

    @Test("a completed ambiguous journal returns to review after relaunch")
    func ambiguousCompletedJournalRecoversIntoReview() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(
            sessionID: sessionID,
            startedAt: clock.now,
            recordingOptions: .defaults
        )
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        clock.advance(by: 720)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.864,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            )
        )
        await recorder.recoverOpenSession()

        #expect(recorder.phase == .reviewing)
        #expect(recorder.routeReview?.sections.count == 1)
        #expect(recorder.currentHike?.id == sessionID)
        #expect(recorder.currentHike?.isRecording == true)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(FileManager.default.fileExists(atPath: journal.journalURL.path))
        await recorder.discard()
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("an explicitly paused session stays paused after relaunch")
    func pausedSessionDoesNotAutoResume() async throws {
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.pause(at: clock.now)
        try await journal.close()

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        #expect(recorder.phase == .paused)
        #expect(recorder.currentHike?.isRecording == true)
        #expect(source.startCount == 0)
        guard case .needsDecision = recorder.recoveryState else {
            Issue.record("the recovered pause should be explained to the user")
            return
        }
    }

    @Test("a recent open session resumes after relaunch")
    func recentOpenSessionAutoResumes() async throws {
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        #expect(recorder.phase == .recording)
        #expect(recorder.recoveryState == .resumed)
        #expect(recorder.currentHike?.isRecording == true)
        #expect(source.startCount == 1)
        #expect(recorder.stats.pointCount == 1)
    }

    @Test("a stale open session waits for a recovery decision")
    func staleOpenSessionDoesNotAutoResume() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(
            sessionID: sessionID,
            startedAt: clock.now,
            recordingOptions: .defaults
        )
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()
        clock.advance(by: 24 * 60 * 60)

        let sharedStore = StubRecordingSharedStateStore()
        await sharedStore.setPendingFixes([
            SharedRecordingFix(
                sessionID: sessionID,
                latitude: 47.6302,
                longitude: 12.86,
                timestamp: clock.now.addingTimeInterval(-60),
                horizontalAccuracy: 50
            ),
        ])
        let recorder = makeRecorder(sharedStateStore: sharedStore)

        await recorder.recoverOpenSession()

        #expect(recorder.phase == .paused)
        #expect(recorder.currentHike?.id == sessionID)
        #expect(source.startCount == 0)
        #expect(recorder.stats.pointCount == 2)
        guard case .needsDecision(let summary) = recorder.recoveryState else {
            Issue.record("a stale session should require a recovery decision")
            return
        }
        #expect(summary.lastUpdatedAt == clock.now.addingTimeInterval(-86_400))
    }

    @Test("automatic recovery claims the journal before Start can replace it")
    func automaticRecoveryBlocksStart() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let recorder = makeRecorder(automaticallyRecovers: true)

        #expect(recorder.phase == .recovering)
        #expect(recorder.isActive)
        await recorder.start()
        for _ in 0..<100 where recorder.phase == .recovering {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.phase == .recording)
        #expect(recorder.stats.pointCount == 1)
        #expect(recorder.currentHike?.id == sessionID)
        let recovered = try #require(try await journal.loadSession())
        #expect(recovered.metadata.sessionID == sessionID)
        #expect(recovered.points.count == 1)
    }

    @Test("a second Stop cannot start another persistence operation")
    func stopIsNotReentrant() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: .empty,
                cachedGraphDelay: .milliseconds(100)
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let firstStop = Task { try await recorder.stop() }
        while recorder.phase != .saving {
            await Task.yield()
        }
        do {
            _ = try await recorder.stop()
            Issue.record("a second Stop should be refused while saving")
        } catch let failure as RecordingFailure {
            guard case .save = failure else {
                Issue.record("the second Stop returned the wrong failure")
                return
            }
        } catch {
            Issue.record("the second Stop returned an unexpected error")
            return
        }
        let hike = try savedHike(from: await firstStop.value)

        #expect(hike.route.count == 2)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(recorder.phase == .idle)
    }

    @Test("pending widget anchors are merged before recovery resumes")
    func pendingWidgetFixesMergeDuringRecovery() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let sharedStore = StubRecordingSharedStateStore()
        let widgetFix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.6302,
            longitude: 12.86,
            timestamp: clock.now.addingTimeInterval(20),
            horizontalAccuracy: 50
        )
        await sharedStore.setPendingFixes([widgetFix])
        let recorder = makeRecorder(sharedStateStore: sharedStore)

        await recorder.recoverOpenSession()

        #expect(recorder.phase == .recording)
        #expect(recorder.stats.pointCount == 2)
        #expect(recorder.trace.tail.count == 2)
        #expect(await sharedStore.removedIDs().contains(widgetFix.id))
        let recovered = try #require(try await journal.loadSession())
        #expect(recovered.points.count == 2)
        #expect(recovered.points.last?.flags.contains(.widgetSourced) == true)
    }

    @Test("recovery does not duplicate a hike saved before journal cleanup")
    func completedJournalRecoveryIsIdempotent() async throws {
        let sessionID = UUID()
        context.insert(
            Hike(
                title: "Already Saved",
                distanceMeters: 10,
                id: sessionID,
                route: Fixture.ridgeRoute
            )
        )
        try context.save()

        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        clock.advance(by: 720)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.864,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            )
        )
        await recorder.recoverOpenSession()

        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(hikes.first?.title == "Already Saved")
        #expect(recorder.phase == .idle)
        #expect(recorder.routeReview == nil)
        #expect(!FileManager.default.fileExists(atPath: journal.journalURL.path))
    }

    @Test("every recorder failure carries user-facing copy", arguments: [
        RecordingFailure.locationDenied,
        .preciseLocationRequired,
        .storageUnavailable,
        .storage("Disk full"),
        .tooShort,
        .save("Store unavailable"),
    ])
    func failuresAreExplained(_ failure: RecordingFailure) throws {
        #expect(!(try #require(failure.errorDescription)).isEmpty)
        #expect(!(try #require(failure.recoverySuggestion)).isEmpty)
    }
}
