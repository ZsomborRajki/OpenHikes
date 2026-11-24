//
//  CommonsPhotoRefetchTests.swift
//  OpenHikesTests
//
//  How a saved copy's picture is asked for again: the revision it was made
//  from or nothing, a copy saved before the hash was kept only while its
//  credit still fits, one question at a time with every name waiting going
//  into the next one as far as it has room, a name asked for twice asked
//  about once, the thumbnails a few at a time, and a *no* remembered while a
//  failure is not. Driven through
//  ``CommonsPhotoRefetch/Transport``, as the other Commons suites are, so
//  nothing here reaches Wikimedia.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Commons photo refetch", .timeLimit(.minutes(1)))
struct CommonsPhotoRefetchTests {
    private static let picture = CommonsPictureAnswer.picture(CommonsRefetchStub.thumbnail)

    /// A saved copy of the file `name`, pinned as the stub's copies are.
    private static func copy(
        _ name: String,
        pinnedTo pin: CommonsRefetchStub.Pin = .current,
        author: String = CommonsRefetchStub.author
    ) -> CommonsCopy {
        let sha1: String? = switch pin {
        case .current: CommonsRefetchStub.currentSHA1(of: name)
        case .revision(let hash): hash
        case .unpinned: nil
        }
        return CommonsCopy(title: name, fileSHA1: sha1, author: author, licenseName: CommonsRefetchStub.licenseName)
    }

    /// Waits until `count` asks are waiting on `title`.
    private static func waitUntil(
        _ refetch: CommonsPhotoRefetch,
        has count: Int,
        waitingOn title: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await waitUntil("\(count) asks on \(title)", sourceLocation: sourceLocation) {
            await refetch.waiterCount(for: title) >= count
        }
    }

    /// Waits until `isDone` — an actor's contents need an `await`, which a
    /// settle's condition cannot make, so this is the loop
    /// `settlePollTick()` is shared for.
    private static func waitUntil(
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ isDone: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !isDone() {
            guard ContinuousClock.now < deadline, await settlePollTick() else {
                Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    // MARK: - Which picture

    @Test("a copy of the file's current revision comes back from one question and one download")
    func currentRevisionComesBack() async {
        let commons = CommonsRefetchStub()
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == Self.picture)

        #expect(commons.questions == [["Lac_glacier.jpg"]])
        #expect(commons.revisionLookups.isEmpty)
        #expect(commons.downloads.count == 1)
    }

    @Test("a copy of a revision the file has moved past comes back as that revision")
    func earlierRevisionComesBack() async {
        let commons = CommonsRefetchStub()
        commons.keepRevisions(of: "Lac_glacier.jpg", ["newer", "saved", "older"])
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg", pinnedTo: .revision("saved"))) == Self.picture)

        #expect(commons.revisionLookups == ["Lac_glacier.jpg"])
        #expect(commons.downloads == [CommonsRefetchStub.archivedThumbnail("saved")])
    }

    @Test("a copy of a revision Commons no longer has is refused, and nothing is downloaded")
    func lostRevisionIsRefused() async {
        let commons = CommonsRefetchStub()
        commons.keepRevisions(of: "Lac_glacier.jpg", ["older"])
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg", pinnedTo: .revision("saved"))) == .refused)
        #expect(commons.downloads.isEmpty)
    }

    @Test("a copy saved without its revision comes back while Commons credits the file as it does")
    func unpinnedCopyWithTheSameCredit() async {
        let commons = CommonsRefetchStub()
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg", pinnedTo: .unpinned)) == Self.picture)
    }

    @Test("a copy saved without its revision is refused once Commons credits the file to somebody else")
    func unpinnedCopyWithAnotherCredit() async {
        let commons = CommonsRefetchStub()
        commons.credit("Lac_glacier.jpg", to: "Somebody else")
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg", pinnedTo: .unpinned)) == .refused)
        #expect(commons.downloads.isEmpty)
    }

    // MARK: - Asking again, or not

    @Test("a file Commons no longer has is refused, and not asked about again")
    func goneFileIsRefusedOnce() async {
        let commons = CommonsRefetchStub()
        commons.gone("Gone.jpg")
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Gone.jpg")) == .refused)
        #expect(await refetch.picture(of: Self.copy("Gone.jpg")) == .refused)

        #expect(commons.questions.count == 1)
        #expect(commons.downloads.isEmpty)
    }

    @Test("a copy whose credit no longer fits is refused, and not asked about again")
    func unlikeCopyIsRefusedOnce() async {
        let commons = CommonsRefetchStub()
        commons.credit("Lac_glacier.jpg", to: "Somebody else")
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let copy = Self.copy("Lac_glacier.jpg", pinnedTo: .unpinned)

        #expect(await refetch.picture(of: copy) == .refused)
        #expect(await refetch.picture(of: copy) == .refused)

        #expect(commons.questions.count == 1)
    }

    @Test("a copy of a revision Commons no longer has is refused, and not looked up again")
    func lostRevisionIsRefusedOnce() async {
        let commons = CommonsRefetchStub()
        commons.keepRevisions(of: "Lac_glacier.jpg", ["older"])
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let copy = Self.copy("Lac_glacier.jpg", pinnedTo: .revision("saved"))

        #expect(await refetch.picture(of: copy) == .refused)
        #expect(await refetch.picture(of: copy) == .refused)

        #expect(commons.questions.count == 1)
        #expect(commons.revisionLookups.count == 1)
    }

    @Test("a refusal of one copy leaves another copy of the same file to be asked for")
    func refusalIsTheCopys() async {
        let commons = CommonsRefetchStub()
        commons.keepRevisions(of: "Lac_glacier.jpg", ["older"])
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg", pinnedTo: .revision("saved"))) == .refused)
        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == Self.picture)
    }

    @Test("a question Commons does not answer is no answer, and the next ask asks again")
    func unansweredQuestionIsAskedAgain() async {
        let commons = CommonsRefetchStub()
        commons.refuseQuestions(true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == .unanswered)
        commons.refuseQuestions(false)
        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == Self.picture)

        #expect(commons.questions.count == 2)
    }

