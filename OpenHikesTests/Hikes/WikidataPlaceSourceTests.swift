//
//  WikidataPlaceSourceTests.swift
//  OpenHikesTests
//
//  Asking Wikidata, Wikipedia and Commons about one place, driven through
//  ``WikidataPlaceSource/Transport`` rather than the network.
//
//  The stand-in answers each service the way it answered on 2026-10-30 for
//  the Watzmann — see ``WikidataFixture`` — and can be told to answer any of
//  them otherwise. What is asserted is what a card depends on and cannot see
//  from the section alone: which questions are asked and which are not, that
//  a picture which cannot be shown costs only the picture, and which failures
//  are *nothing to show* and which are worth asking again.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Wikidata place source")
struct WikidataPlaceSourceTests {
    private static let noArticleNoImage = Data(#"{"entities":{"Q1":{"id":"Q1","sitelinks":{},"claims":{}}}}"#.utf8)

    /// The services, answering from memory and writing down what they were
    /// asked. `final class` behind a `Mutex` because the calls arrive off the
    /// main actor.
    nonisolated private final class StubWikimedia: Sendable {
        enum Service: Hashable {
            case wikidata
            case wikipedia
            case commons
            case images
        }

        private struct State {
            var requests: [URLRequest] = []
            var answers: [Service: (Data, Int)] = [:]
            var failures: [Service: any Error] = [:]
        }

        private let state: Mutex<State>

        init() {
            state = Mutex(State(answers: [
                .wikidata: (WikidataFixture.watzmann, 200),
                .wikipedia: (WikidataFixture.summary, 200),
                .commons: (WikidataFixture.fileInfo, 200),
                .images: (PhotoDiscoveryFixture.sampleImageData(), 200),
            ]))
        }

        var requests: [URLRequest] { state.withLock(\.requests) }

        func asked(_ service: Service) -> [URLRequest] {
            requests.filter { Self.service(of: $0) == service }
        }

        func answer(_ service: Service, with data: Data, status: Int = 200) {
            state.withLock { $0.answers[service] = (data, status) }
        }

        /// `service`'s requests end without an answer, as one cut off does.
        func fail(_ service: Service, with error: any Error) {
            state.withLock { $0.failures[service] = error }
        }

        var transport: WikidataPlaceSource.Transport {
            { [self] request in
                try state.withLock { current in
                    current.requests.append(request)
                    if let failure = current.failures[Self.service(of: request)] { throw failure }
                    return current.answers[Self.service(of: request)] ?? (Data(), 404)
                }
            }
        }

        private static func service(of request: URLRequest) -> Service {
            switch request.url?.host() {
            case "www.wikidata.org": .wikidata
            case "commons.wikimedia.org": .commons
            case let host? where host.hasSuffix(".wikipedia.org"): .wikipedia
            default: .images
            }
        }
    }

    private static func source(_ stub: StubWikimedia, languages: [String] = ["de", "en"]) -> WikidataPlaceSource {
        WikidataPlaceSource(languages: languages, transport: stub.transport)
    }

    // MARK: - What an answer holds

    @Test("an item with an article and a photograph answers both, from four requests")
    func anItemAnswersItsArticleAndPhotograph() async throws {
        let stub = StubWikimedia()

        let place = try #require(try await Self.source(stub).place("Q163919"))

        #expect(place.item == "Q163919")
        #expect(place.article?.title == "Watzmann")
        #expect(place.article?.language == "de")
        #expect(place.photo?.credit.author == "Jörg Braukmann")
        #expect(place.photo?.credit.license.name == "CC BY-SA 4.0")
        #expect(place.photo?.credit.license.sourceURL.absoluteString
            == "https://commons.wikimedia.org/wiki/File:Watzmann_von_Norden.jpg")
        #expect(place.photo?.imageData == PhotoDiscoveryFixture.sampleImageData())
        #expect(stub.requests.count == 4)
        #expect(stub.asked(.wikipedia).first?.url?.host() == "de.wikipedia.org")
    }

