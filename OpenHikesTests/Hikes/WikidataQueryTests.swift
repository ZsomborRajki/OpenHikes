//
//  WikidataQueryTests.swift
//  OpenHikesTests
//
//  What a place card asks Wikidata and Wikipedia, and how their answers are
//  read.
//
//  The answers are ``WikidataFixture``'s, cut down from what the live
//  services sent for the Watzmann and keeping their shapes. What is pinned is
//  the reading — which article, which picture, and which answers are
//  *nothing to show* rather than a failure.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Wikidata query")
struct WikidataQueryTests {
    nonisolated private enum Answers {
        /// An item with these image statements and nothing else.
        static func images(_ statements: [(rank: String, file: String?)]) -> Data {
            let claims = statements.map { statement in
                let value = statement.file.map { #","datavalue":{"value":"\#($0)","type":"string"}"# } ?? ""
                let snak = statement.file == nil ? "somevalue" : "value"
                return #"{"mainsnak":{"snaktype":"\#(snak)","property":"P18"\#(value)},"rank":"\#(statement.rank)"}"#
            }
            return Data(#"{"entities":{"Q1":{"id":"Q1","claims":{"P18":[\#(claims.joined(separator: ","))]}}}}"#.utf8)
        }

        /// An item linked to one German article, titled `title`.
        static func article(titled title: String) -> Data {
            Data(#"{"entities":{"Q1":{"id":"Q1","sitelinks":{"dewiki":{"site":"dewiki","title":"\#(title)"}}}}}"#.utf8)
        }

        /// A summary, with `changes` written over the Watzmann's.
        static func summary(_ changes: [String: Any]) throws -> Data {
            let parsed = try JSONSerialization.jsonObject(with: WikidataFixture.summary)
            var object = try #require(parsed as? [String: Any])
            object.merge(changes) { _, new in new }
            return try JSONSerialization.data(withJSONObject: object)
        }
    }

    private static func queryItems(of request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: - Languages

    @Test(
        "the device's languages are asked first, then English, each once",
        arguments: [
            (["de-DE", "en-US"], ["de", "en"]),
            (["en-GB", "en-US"], ["en"]),
            (["hu-HU", "de-AT", "fr-FR"], ["hu", "de", "en"]),
            // Bokmål's Wikipedia is not at its own code, and nor are the
            // ones Wikimedia lists under *Special language codes*.
            (["nb-NO"], ["no", "en"]),
            (["yue-Hant-HK", "zh-Hant-HK"], ["zh-yue", "zh", "en"]),
            (["gsw-CH"], ["als", "en"]),
            (["nan-Hant-TW"], ["zh-min-nan", "en"]),
            (["zh-Hans-CN"], ["zh", "en"]),
            ([], ["en"]),
        ]
    )
    func theDevicesLanguagesComeFirst(preferred: [String], languages: [String]) {
        #expect(WikidataQuery.languages(preferring: preferred) == languages)
    }

    /// Wikidata writes a Wikipedia's code with `_` for `-`. Asked for
    /// `yuewiki` on 2026-10-30, Hong Kong's item answered about English alone.
    @Test(
        "a Wikipedia is asked for by the site id Wikidata files it under",
        arguments: [("de", "dewiki"), ("no", "nowiki"), ("zh-yue", "zh_yuewiki"), ("zh-min-nan", "zh_min_nanwiki")]
    )
    func aWikipediaIsAskedForByItsSiteID(language: String, site: String) {
        #expect(WikidataQuery.site(for: language) == site)
    }

    // MARK: - The requests

    @Test("the item is asked for its articles in the hiker's languages and its statements")
    func theItemIsAskedForItsArticlesAndStatements() {
        let request = WikidataQuery.entity("Q163919", languages: ["de", "en"])

        #expect(request.url?.host() == "www.wikidata.org")
        #expect(
            Self.queryItems(of: request) == [
                "action": "wbgetentities",
                "format": "json",
                "ids": "Q163919",
                "props": "sitelinks|claims",
                "sitefilter": "dewiki|enwiki",
            ]
        )
        #expect(request.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent)
    }

    @Test("a summary is asked of the article's own Wikipedia")
    func aSummaryIsAskedOfItsWikipedia() throws {
        let request = try #require(WikidataQuery.summary(of: "Watzmann", language: "de"))
        let cantonese = try #require(WikidataQuery.summary(of: "香港", language: "zh-yue"))

        #expect(request.url?.absoluteString == "https://de.wikipedia.org/api/rest_v1/page/summary/Watzmann")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent)
        #expect(
            cantonese.url?.absoluteString
                == "https://zh-yue.wikipedia.org/api/rest_v1/page/summary/%E9%A6%99%E6%B8%AF",
            "a Wikipedia whose code is not two or three letters is still one"
        )
    }

    /// A slash is a character of some titles and a separator of the path, so
    /// a title carrying one would ask for a different page if it were left.
    @Test("a title's spaces are underscores and its slash is not a path")
    func aTitleIsOnePathComponent() throws {
        let request = try #require(WikidataQuery.summary(of: "Kärlinger Haus/Funtensee", language: "de"))

        #expect(request.url?.absoluteString.hasSuffix("/page/summary/K%C3%A4rlinger_Haus%2FFuntensee") == true)
    }

    /// The language becomes part of the host name, so nothing but a language
    /// code is let into it.
    @Test(
        "a language that cannot be a host name asks nothing",
        arguments: ["", "d", "EN", "deu1", "de.evil", "de/x", "zh-evil"]
    )
    func aLanguageThatIsNotOneAsksNothing(language: String) {
        #expect(WikidataQuery.summary(of: "Watzmann", language: language) == nil)
    }

    @Test("a picture's details are asked of Commons by the file's name")
    func aPictureIsAskedForByName() {
        let named = Self.queryItems(of: CommonsPhotoQuery.imageInfo(ofFileTitled: "Watzmann von Norden.jpg"))
        let numbered = Self.queryItems(of: CommonsPhotoQuery.imageInfo(of: [117_867_472]))

        #expect(named["titles"] == "File:Watzmann von Norden.jpg")
        #expect(named["pageids"] == nil)
        // The same fields a geotagged file is asked for, so the same checks
        // can be made of it.
        #expect(named.filter { $0.key != "titles" } == numbered.filter { $0.key != "pageids" })
    }

    /// MediaWiki reads a `+` in a query as a space: asked for `File:A+B.jpg`
    /// on 2026-10-30, Commons answered about `File:A B.jpg`.
    @Test("a file name's plus is sent as one, not as a space")
    func aFileNamesPlusIsSentAsOne() throws {
        let url = try #require(CommonsPhotoQuery.imageInfo(ofFileTitled: "Lac+glacier.jpg").url)
        let sent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []

        #expect(sent.first { $0.name == "titles" }?.value == "File:Lac%2Bglacier.jpg")
    }

    // MARK: - The item's answer

    @Test("an item's answer gives its articles and its image")
    func anItemGivesItsArticlesAndImage() throws {
        let entity = try WikidataQuery.entity(from: WikidataFixture.watzmann)

        #expect(entity.articles == ["dewiki": "Watzmann", "enwiki": "Watzmann"])
        #expect(entity.image == "Watzmann von Norden.jpg")
    }

    /// A title is the page's name: cut to a bound it names another page, or
    /// none, which would read as an article that has gone. MediaWiki's own
    /// limit is 255 bytes.
    @Test("a linked title is read whole, and one longer than a page's can be is no link")
    func aLinkedTitleIsReadWhole() throws {
        let long = String(repeating: "a", count: 200)
        let tooLong = String(repeating: "a", count: 256)

        #expect(try WikidataQuery.entity(from: Answers.article(titled: long)).articles["dewiki"] == long)
        #expect(try WikidataQuery.entity(from: Answers.article(titled: tooLong)).articles["dewiki"] == nil)
    }

    @Test("the article read is the first language that has one")
    func theFirstLanguageWithAnArticleIsRead() throws {
        let entity = WikidataEntity(articles: ["dewiki": "Kärlingerhaus"])
        let hongKong = try WikidataQuery.entity(from: WikidataFixture.hongKong)

        #expect(entity.article(in: ["en", "de"])?.language == "de")
        #expect(entity.article(in: ["en", "de"])?.title == "Kärlingerhaus")
        #expect(entity.article(in: ["en", "fr"]) == nil)
        #expect(hongKong.article(in: ["zh-yue", "en"])?.title == "香港", "not the English article after it")
    }

    /// Wikidata's own ranking: a preferred statement before a normal one,
    /// and a deprecated one — a statement somebody marked as wrong — never.
    @Test("the image read is the preferred one, never a deprecated one")
    func thePreferredImageIsRead() throws {
        let ranked = try WikidataQuery.entity(from: Answers.images([
            ("deprecated", "Wrong.jpg"),
            ("normal", "Normal.jpg"),
            ("preferred", "Preferred.jpg"),
        ]))
        let deprecated = try WikidataQuery.entity(from: Answers.images([("deprecated", "Wrong.jpg")]))
        // *Some value* is a statement with no file in it.
        let unknown = try WikidataQuery.entity(from: Answers.images([("preferred", nil), ("normal", "Normal.jpg")]))

        #expect(ranked.image == "Preferred.jpg")
        #expect(deprecated.image == nil)
        #expect(unknown.image == "Normal.jpg")
    }

    @Test("an item that no longer exists is an answer with nothing in it")
    func aMissingItemIsAnEmptyAnswer() throws {
        let missing = Data(#"{"error":{"code":"no-such-entity","info":"Could not find an entity."}}"#.utf8)

        #expect(try WikidataQuery.entity(from: missing) == WikidataEntity())
    }

    @Test("any other error is a refusal naming its code")
    func anyOtherErrorIsARefusal() {
        let lagging = Data(#"{"error":{"code":"maxlag","info":"Waiting for a database server."}}"#.utf8)

        #expect(throws: WikidataPlaceFailure.refused(code: "maxlag")) {
            try WikidataQuery.entity(from: lagging)
        }
    }

    /// MediaWiki writes an empty object as `[]`.
    @Test("an item with no links and no statements is read as one")
    func anEmptyItemIsRead() throws {
        let empty = Data(#"{"entities":{"Q1":{"type":"item","id":"Q1","sitelinks":[],"claims":[]}},"success":1}"#.utf8)

        #expect(try WikidataQuery.entity(from: empty) == WikidataEntity())
    }

    @Test("a status outside the 200s is the server's failure")
    func aFailedStatusIsTheServers() {
        #expect(throws: WikidataPlaceFailure.server(statusCode: 503)) {
            try WikidataQuery.body(of: Data(), statusCode: 503)
        }
        #expect(throws: Never.self) { try WikidataQuery.body(of: Data(), statusCode: 200) }
    }

    // MARK: - The article's answer

    @Test("a summary gives the article's title, its opening and its address")
    func aSummaryGivesTheArticle() throws {
        let article = try #require(try WikidataQuery.article(from: WikidataFixture.summary, language: "de"))

        #expect(article.title == "Watzmann")
        #expect(article.extract == "Der Watzmann ist der zentrale Gebirgsstock der Berchtesgadener Alpen.")
        #expect(article.url.absoluteString == "https://de.wikipedia.org/wiki/Watzmann")
        #expect(article.language == "de")
    }

    /// The summaries that are not an article to show, each one change away
    /// from the Watzmann's.
    enum Unshown: CaseIterable, Sendable {
        case disambiguation
        case emptyOpening
        case addressElsewhere
        case addressInPlainText

        var changes: [String: Any] {
            switch self {
            case .disambiguation: ["type": "disambiguation"]
            case .emptyOpening: ["extract": "   "]
            case .addressElsewhere: ["content_urls": ["desktop": ["page": "https://example.com/wiki/Watzmann"]]]
            case .addressInPlainText: ["content_urls": ["desktop": ["page": "http://de.wikipedia.org/wiki/Watzmann"]]]
            }
        }
    }

    @Test("a summary that is not of an article to show is none", arguments: Unshown.allCases)
    func aSummaryNotToShowIsNone(unshown: Unshown) throws {
        #expect(try WikidataQuery.article(from: Answers.summary(unshown.changes), language: "de") == nil)
    }
}
