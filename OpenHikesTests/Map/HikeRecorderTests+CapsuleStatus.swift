//
//  HikeRecorderTests+CapsuleStatus.swift
//  OpenHikesTests
//
//  What the map's activity capsule's status draws while a recording is under
//  way: the recording while the capsule is shown, and nothing while it is
//  hidden. The status reads the distance per fix, and the capsule is hidden
//  for most of a recording, on the recording's own screen. See
//  ``MapActivityCapsuleControlsView/statusActivity``.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing
import UIKit

extension HikeRecorderTests {
    @Test("the capsule's status draws a recording only while the capsule is shown")
    func capsuleStatusStandsDownWhileHidden() async {
        let recorder = makeRecorder()
        let walk = TrailWalkSession(context: container.mainContext)
        let capsule = MapActivityCapsule(
            recorder: recorder,
            walk: walk,
            recordingStop: RecordingStopQuestion(recorder: recorder, endings: EventFeed()),
            walkEnd: WalkEndQuestion(session: walk, endings: EventFeed()),
            openRequests: HikeOpenRequests()
        )
        let host = MapActivityCapsuleControlsView(capsule: capsule)
        await recorder.start()

        host.apply(capsule.controls)
        #expect(host.statusActivity == .recording)
        #expect(host.statusButton?.isAccessibilityElement == true)

        host.isHidden = true
        #expect(host.statusActivity == nil, "a hidden capsule draws no figures")
        #expect(host.statusButton?.isAccessibilityElement == false, "and its status leaves VoiceOver and the tests")

        host.isHidden = false
        #expect(host.statusActivity == .recording, "and draws them again when it comes back")
        #expect(host.statusButton?.isAccessibilityElement == true)
    }

    /// The capsule stands down for VoiceOver the moment it is withdrawn,
    /// ahead of the fade that hides it — see `MapCoordinator+ActivityCapsule.swift`.
    @Test("a withdrawn capsule's status leaves accessibility before its fade is over")
    func capsuleStatusLeavesAccessibilityAtOnce() {
        let recorder = makeRecorder()
        let walk = TrailWalkSession(context: container.mainContext)
        let capsule = MapActivityCapsule(
            recorder: recorder,
            walk: walk,
            recordingStop: RecordingStopQuestion(recorder: recorder, endings: EventFeed()),
            walkEnd: WalkEndQuestion(session: walk, endings: EventFeed()),
            openRequests: HikeOpenRequests()
        )
        let host = MapActivityCapsuleControlsView(capsule: capsule)

        host.accessibilityElementsHidden = true
        #expect(host.statusButton?.isAccessibilityElement == false)

        host.accessibilityElementsHidden = false
        #expect(host.statusButton?.isAccessibilityElement == true)
    }
}
