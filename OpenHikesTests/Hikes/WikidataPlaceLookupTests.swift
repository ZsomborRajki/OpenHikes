//
//  WikidataPlaceLookupTests.swift
//  OpenHikesTests
//
//  What the place cards' lookup keeps between cards, and what it does not.
//
//  A card reopened draws from what the lookup kept, so a kept answer is a
//  request saved and a section drawn in the card's first pass — and a kept
//  failure would be a section a hiker never sees again that launch. Both
//  halves are pinned against a source that counts what it was asked.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Wikidata place lookup")
struct WikidataPlaceLookupTests {
    /// A source that answers from a script and counts the questions.
    nonisolated private final class CountingSource: WikidataPlaceSourcing {
        private struct State {
            var asked: [String] = []
            var failures = 0
            var incomplete = 0
        }

        private let state = Mutex(State())

        var asked: [String] { state.withLock(\.asked) }

        /// The next `count` questions fail, the way an offline one does.
        func fail(times count: Int) { state.withLock { $0.failures = count } }

        /// The next `count` answers come without the photograph they name,
        /// the way one does whose picture failed.
        func leaveOutPhotograph(times count: Int) { state.withLock { $0.incomplete = count } }

        @concurrent
        func place(_ item: String) async throws -> WikidataPlace? {
            let (fails, isComplete) = state.withLock { current in
                current.asked.append(item)
                if current.failures > 0 {
                    current.failures -= 1
                    return (true, true)
                }
                guard current.incomplete > 0 else { return (false, true) }
                current.incomplete -= 1
                return (false, false)
            }
            if fails { throw URLError(.notConnectedToInternet) }
            // An item named `none` has nothing to show; every other one has
            // an article.
            guard item != "none" else { return nil }
            return WikidataPlace(
                item: item,
                article: WikidataPlaceLookupTests.article,
                photo: nil,
                isComplete: isComplete
            )
        }
    }

    nonisolated private static let article = WikipediaArticle(
        title: "Watzmann",
        extract: "Der Watzmann ist der zentrale Gebirgsstock der Berchtesgadener Alpen.",
        url: URL(filePath: "/Watzmann"),
        language: "de"
    )

    @Test("an answer is asked for once, and is there for the next card before it asks")
    func anAnswerIsAskedForOnce() async {
        let source = CountingSource()
        let lookup = WikidataPlaceLookup(source: source)
        #expect(lookup.answered("Q163919") == nil, "nothing is known before anything is asked")

        let first = await lookup.place("Q163919")
        let second = await lookup.place("Q163919")

        #expect(first?.article == Self.article)
        #expect(second == first)
        #expect(lookup.answered("Q163919") == first)
        #expect(source.asked == ["Q163919"])
    }

    /// *Nothing to show* is an answer the same item will give again.
    @Test("nothing to show is kept too")
    func nothingToShowIsKept() async {
        let source = CountingSource()
        let lookup = WikidataPlaceLookup(source: source)

        _ = await lookup.place("none")
        let again = await lookup.place("none")

        #expect(again == nil)
        #expect(source.asked == ["none"])
    }

    /// Offline in a valley is the commonest failure, and the next card opened
    /// on a better signal should ask.
    @Test("a failure is not kept, and the next card asks again")
    func aFailureIsNotKept() async {
        let source = CountingSource()
        source.fail(times: 1)
        let lookup = WikidataPlaceLookup(source: source)

        let failed = await lookup.place("Q163919")
        let retried = await lookup.place("Q163919")

        #expect(failed == nil)
        #expect(retried?.article == Self.article)
        #expect(source.asked == ["Q163919", "Q163919"])
    }

    /// A card closed while its question was out cancels it, and a question
    /// cut short may have answered with less than there is — a photograph-only
    /// place without its photograph is *nothing to show*.
    @Test("what a question cut short answered is not kept, and the next card asks again")
    func aCutShortAnswerIsNotKept() async {
        let source = CountingSource()
        let lookup = WikidataPlaceLookup(source: source)

        // Cancelled before it starts: the task is the main actor's, and
        // cannot run until this test suspends.
        let closed = Task { await lookup.place("Q163919") }
        closed.cancel()
        let cutShort = await closed.value
        let reopened = await lookup.place("Q163919")

        #expect(cutShort == nil)
        #expect(reopened?.article == Self.article)
        #expect(source.asked == ["Q163919", "Q163919"])
    }

