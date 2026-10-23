//
//  HikeRecorderTests+ShutterPosition.swift
//  OpenHikesTests
//
//  A photo from the recording screen is pinned where the walk was when its
//  shutter fired, not where it is when Use Photo is tapped (#970). The
//  camera cannot run in a test, so these drive the half after it: fixes the
//  recorder really accepted, a shutter time like the one
//  ``CameraCaptureMetadata`` reads, and the pill's controller asked for a
//  filing the way `attachCapturedPhoto` asks.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

extension HikeRecorderTests {
    /// The recording screen's claim on the pill, made as `RecordingView`
    /// makes it.
    private func recordingScreenClaim(on recorder: HikeRecorder) throws -> PhotoCaptureController {
        let hike = try #require(recorder.currentHike)
        let controller = PhotoCaptureController()
        controller.attach(to: hike) { shutter in
            recorder.photoCoordinate(atShutter: shutter)
        }
        return controller
    }

    @Test("a photo handed over after later fixes keeps the place its shutter fired")
    func capturedPhotoKeepsItsShutterPosition() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let shutter = clock.now
        source.deliver(fix(latitude: 47.63))
        // The review screen stays up while the hiker walks on to B.
        for latitude in [47.6302, 47.6304, 47.6306] {
            clock.advance(by: 10)
            source.deliver(fix(latitude: latitude))
        }
        #expect(hikeRecorder.lastAcceptedPoint?.latitude == 47.6306)

        let filing = try #require(try recordingScreenClaim(on: hikeRecorder).currentSubject(shutter: shutter))

        let pinned = try #require(filing.coordinate)
        #expect(pinned.latitude.isApproximatelyEqual(to: 47.63, absoluteTolerance: 1e-7))
    }

    @Test("a photo the camera gave no time for is pinned at the latest fix")
    func capturedPhotoWithoutShutterUsesTheLatestFix() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        let filing = try #require(try recordingScreenClaim(on: hikeRecorder).currentSubject(shutter: nil))

        let pinned = try #require(filing.coordinate)
        #expect(pinned.latitude.isApproximatelyEqual(to: 47.6302, absoluteTolerance: 1e-7))
    }

    /// The pause is marked on the first fix after it, and the fixes before it
    /// are kept across the resume — so a photo from the first leg handed over
    /// on the second is still placed on the first.
    @Test("a photo from before a pause, handed over after it, stays on the first leg")
    func shutterBeforeAPauseSurvivesTheResume() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        let shutter = clock.now
        source.deliver(fix(latitude: 47.6302))

        hikeRecorder.pause()
        clock.advance(by: 900)
        await hikeRecorder.resume()
        source.deliver(fix(latitude: 47.64))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6402))

        let pinned = try #require(hikeRecorder.photoCoordinate(atShutter: shutter))
        #expect(pinned.latitude.isApproximatelyEqual(to: 47.6302, absoluteTolerance: 1e-7))
        #expect(
            hikeRecorder.photoCoordinate(atShutter: shutter.addingTimeInterval(450)) == nil,
            "the middle of a fifteen-minute pause is somewhere the walk never recorded"
        )
    }

    @Test("a new recording forgets the last one's fixes")
    func newRecordingStartsWithoutTheLastOnesFixes() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let shutter = clock.now
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        _ = try savedHike(from: await hikeRecorder.stop())

        clock.advance(by: 60)
        await hikeRecorder.start()

        #expect(hikeRecorder.recentFixes.points.isEmpty)
        #expect(hikeRecorder.photoCoordinate(atShutter: shutter) == nil)
    }

    /// A discarded recording is gone, and so is what it walked: a photo
    /// handed over afterwards has nothing of it to be placed by.
    @Test("a discarded recording forgets its fixes")
    func discardForgetsTheFixes() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let shutter = clock.now
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        await hikeRecorder.discard()

        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.recentFixes.points.isEmpty)
        #expect(hikeRecorder.photoCoordinate(atShutter: shutter) == nil)
    }

    /// Relaunching rebuilds the recorder's live state from the journal, the
    /// recent fixes included, so a shutter from before the relaunch is still
    /// placed by the walk rather than at its newest fix.
    @Test("a recovered recording places a shutter by the fixes it recovered")
    func recoveredFixesPlaceAnEarlierShutter() async throws {
        let shutter = clock.now
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: shutter)
        for latitude in [47.63, 47.6302, 47.6304] {
            try await journal.append(
                RecordingPoint(latitude: latitude, longitude: 12.86, timestamp: clock.now, horizontalAccuracy: 8)
            )
            clock.advance(by: 10)
        }
        try await journal.close()

        let hikeRecorder = makeRecorder()
        await hikeRecorder.recoverOpenSession()

        #expect(hikeRecorder.phase == .recording)
        let pinned = try #require(hikeRecorder.photoCoordinate(atShutter: shutter))
        #expect(pinned.latitude.isApproximatelyEqual(to: 47.63, absoluteTolerance: 1e-7))
    }
}
