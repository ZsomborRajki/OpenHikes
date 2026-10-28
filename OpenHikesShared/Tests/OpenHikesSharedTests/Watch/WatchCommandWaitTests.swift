//
//  WatchCommandWaitTests.swift
//  OpenHikesSharedTests
//
//  An answer that lands after the press it answers has stopped waiting —
//  issue #1124. The watch has no test bundle, so the decision is here and
//  `WatchModel` only asks it.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("A button waiting on the phone")
struct WatchCommandWaitTests {
    @Test("the answer to the press waiting ends the wait and says why it was refused")
    func theMatchingAnswerEndsTheWait() throws {
        var wait = WatchCommandWait()
        let pause = try Fixture.press(.pause, id: Fixture.first, on: &wait)
        #expect(wait.pendingAction == .pause)

        let ended = wait.receive(Fixture.answer(to: pause, refusal: "Nothing is recording."))
        #expect(ended)
        #expect(wait.pending == nil)
        #expect(wait.refusal == "Nothing is recording.")
    }

    @Test("a second press is refused while the first is waiting")
    func aSecondPressWaitsForTheFirst() throws {
        var wait = WatchCommandWait()
        _ = try Fixture.press(.stop, id: Fixture.first, on: &wait)
        let refused = wait.press(.stop, id: Fixture.second)
        #expect(refused == nil)
        #expect(wait.pending?.id == Fixture.first)
    }

    @Test("a late success for an earlier press leaves the newer press waiting")
    func aLateSuccessKeepsTheNewerWait() throws {
        var wait = WatchCommandWait()
        let pause = try Fixture.press(.pause, id: Fixture.first, on: &wait)
        wait.phoneLost()
        let resume = try Fixture.press(.resume, id: Fixture.second, on: &wait)

        let ended = wait.receive(Fixture.answer(to: pause))
        #expect(!ended)
        // Resume is still unanswered, so its button stays marked and the
        // others disabled.
        #expect(wait.pending == resume)
        #expect(wait.refusal == nil)
    }

    @Test(
        "a late failure for an earlier press says nothing about the newer one",
        arguments: [true, false]
    )
    func aLateFailureKeepsTheNewerWait(fromThePhone: Bool) throws {
        var wait = WatchCommandWait()
        let pause = try Fixture.press(.pause, id: Fixture.first, on: &wait)
        wait.phoneLost()
        let resume = try Fixture.press(.resume, id: Fixture.second, on: &wait)

        // Either the phone's own refusal or the watch's failure to get one.
        let late: WatchCommandAnswer = fromThePhone
            ? Fixture.answer(to: pause, refusal: "Nothing is recording.")
            : .undelivered(commandID: pause.id, reason: "That didn’t reach your iPhone.")
        let lateEnded = wait.receive(late)
        #expect(!lateEnded)
        #expect(wait.pending == resume)
        #expect(wait.refusal == nil)

        // Resume's own answer still lands.
        let ownEnded = wait.receive(Fixture.answer(to: resume, refusal: "Already recording."))
        #expect(ownEnded)
        #expect(wait.pending == nil)
        #expect(wait.refusal == "Already recording.")
    }

    @Test("a late answer with nothing waiting changes nothing")
    func aLateAnswerWithNothingWaiting() throws {
        var wait = WatchCommandWait()
        let stop = try Fixture.press(.stop, id: Fixture.first, on: &wait)
        wait.phoneLost()

        let ended = wait.receive(Fixture.answer(to: stop, refusal: "Nothing is recording."))
        #expect(!ended)
        #expect(wait == WatchCommandWait())
    }

    @Test("an answer delivered twice after a reconnect ends only its own wait")
    func aDuplicateAnswerIsLate() throws {
        var wait = WatchCommandWait()
        let pause = try Fixture.press(.pause, id: Fixture.first, on: &wait)
        let answer = Fixture.answer(to: pause, refusal: "Nothing is recording.")
        let ended = wait.receive(answer)
        #expect(ended)
        wait.acknowledgeRefusal()

        // The copy lands with nothing waiting: the refusal the hiker read
        // does not come back.
        let copyEnded = wait.receive(answer)
        #expect(!copyEnded)
        #expect(wait.refusal == nil)

        // And it lands again with the next press waiting: that press keeps
        // its wait.
        let start = try Fixture.press(.start, id: Fixture.second, on: &wait)
        let laterCopyEnded = wait.receive(answer)
        #expect(!laterCopyEnded)
        #expect(wait.pending == start)
        #expect(wait.refusal == nil)
    }

    @Test("a press clears the refusal the last one earned")
    func aPressClearsTheOldRefusal() throws {
        var wait = WatchCommandWait()
        let pause = try Fixture.press(.pause, id: Fixture.first, on: &wait)
        wait.receive(.undelivered(commandID: pause.id, reason: "Your iPhone is out of range."))
        #expect(wait.refusal != nil)

        _ = try Fixture.press(.pause, id: Fixture.second, on: &wait)
        #expect(wait.refusal == nil)
    }

    private enum Fixture {
        static let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
        static let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        /// Presses through a helper, because `#require` cannot take a
        /// mutating call. An answer is received outside `#expect` for the
        /// same reason.
        static func press(
            _ action: WatchRecordingCommand.Action,
            id: UUID,
            on wait: inout WatchCommandWait
        ) throws -> WatchRecordingCommand {
            let command = wait.press(action, id: id)
            return try #require(command)
        }

        static func answer(to command: WatchRecordingCommand, refusal: String? = nil) -> WatchCommandAnswer {
            .answered(
                WatchCommandOutcome(
                    commandID: command.id,
                    recording: WatchPhoneRecording(state: .recording, updatedAt: stamp),
                    refusal: refusal
                )
            )
        }
    }
}
