//
//  MapActivityCapsuleTests.swift
//  OpenHikesTests
//
//  When the map's activity capsule stands for something: a recording or a
//  walk under way, wherever its own screen is not the one in front, and a
//  recording over a walk. See ``MapActivityCapsule``.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Map activity capsule")
struct MapActivityCapsuleTests {
    private let trail = UUID()
    private let other = UUID()

    @Test("nothing under way, no capsule")
    func nothingUnderWay() {
        #expect(activity() == nil)
        #expect(activity(hikeOnTop: trail) == nil)
    }

    @Test("a recording stands in the capsule on every screen but its own")
    func recordingAwayFromItsScreen() {
        #expect(activity(recordingLive: true) == .recording)
        #expect(activity(recordingLive: true, hikeOnTop: other) == .recording)
        #expect(activity(recordingLive: true, recordingOnTop: true) == nil, "its own bar holds the controls")
    }

    @Test("a walk stands in the capsule on every screen but its trail's")
    func walkAwayFromItsTrail() {
        #expect(activity(walkedHikeID: trail) == .walk(hikeID: trail))
        #expect(activity(walkedHikeID: trail, hikeOnTop: other) == .walk(hikeID: trail))
        #expect(activity(walkedHikeID: trail, hikeOnTop: trail) == nil, "its trail's bar holds the controls")
    }

    /// A hiker never has both, but every surface ranks them the same way —
    /// see *The app* in `AGENTS.md`.
    @Test("a recording outranks a walk")
    func recordingOutranksAWalk() {
        #expect(activity(recordingLive: true, walkedHikeID: trail, hikeOnTop: trail) == .recording)
        #expect(activity(recordingLive: true, recordingOnTop: true, walkedHikeID: trail) == nil)
    }

    @Test("Pause while a recording takes fixes, Resume while it is paused, neither otherwise")
    func pauseControlFollowsThePhase() {
        #expect(MapActivityCapsule.pause(for: .waitingForFix) == .pause)
        #expect(MapActivityCapsule.pause(for: .recording) == .pause)
        #expect(MapActivityCapsule.pause(for: .paused) == .resume)
        #expect(MapActivityCapsule.pause(for: .idle) == nil)
        #expect(MapActivityCapsule.pause(for: .recovering) == nil)
        #expect(MapActivityCapsule.pause(for: .saving) == nil)
        #expect(MapActivityCapsule.pause(for: .failed(.tooShort)) == nil)
    }

    private func activity(
        recordingLive: Bool = false,
        recordingOnTop: Bool = false,
        walkedHikeID: UUID? = nil,
        hikeOnTop: UUID? = nil
    ) -> MapActivityCapsule.Activity? {
        MapActivityCapsule.activity(
            recordingLive: recordingLive,
            recordingOnTop: recordingOnTop,
            walkedHikeID: walkedHikeID,
            hikeOnTop: hikeOnTop
        )
    }
}
