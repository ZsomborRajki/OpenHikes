//
//  CommonsPhotoRefetchTests.swift
//  OpenHikesTests
//
//  The queue a saved copy's picture is asked for again through: one question
//  to Commons at a time, every name waiting going into the next one, a name
//  asked for twice asked about once, and a *no* remembered while a failure is
//  not. Driven through ``CommonsPhotoRefetch/Transport``, as the other
//  Commons suites are, so nothing here reaches Wikimedia.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Commons photo refetch", .timeLimit(.minutes(1)))
struct CommonsPhotoRefetchTests {
    /// Waits until `count` asks are waiting on `title` — an actor's contents
    /// need an `await`, which a settle's condition cannot make, so this is
    /// the loop `settlePollTick()` is shared for.
    private static func waitUntil(
        _ refetch: CommonsPhotoRefetch,
        has count: Int,
        waitingOn title: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await refetch.waiterCount(for: title) < count {
            guard ContinuousClock.now < deadline, await settlePollTick() else {
                Issue.record("Timed out waiting for \(count) asks on \(title)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    @Test("a file Commons still has comes back as its picture, from one question and one download")
    func fileComesBackAsItsPicture() async {
        let commons = CommonsRefetchStub()
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        let answer = await refetch.picture(ofFileTitled: "Lac_glacier.jpg")

        #expect(answer == .picture(CommonsRefetchStub.thumbnail))
        #expect(commons.questions == [["Lac_glacier.jpg"]])
        #expect(commons.downloads == 1)
    }

    @Test("a file Commons no longer has is refused, and not asked about again")
    func goneFileIsRefusedOnce() async {
        let commons = CommonsRefetchStub()
        commons.gone("Gone.jpg")
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(ofFileTitled: "Gone.jpg") == .refused)
        #expect(await refetch.picture(ofFileTitled: "Gone.jpg") == .refused)

        #expect(commons.questions.count == 1)
        #expect(commons.downloads == 0)
    }

    @Test("a question Commons does not answer is no answer, and the next ask asks again")
    func unansweredQuestionIsAskedAgain() async {
        let commons = CommonsRefetchStub()
        commons.refuseQuestions(true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(ofFileTitled: "Lac_glacier.jpg") == .unanswered)
        commons.refuseQuestions(false)
        #expect(await refetch.picture(ofFileTitled: "Lac_glacier.jpg") == .picture(CommonsRefetchStub.thumbnail))

        #expect(commons.questions.count == 2)
    }

    @Test("a thumbnail that does not arrive is no answer rather than a refusal")
    func failedDownloadIsUnanswered() async {
        let commons = CommonsRefetchStub()
        commons.refuseDownloads(true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(ofFileTitled: "Lac_glacier.jpg") == .unanswered)
        commons.refuseDownloads(false)
        #expect(await refetch.picture(ofFileTitled: "Lac_glacier.jpg") == .picture(CommonsRefetchStub.thumbnail))
    }

    @Test("names asked for while a question is out wait, and go together in the next one")
    func waitingNamesGoTogether() async {
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        async let first = refetch.picture(ofFileTitled: "First.jpg")
        await settleDelegateHop(until: "the first question is out") { commons.isHoldingQuestion }
        async let second = refetch.picture(ofFileTitled: "Second.jpg")
        async let third = refetch.picture(ofFileTitled: "Third.jpg")
        await Self.waitUntil(refetch, has: 1, waitingOn: "Second.jpg")
        await Self.waitUntil(refetch, has: 1, waitingOn: "Third.jpg")
        // Only one question while the first is held: the other two wait.
        #expect(commons.questions == [["First.jpg"]])
        commons.answerHeldQuestion()

        let answers = await [first, second, third]
        #expect(answers.allSatisfy { $0 == .picture(CommonsRefetchStub.thumbnail) })
        #expect(commons.questions == [["First.jpg"], ["Second.jpg", "Third.jpg"]])
    }

    @Test("a name asked for again while its question is out is asked about once")
    func nameInFlightIsAskedOnce() async {
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        async let strip = refetch.picture(ofFileTitled: "Lac_glacier.jpg")
        await settleDelegateHop(until: "the first question is out") { commons.isHoldingQuestion }
        async let viewer = refetch.picture(ofFileTitled: "Lac_glacier.jpg")
        // The second ask joins the question that is out rather than queueing
        // for the next one.
        await Self.waitUntil(refetch, has: 2, waitingOn: "Lac_glacier.jpg")
        commons.answerHeldQuestion()

        let answers = await [strip, viewer]
        #expect(answers == [.picture(CommonsRefetchStub.thumbnail), .picture(CommonsRefetchStub.thumbnail)])
        #expect(commons.questions == [["Lac_glacier.jpg"]])
        #expect(commons.downloads == 1)
    }
}