    @Test("every request introduces itself")
    func everyRequestIntroducesItself() async throws {
        let stub = StubWikimedia()

        _ = try await Self.source(stub).place("Q163919")

        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent })
    }

    @Test("a phone in English reads the English article")
    func aPhoneInEnglishReadsEnglish() async throws {
        let stub = StubWikimedia()

        let place = try await Self.source(stub, languages: ["en"]).place("Q163919")

        #expect(place?.article?.language == "en")
        #expect(stub.asked(.wikipedia).first?.url?.host() == "en.wikipedia.org")
        #expect(
            stub.asked(.wikidata).first?.url?.query()?.contains("sitefilter=enwiki") == true,
            "and asks the item about English alone"
        )
    }

    /// Cantonese's Wikipedia is zh-yue.wikipedia.org, filed by Wikidata as
    /// `zh_yuewiki`. Asked for under its language's own code, Hong Kong's
    /// item answered about English alone on 2026-10-30.
    @Test("a phone in Cantonese reads the Cantonese article, from its own Wikipedia")
    func aPhoneInCantoneseReadsCantonese() async throws {
        let stub = StubWikimedia()
        stub.answer(.wikidata, with: WikidataFixture.hongKong)
        stub.answer(.wikipedia, with: WikidataFixture.hongKongInCantonese)
        let languages = WikidataQuery.languages(preferring: ["yue-Hant-HK"])

        let place = try await Self.source(stub, languages: languages).place("Q8646")

        #expect(place?.article?.title == "香港")
        #expect(place?.article?.language == "zh-yue")
        #expect(stub.asked(.wikipedia).first?.url?.host() == "zh-yue.wikipedia.org")
        #expect(stub.asked(.wikidata).first?.url?.query()?.contains("sitefilter=zh_yuewiki") == true)
    }

    /// Measured on 2026-10-30: of nine huts' items in the Berchtesgaden box,
    /// eight linked a German article, none an English one, and all nine named
    /// a photograph. A card that needed both would show a hiker reading in
    /// English nothing at all.
    @Test("an item with no article in the hiker's languages still shows its photograph")
    func aPhotographShowsWithoutAnArticle() async throws {
        let stub = StubWikimedia()
        stub.answer(.wikidata, with: WikidataFixture.watzmannInGermanOnly)

        let place = try #require(try await Self.source(stub, languages: ["en"]).place("Q163919"))

        #expect(place.article == nil)
        #expect(place.photo != nil)
        #expect(stub.asked(.wikipedia).isEmpty, "there was no article to ask for")
    }

    @Test("an item with neither is nothing to show, and costs one request")
    func anItemWithNeitherIsNothing() async throws {
        let stub = StubWikimedia()
        stub.answer(.wikidata, with: Self.noArticleNoImage)

        let place = try await Self.source(stub).place("Q1")

        #expect(place == nil)
        #expect(stub.requests.count == 1)
    }

    /// The item still links an article that has since been deleted or moved.
    @Test("an article that has gone is no article, and the photograph stays")
    func aGoneArticleIsNoArticle() async throws {
        let stub = StubWikimedia()
        stub.answer(.wikipedia, with: Data(), status: 404)

        let place = try #require(try await Self.source(stub).place("Q163919"))

        #expect(place.article == nil)
        #expect(place.photo != nil)
    }

    // MARK: - A picture costs only itself

    @Test("a file that is not a photograph is left out, and the article stays")
    func aDrawingIsLeftOut() async throws {
        let stub = StubWikimedia()
        stub.answer(.commons, with: WikidataFixture.fileInfo(mime: "image/png"))

        let place = try #require(try await Self.source(stub).place("Q163919"))

        #expect(place.photo == nil)
        #expect(place.article != nil)
        #expect(place.isComplete, "a picture this app may not show is an answer")
        #expect(stub.asked(.images).isEmpty, "nothing is downloaded for a file that will not be shown")
    }

    @Test("a picture that is not one costs the picture")
    func aPictureThatIsNotOneCostsThePicture() async throws {
        let stub = StubWikimedia()
        stub.answer(.images, with: Data("<html>Not found</html>".utf8))

        let place = try #require(try await Self.source(stub).place("Q163919"))

        #expect(place.photo == nil)
        #expect(place.article != nil)
        #expect(place.isComplete)
    }

    // MARK: - A picture that failed is not one there is none of

    @Test("a busy Commons costs the picture this once, and is not asked twice")
    func aBusyCommonsCostsThePicture() async throws {
        let stub = StubWikimedia()
        stub.answer(.commons, with: Data(), status: 429)

        let place = try #require(try await Self.source(stub).place("Q163919"))

        #expect(place.photo == nil)
        #expect(place.article != nil)
        #expect(!place.isComplete, "so the next card asks for the picture again")
        #expect(stub.asked(.commons).count == 1)
    }

    /// The huts' shape read in English: the photograph is the whole section,
    /// and answered as `nil` its failure would be kept as *nothing to show*.
    @Test("a photograph that failed with no article beside it throws")
    func aFailedPhotographAloneThrows() async {
        let stub = StubWikimedia()
        stub.answer(.wikidata, with: WikidataFixture.watzmannInGermanOnly)
        stub.answer(.commons, with: Data(), status: 429)

        await #expect(throws: CommonsPhotoFailure.busy) {
            try await Self.source(stub, languages: ["en"]).place("Q163919")
        }
    }

    /// A card closed while its picture is on the way cuts the download off,
    /// which `URLSession` reports as its own cancellation.
    @Test("a download cut short with no article beside it throws")
    func aCutShortPhotographAloneThrows() async {
        let stub = StubWikimedia()
        stub.answer(.wikidata, with: WikidataFixture.watzmannInGermanOnly)
        stub.fail(.images, with: URLError(.cancelled))

        let error = await #expect(throws: URLError.self) {
            try await Self.source(stub, languages: ["en"]).place("Q163919")
        }

        #expect(error?.code == .cancelled)
    }

    // MARK: - What is worth asking again

    /// A failure is thrown rather than answered as `nil`, which is what keeps
    /// the lookup from remembering *nothing to show* for a place that has
    /// something — see ``WikidataPlaceLookup``.
    @Test("an item that could not be asked about throws, and nothing more is asked")
    func aFailedItemThrows() async {
        let stub = StubWikimedia()
        stub.answer(.wikidata, with: Data(), status: 503)

        await #expect(throws: WikidataPlaceFailure.server(statusCode: 503)) {
            try await Self.source(stub).place("Q163919")
        }
        #expect(stub.requests.count == 1)
    }

    @Test("an article that could not be read throws")
    func aFailedArticleThrows() async {
        let stub = StubWikimedia()
        stub.answer(.wikipedia, with: Data(), status: 500)

        await #expect(throws: WikidataPlaceFailure.server(statusCode: 500)) {
            try await Self.source(stub).place("Q163919")
        }
    }
}
