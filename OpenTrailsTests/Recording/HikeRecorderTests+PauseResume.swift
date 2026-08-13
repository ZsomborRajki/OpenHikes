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

private final class StubRecordingLocationSource: RecordingLocationSource {

extension HikeRecorderTests {

    @Test("batched Core Location delivery keeps every accepted fix")
    func batchedDeliveryIsRecordedInTimestampOrder() async {
        let recorder = makeRecorder()
        await recorder.start()
        let first = fix(latitude: 47.63)
        clock.advance(by: 10)
        let second = fix(latitude: 47.6302)

        source.deliver([second, first])
        await settleDelegateHop()

        #expect(recorder.stats.pointCount == 2)
    }

    @Test("a rejected weak fix still reports weak GPS signal")
    func rejectedWeakFixUpdatesAccuracyOnly() async {
        let recorder = makeRecorder()
        await recorder.start()

        source.deliver(
            fix(
                latitude: 47.63,
                accuracy:
                    RecordingFixPolicy.maximumHorizontalAccuracy + 450
            )
        )
        await settleDelegateHop()

        #expect(
            recorder.stats.horizontalAccuracy
                == RecordingFixPolicy.maximumHorizontalAccuracy + 450
        )
        #expect(recorder.stats.pointCount == 0)
        #expect(recorder.phase == .waitingForFix)
    }

    @Test("a lone accepted fix is flushed without waiting for ten points")
    func sparseFixesAreFlushedOnDeadline() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        for _ in 0..<16 { await Task.yield() }

        let journal = TrackJournal(directory: directory)
        let session = try #require(try await journal.loadSession())
        #expect(session.points.count == 1)
    }

    @Test("pause and resume do not add the distance crossed while paused")
    func pauseDoesNotBridgeGap() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        await settleDelegateHop()

        recorder.pause()
        clock.advance(by: 300)
        await recorder.resume()
        source.deliver(fix(latitude: 47.64))
        await settleDelegateHop()
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.641))
        await settleDelegateHop()

        let hike = try savedHike(from: await recorder.stop())
        #expect(abs(hike.distanceMeters - 222) < 5)
        #expect(hike.route.count == 4, "the drawn route remains continuous in v1")
    }

    @Test("reduced accuracy refuses to start a meaningless trace")
    func reducedAccuracyIsRefused() async {
        source.hasFullAccuracy = false
        let recorder = makeRecorder()

        await recorder.start()

        #expect(source.fullAccuracyRequests == 1)
        #expect(recorder.phase == .failed(.preciseLocationRequired))
        #expect(source.startCount == 0)
    }

    @Test("losing precise location pauses an active recording with an error")
    func preciseLocationRevokedMidRecording() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.hasFullAccuracy = false

        recorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await settleDelegateHop()

        #expect(recorder.phase == .failed(.preciseLocationRequired))
        #expect(source.stopCount == 1)
    }

    @Test("revoking location stops every active recording sensor")
    func locationRevokedMidRecording() async {
        let elevation = StubRecordingElevationSource()
        let recorder = makeRecorder(elevationSource: elevation)
        await recorder.start()
        source.authorization = .denied

        recorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await settleDelegateHop()

        #expect(recorder.phase == .failed(.locationDenied))
        #expect(source.stopCount == 1)
        #expect(elevation.stopCount >= 2)
    }

    @Test("a completed journal is saved on the next launch")
    func completedJournalIsRecovered() async throws {
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
        clock.advance(by: 10)
        try await journal.append(
            RecordingPoint(
                latitude: 47.6302,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(hikes.first?.id == sessionID)
        #expect(hikes.first?.isRecording == false)
        #expect(recorder.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: journal.journalURL.path))
    }
}
