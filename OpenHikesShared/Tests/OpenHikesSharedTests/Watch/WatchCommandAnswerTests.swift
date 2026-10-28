//
//  WatchCommandAnswerTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("A command's answer on the watch")
struct WatchCommandAnswerTests {
    @Test(
        "a command that never reached the phone keeps the recording the phone last reported",
        arguments: [WatchPhoneRecording.State.recording, .paused]
    )
    func anUndeliveredCommandKeepsTheReading(state: WatchPhoneRecording.State) {
        let held = WatchPhoneRecording(state: state, elapsedSeconds: 600, updatedAt: Fixture.stamp)
        // Both ways PhoneLink fails to get an answer: a send error and a reply
        // that would not decode.
        for reason in ["That didn’t reach your iPhone.", "Your iPhone couldn’t answer that."] {
            let answer = WatchCommandAnswer.undelivered(commandID: Fixture.commandID, reason: reason)
            // The phone has not said it stopped, so the watch must not either:
            // an invented idle would hide the hike and let the watch start a
            // second recording of the same walk.
            #expect(answer.reading(holding: held) == held)
            #expect(answer.refusal == reason)
            #expect(answer.commandID == Fixture.commandID)
        }
    }

    @Test("a command that never reached the phone invents no reading where there was none")
    func anUndeliveredCommandInventsNothing() {
        let answer = WatchCommandAnswer.undelivered(
            commandID: Fixture.commandID,
            reason: "Your iPhone is out of range."
        )
        // "This watch has not been told" stays that, rather than becoming
        // "nothing is recording on your iPhone".
        #expect(answer.reading(holding: nil) == nil)
    }

    @Test("the phone's own answer replaces the reading, idle included")
    func thePhonesAnswerIsAuthoritative() {
        let held = WatchPhoneRecording(state: .recording, updatedAt: Fixture.stamp)
        let stopped = WatchPhoneRecording.idle(at: Fixture.stamp.addingTimeInterval(5))
        let answer = WatchCommandAnswer.answered(
            WatchCommandOutcome(commandID: Fixture.commandID, recording: stopped)
        )
        #expect(answer.reading(holding: held) == stopped)
        #expect(answer.reading(holding: nil) == stopped)
        #expect(answer.refusal == nil)
    }

    @Test("a refusal from the phone still carries the state the phone is in")
    func aPhoneRefusalCarriesItsState() {
        let running = WatchPhoneRecording(state: .recording, updatedAt: Fixture.stamp)
        let answer = WatchCommandAnswer.answered(
            WatchCommandOutcome(commandID: Fixture.commandID, recording: running, refusal: "Already recording.")
        )
        #expect(answer.reading(holding: .idle(at: Fixture.stamp.addingTimeInterval(-60))) == running)
        #expect(answer.refusal == "Already recording.")
    }

    @Test("an answer older than the reading already held is dropped")
    func anOlderAnswerLosesToANewerPush() {
        let pushed = WatchPhoneRecording(state: .paused, updatedAt: Fixture.stamp)
        let stale = WatchPhoneRecording(state: .recording, updatedAt: Fixture.stamp.addingTimeInterval(-1))
        let answer = WatchCommandAnswer.answered(WatchCommandOutcome(commandID: Fixture.commandID, recording: stale))
        #expect(answer.reading(holding: pushed) == pushed)
        // Equal stamps go to the arrival, as the model always took them.
        let same = WatchPhoneRecording(state: .recording, updatedAt: Fixture.stamp)
        #expect(same.reading(holding: pushed) == same)
    }

    private enum Fixture {
        static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        static let commandID = UUID(uuidString: "88888888-8888-8888-8888-888888888888") ?? UUID()
    }
}
