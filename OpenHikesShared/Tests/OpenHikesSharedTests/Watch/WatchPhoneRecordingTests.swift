//
//  WatchPhoneRecordingTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("The phone's recording on the watch")
struct WatchPhoneRecordingTests {
    @Test("a running walk hands the watch a clock to tick rather than a number")
    func aRunningWalkHasAnAnchor() throws {
        let recording = WatchPhoneRecording(
            state: .recording,
            elapsedSeconds: 600,
            updatedAt: Fixture.stamp
        )
        let anchor = try #require(recording.clockAnchor)
        // Ten minutes before the reading was taken, so a `Text(_:style:)`
        // handed this counts from the right place without another message.
        #expect(anchor == Fixture.stamp.addingTimeInterval(-600))
    }

    @Test("a paused walk has no clock to tick")
    func aPausedWalkHasNoAnchor() {
        let recording = WatchPhoneRecording(
            state: .paused,
            elapsedSeconds: 600,
            updatedAt: Fixture.stamp
        )
        // The whole point: a stopwatch running on a hike that is not running
        // is the one reading on this screen that would be a lie.
        #expect(recording.clockAnchor == nil)
    }

    @Test("idle is neither running nor paused, and carries no session")
    func idleCarriesNothing() {
        let recording = WatchPhoneRecording.idle(at: Fixture.stamp)
        #expect(!recording.isActive)
        #expect(recording.sessionID == nil)
        #expect(recording.clockAnchor == nil)
    }

    @Test("both active states read as active")
    func bothActiveStatesAreActive() {
        #expect(WatchPhoneRecording(state: .recording).isActive)
        #expect(WatchPhoneRecording(state: .paused).isActive)
    }

    @Test("an outcome carries a state whether or not the command worked")
    func anOutcomeAlwaysCarriesAState() {
        let refused = WatchCommandOutcome(
            commandID: Fixture.commandID,
            recording: WatchPhoneRecording(state: .recording),
            refusal: "That hike is already running."
        )
        // A hiker who asked to start a hike while one was already running
        // should see the hike that *is* running, not an error beside a blank
        // screen.
        #expect(refused.recording.isActive)
        #expect(refused.refusal != nil)

        let done = WatchCommandOutcome(
            commandID: Fixture.commandID,
            recording: .idle()
        )
        #expect(done.refusal == nil)
    }

    @Test("a command is distinguishable from the one before it")
    func commandsAreIdentified() {
        let first = WatchRecordingCommand(action: .pause)
        let second = WatchRecordingCommand(action: .pause)
        // Two taps on the same button are two commands, so the first reply
        // cannot update a screen the second has already moved on from.
        #expect(first.id != second.id)
    }

    private enum Fixture {
        static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        static let commandID = UUID(uuidString: "77777777-7777-7777-7777-777777777777") ?? UUID()
    }
}
