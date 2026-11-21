//
//  HikeIntentCoordinatorTests+Stop.swift
//  OpenHikesTests
//
//  Stop from Siri, Control Center and the watch, which asks what the
//  recording screen's Stop button asks first (#1535). The rule is
//  ``RecordingStopStep``'s, pinned in `RecordingStopTests.swift`. These hold
//  the coordinator to acting on it: a recording with a line is saved, one
//  with nothing in it is ended with no draft left, and one holding a place
//  is left running for the screen to ask about.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

extension HikeIntentCoordinatorTests {
    @Test("stopping saves the hike and reports what was walked")
    func stoppingSavesTheHike() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        walk()

        let stopped = try await coordinator.stopRecording()

        guard case .saved(let hike) = stopped else {
            Issue.record("A walk with a line was not saved: \(stopped)")
            return
        }
        #expect(hike.distance.value > 0)
        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            try await coordinator.currentRecording()
        }
        // Saved, not merely stopped: the row has to be in the store and no
        // longer flagged as a draft, which is what makes it the answer to
        // "what was my last hike".
        let saved = try await coordinator.lastOuting()
        #expect(saved.id == hike.id)
    }

    @Test("stopping nothing is refused")
    func stoppingWithoutARecordingIsRefused() async {
        let coordinator = makeCoordinator()

        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            try await coordinator.stopRecording()
        }
    }

    @Test("stopping a recording still finding GPS ends it")
    func stoppingARecordingWithNoFixEndsIt() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()

        let stopped = try await coordinator.stopRecording()

        #expect(stopped == .endedEmpty)
        #expect(recorder?.phase == .idle)
        #expect(try container.mainContext.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// One point is a place, not a line. Going straight to the save failed it
    /// as too short and left the draft running, where only the recording
    /// screen could end it.
    @Test("stopping a recording with one point ends it, with no draft left")
    func stoppingAOnePointRecordingEndsIt() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        source.deliver(fix(latitude: 47.63))
        #expect(recorder?.currentHike != nil, "the draft a failed save left behind")

        let stopped = try await coordinator.stopRecording()

        #expect(stopped == .endedEmpty)
        #expect(recorder?.phase == .idle)
        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            try await coordinator.currentRecording()
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The issue's own steps: started and stopped from Control Center before
    /// a second fix arrived.
    @Test("the control ends a recording stopped before its second fix")
    func controlEndsAnEmptyRecording() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.toggleHikeRecording(canPromptForLocation: false)
        source.deliver(fix(latitude: 47.63))

        let outcome = try await coordinator.toggleHikeRecording(canPromptForLocation: false)

        #expect(outcome == .completed)
        #expect(recorder?.phase == .idle)
        #expect(try container.mainContext.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The recording screen asks before a place goes with the recording, and
    /// Siri, the control and the watch cannot ask. So nothing is ended.
    @Test("a recording with a place on it is left running")
    func stoppingKeepsARecordingHoldingAPlace() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        source.deliver(fix(latitude: 47.63))
        let draft = try #require(recorder?.currentHike)
        try HikePlaceChange.add(
            TrailPlace(latitude: 47.63, longitude: 12.86, symbol: .viewpoint),
            to: draft,
            in: container.mainContext
        )

        await #expect(throws: HikeIntentFailure.recordingNeedsDiscardChoice) {
            try await coordinator.stopRecording()
        }

        #expect(recorder?.phase == .recording)
        #expect(recorder?.currentHike?.places.count == 1)
        #expect(source.stopCount == 0, "the GPS is still on")
    }

    @Test("a Stop while another is counting the walk's fixes is told to wait")
    func stoppingWhileAnotherStopCountsIsRefused() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        source.deliver(fix(latitude: 47.63))
        let counting = try #require(recorder)
        counting.isSettlingStop = true

        await #expect(throws: HikeIntentFailure.busyFinishing) {
            try await coordinator.stopRecording()
        }

        #expect(counting.phase == .recording)
    }
}