    /// An article whose photograph failed: the article is worth drawing at
    /// once, and the photograph worth asking for again.
    @Test("an answer whose photograph failed is drawn by the next card, and asked again")
    func anIncompleteAnswerIsAskedAgain() async {
        let source = CountingSource()
        source.leaveOutPhotograph(times: 1)
        let lookup = WikidataPlaceLookup(source: source)

        let first = await lookup.place("Q163919")
        #expect(first?.isComplete == false)
        #expect(lookup.answered("Q163919") == first, "the next card draws it before it asks")

        let second = await lookup.place("Q163919")
        let third = await lookup.place("Q163919")

        #expect(second?.isComplete == true)
        #expect(third == second)
        #expect(source.asked == ["Q163919", "Q163919"])
    }

    /// Asked again and failed again, an answer whose photograph failed is
    /// still the best there is to draw.
    @Test("an answer whose photograph failed outlasts a failed second question")
    func anIncompleteAnswerOutlastsAFailure() async {
        let source = CountingSource()
        source.leaveOutPhotograph(times: 1)
        let lookup = WikidataPlaceLookup(source: source)

        let first = await lookup.place("Q163919")
        source.fail(times: 1)
        let failed = await lookup.place("Q163919")

        #expect(failed == nil)
        #expect(lookup.answered("Q163919") == first)
        #expect(source.asked == ["Q163919", "Q163919"])
    }

    @Test("only the newest answers are kept")
    func onlyTheNewestAreKept() async {
        let source = CountingSource()
        let lookup = WikidataPlaceLookup(source: source)
        let items = (0...WikidataPlaceLookup.capacity).map { "Q\($0 + 1)" }

        for item in items {
            _ = await lookup.place(item)
        }

        #expect(lookup.answered(items[0]) == nil, "the oldest has gone")
        #expect(lookup.answered(items[1]) != nil)
        #expect(lookup.answered(items[items.count - 1]) != nil)
    }

    /// The maker hands a card another place and keeps its state, so the
    /// answer a card was handed may be about the last place it showed.
    @Test("a card draws the answer about its own place, never the last one's")
    func aCardDrawsItsOwnPlace() async throws {
        let lookup = WikidataPlaceLookup(source: CountingSource())
        let watzmann = try #require(WikidataPlace(item: "Q163919", article: Self.article, photo: nil))

        #expect(lookup.shown(for: "Q163919", described: watzmann) == watzmann)
        #expect(lookup.shown(for: "Q2", described: watzmann) == nil, "an answer about another place is not drawn")
        #expect(lookup.shown(for: nil, described: watzmann) == nil, "a place with no item draws nothing")

        let answered = await lookup.place("Q2")
        #expect(answered != nil)
        #expect(
            lookup.shown(for: "Q2", described: watzmann) == answered,
            "what an earlier card was handed is drawn without asking"
        )
    }

    /// A photograph with no article beside it is Commons', and a heading
    /// naming Wikipedia would claim words the section does not have.
    @Test("a section is headed by where its answer comes from")
    func aSectionIsHeadedByItsSource() throws {
        let photo = WikidataPhoto(
            credit: CommonsPhotoCredit(
                author: "Jörg Braukmann",
                license: HikePhotoLicense(name: "CC BY-SA 4.0", url: nil, sourceURL: URL(filePath: "/File"))
            ),
            imageData: Data()
        )
        let withArticle = try #require(WikidataPlace(item: "Q1", article: Self.article, photo: photo))
        let photoAlone = try #require(WikidataPlace(item: "Q1", article: nil, photo: photo))

        #expect(withArticle.heading == String(localized: "From Wikipedia"))
        #expect(photoAlone.heading == String(localized: "From Wikimedia Commons"))
    }

    @Test("a photograph's bytes decode, and anything else does not")
    func aPhotographsBytesDecode() async {
        #expect(await WikidataPlaceLookup.image(from: PhotoDiscoveryFixture.sampleImageData()) != nil)
        #expect(await WikidataPlaceLookup.image(from: Data("<html>Not found</html>".utf8)) == nil)
    }

    @Test("an answer with neither an article nor a photograph is no answer")
    func neitherIsNoAnswer() {
        #expect(WikidataPlace(item: "Q1", article: nil, photo: nil) == nil)
        #expect(WikidataPlace(item: "Q1", article: Self.article, photo: nil) != nil)
    }
}