    @Test("a thumbnail Commons failed to make is no answer, and the next ask asks again")
    func thumbnailErrorIsAskedAgain() async {
        let commons = CommonsRefetchStub()
        commons.failThumbnail(of: "Lac_glacier.jpg")
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == .unanswered)
        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == .unanswered)

        #expect(commons.questions.count == 2)
    }

    @Test("a thumbnail that does not arrive is no answer rather than a refusal")
    func failedDownloadIsUnanswered() async {
        let commons = CommonsRefetchStub()
        commons.refuseDownloads(true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)

        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == .unanswered)
        commons.refuseDownloads(false)
        #expect(await refetch.picture(of: Self.copy("Lac_glacier.jpg")) == Self.picture)
    }

    // MARK: - The queue

    @Test("names asked for while a question is out wait, and go together in the next one, in order")
    func waitingNamesGoTogether() async {
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let (first, second, third) = (Self.copy("First.jpg"), Self.copy("Second.jpg"), Self.copy("Third.jpg"))

        async let firstAnswer = refetch.picture(of: first)
        await settleDelegateHop(until: "the first question is out") { commons.isHoldingQuestion }
        async let secondAnswer = refetch.picture(of: second)
        // Asked for only once the second is waiting, so the order the next
        // question names them in is the order they were asked for.
        await Self.waitUntil(refetch, has: 1, waitingOn: "Second.jpg")
        async let thirdAnswer = refetch.picture(of: third)
        await Self.waitUntil(refetch, has: 1, waitingOn: "Third.jpg")
        // Only one question while the first is held: the other two wait.
        #expect(commons.questions == [["First.jpg"]])
        commons.answerHeldQuestion()

        let answers = await [firstAnswer, secondAnswer, thirdAnswer]
        #expect(answers.allSatisfy { $0 == Self.picture })
        #expect(commons.questions == [["First.jpg"], ["Second.jpg", "Third.jpg"]])
    }

    @Test("more names than one question holds go a batch at a time, in the order they were asked for")
    func aBacklogGoesABatchAtATime() async {
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let names = (0..<(CommonsPhotoQuery.imageInfoBatch + 2)).map { "Photo_\($0).jpg" }

        async let first = refetch.picture(of: Self.copy("First.jpg"))
        await settleDelegateHop(until: "the first question is out") { commons.isHoldingQuestion }
        let answers = await withTaskGroup(of: CommonsPictureAnswer.self) { group in
            // One at a time, so the order they wait in is the order asked.
            for name in names {
                group.addTask { await refetch.picture(of: Self.copy(name)) }
                await Self.waitUntil(refetch, has: 1, waitingOn: name)
            }
            commons.answerHeldQuestion()
            var answers: [CommonsPictureAnswer] = []
            for await answer in group { answers.append(answer) }
            return answers
        }

        #expect(await first == Self.picture)
        #expect(answers.count == names.count)
        #expect(answers.allSatisfy { $0 == Self.picture })
        #expect(Array(commons.questions.dropFirst()) == [
            Array(names.prefix(CommonsPhotoQuery.imageInfoBatch)),
            Array(names.dropFirst(CommonsPhotoQuery.imageInfoBatch)),
        ])
    }

    @Test("a picture asked for again while its question is out is asked about and downloaded once")
    func pictureInFlightIsFetchedOnce() async {
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let copy = Self.copy("Lac_glacier.jpg")

        async let strip = refetch.picture(of: copy)
        await settleDelegateHop(until: "the first question is out") { commons.isHoldingQuestion }
        async let viewer = refetch.picture(of: copy)
        // The second ask joins the question that is out rather than queueing
        // for the next one.
        await Self.waitUntil(refetch, has: 2, waitingOn: "Lac_glacier.jpg")
        commons.answerHeldQuestion()

        let answers = await [strip, viewer]
        #expect(answers == [Self.picture, Self.picture])
        #expect(commons.questions == [["Lac_glacier.jpg"]])
        #expect(commons.downloads.count == 1)
    }

    @Test("names too long to go in one question together go in the next")
    func longNamesSplitAcrossQuestions() async {
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let names = (0..<CommonsPhotoQuery.imageInfoBatch).map { index in
            "Вид_на_Говерлу_з_хребта_Чорногора,_Українські_Карпати_\(index).jpg"
        }
        let copies = names.map { Self.copy($0) }

        async let first = refetch.picture(of: Self.copy("First.jpg"))
        await settleDelegateHop(until: "the first question is out") { commons.isHoldingQuestion }
        let answers = await withTaskGroup(of: CommonsPictureAnswer.self) { group in
            for copy in copies {
                group.addTask { await refetch.picture(of: copy) }
            }
            for name in names {
                await Self.waitUntil(refetch, has: 1, waitingOn: name)
            }
            commons.answerHeldQuestion()
            var answers: [CommonsPictureAnswer] = []
            for await answer in group { answers.append(answer) }
            return answers
        }

        #expect(await first == Self.picture)
        #expect(answers.count == names.count)
        #expect(answers.allSatisfy { $0 == Self.picture })
        let later = commons.questions.dropFirst()
        #expect(later.count > 1)
        #expect(later.flatMap(\.self).sorted() == names.sorted())
        #expect(commons.requests.allSatisfy { $0.absoluteString.utf8.count <= CommonsPhotoQuery.maximumRequestLength })
    }

    @Test("thumbnails come down a few at a time, however many are asked for")
    func downloadsTakeTurns() async {
        let commons = CommonsRefetchStub(holdingDownloads: true)
        let refetch = CommonsPhotoRefetch(transport: commons.transport)
        let turns = WikimediaCommonsSource.parallelDownloads
        let names = (0..<(turns + 2)).map { "Photo_\($0).jpg" }
        let copies = names.map { Self.copy($0) }

        let answers = await withTaskGroup(of: CommonsPictureAnswer.self) { group in
            for copy in copies {
                group.addTask { await refetch.picture(of: copy) }
            }
            await Self.waitUntil("\(turns) downloads out and the rest waiting") {
                await refetch.downloadsWaitingForTurn == names.count - turns && commons.heldDownloadCount == turns
            }
            // The two waiting for a turn have not been asked for.
            #expect(commons.downloads.count == turns)
            commons.releaseDownloads()
            var answers: [CommonsPictureAnswer] = []
            for await answer in group { answers.append(answer) }
            return answers
        }

        #expect(answers.count == names.count)
        #expect(answers.allSatisfy { $0 == Self.picture })
        #expect(commons.downloads.count == names.count)
    }
}
