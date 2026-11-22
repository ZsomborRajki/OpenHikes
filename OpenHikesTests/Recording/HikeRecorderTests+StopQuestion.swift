//
//  HikeRecorderTests+StopQuestion.swift
//  OpenHikesTests
//
//  The question both of a recording's Stops ask — the bar's and the map
//  capsule's — read off a real recording: what it asks, what it opens the
//  name field with, and what it sends when the recording ends. The rule it
//  asks by is ``RecordingStopStep``'s, pinned in `RecordingStopTests.swift`
//  and `HikeRecorderTests+Stop.swift`. See ``RecordingStopQuestion``.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension HikeRecorderTests {
    @Test("Stop ends a recording with nothing in it, asks nothing, and says it went")
    func stopQuestionEndsAnEmptyRecording() async throws {
        let recorder = makeRecorder()
        let endings = EventFeed<ActivityEnding>()
        let sent = FeedReader(endings.events())
        let question = RecordingStopQuestion(recorder: recorder, endings: endings)
        await recorder.start()
        let draftID = try #require(recorder.currentHike?.id)

        await question.ask()

        #expect(recorder.phase == .idle)
        #expect(!question.isAskingName)
        #expect(!question.isConfirmingDiscard)
        await settleDelegateHop(until: "the discard to be sent") { !sent.received.isEmpty }
        #expect(sent.received == [.recordingDiscarded(hikeID: draftID)])
    }

    @Test("Stop asks a recording with a line for its name, offering one in the field")
    func stopQuestionAsksForAName() async {
        let recorder = makeRecorder()
        let question = RecordingStopQuestion(recorder: recorder, endings: EventFeed())
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        await question.ask()

        #expect(question.isAskingName)
        #expect(question.offeredTitle?.isEmpty == false)
        #expect(question.nameDraft == question.offeredTitle, "the field opens holding the offered name")
        #expect(recorder.phase == .recording, "asking ends nothing")
    }

    @Test("Save keeps the recording under the name typed over the offered one, and says which hike")
    func stopQuestionSavesTheTypedName() async throws {
        let recorder = makeRecorder()
        let endings = EventFeed<ActivityEnding>()
        let sent = FeedReader(endings.events())
        let question = RecordingStopQuestion(recorder: recorder, endings: endings)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        await question.ask()

        question.nameDraft = "Summit Day"
        await question.save()

        await settleDelegateHop(until: "the save to be sent") { !sent.received.isEmpty }
        guard case let .recordingSaved(hikeID) = try #require(sent.received.first) else {
            Issue.record("a save should be sent as one, sent \(sent.received)")
            return
        }
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        let saved = try #require(try container.mainContext.fetch(descriptor).first)
        #expect(saved.displayTitle == "Summit Day")
        #expect(recorder.phase == .idle)
    }

    /// The name alert's other way out, and a failed save's.
    @Test("Discard asks first, and throws the recording away only when told to")
    func stopQuestionDiscardsWhenConfirmed() async throws {
        let recorder = makeRecorder()
        let endings = EventFeed<ActivityEnding>()
        let sent = FeedReader(endings.events())
        let question = RecordingStopQuestion(recorder: recorder, endings: endings)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        let draftID = try #require(recorder.currentHike?.id)

        question.confirmDiscard()
        #expect(question.isConfirmingDiscard)
        #expect(recorder.phase == .recording, "asking throws nothing away")

        await question.discard()

        #expect(recorder.phase == .idle)
        await settleDelegateHop(until: "the discard to be sent") { !sent.received.isEmpty }
        #expect(sent.received == [.recordingDiscarded(hikeID: draftID)])
    }
}
