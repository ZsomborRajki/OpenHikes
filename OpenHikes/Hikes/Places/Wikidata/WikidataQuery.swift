//
//  WikidataQuery.swift
//  OpenHikes
//
//  What this app asks Wikidata and Wikipedia about a place, and how it reads
//  what comes back.
//
//  ## Two questions, and why the second waits for the first
//
//  **Which article, and which picture?** `wbgetentities` on Wikidata answers
//  with the item's links to the Wikipedias asked about and its statements,
//  of which one is read: the image, `P18`, the file Commons keeps as the
//  picture of that thing. The links are filtered to the hiker's languages by
//  the request, so an item linked to two hundred Wikipedias answers with two.
//
//  **What does it say?** The article's summary from the Wikipedia the first
//  of those languages names — its title, its opening paragraph as plain text
//  and its address. That is Wikipedia's REST summary, the answer its own link
//  previews are drawn from, rather than the whole page.
//
//  The picture is the third question, asked of Commons the way every other
//  photograph here is — see ``CommonsPhotoQuery/imageInfo(ofFileTitled:)``.
//
//  ## Which languages
//
//  The device's two preferred languages, then English, as Wikipedia codes:
//  the app's words follow the device's language, and so does what it reads
//  out of Wikipedia. A hiker whose phone is in German reads the German
//  article, and the English one where there is no German; a hiker whose phone
//  is in a language the app has no words for still reads that language's
//  article where there is one. Measured on 2026-10-30, the Watzmann's item
//  links both the German and the English article; a hut's often links only
//  the German one.
//

import Foundation
import OpenHikesData

nonisolated enum WikidataQuery {
    /// The MediaWiki Action API on Wikidata.
    static let endpoint = URL(string: "https://www.wikidata.org/w/api.php")!

    /// How long the client waits for an answer, in seconds — the patience
    /// ``CommonsPhotoQuery/timeoutInterval`` gives Commons, for the same kind
    /// of question on the same servers.
    static let timeoutInterval: TimeInterval = 15

    /// The language read when none of the device's has an article.
    static let fallbackLanguage = "en"

    /// How many of the device's preferred languages are asked about, before
    /// the fallback.
    static let preferredLanguageLimit = 2

    /// The statement read off the item: its image.
    static let imageProperty = "P18"

    /// The error code Wikidata answers an item that no longer exists with.
    static let missingItemCode = "no-such-entity"

    /// The longest file name Commons allows, in UTF-8 bytes. A longer one is
    /// not the name of a file.
    private static let maximumFileNameBytes = 240

    private static let successRange = 200..<300

    /// The summary of an article that is one, rather than a disambiguation
    /// page or a main page.
    private static let articleType = "standard"

    /// Where a language's Wikipedia is not at its own code: Bokmål is written
    /// at no.wikipedia.org.
    private static let renamedLanguages = ["nb": "no"]

    /// The characters of a title left as they are in a summary's path. A
    /// slash is a character of some titles and a separator of the path, so it
    /// is escaped, as is everything a path or a query reads as syntax.
    private static let titleCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))

    // MARK: - Languages

    /// The Wikipedias asked about, in the order an article is chosen from:
    /// the device's preferred languages, then English, without repeats.
    ///
    /// - Parameter preferred: The device's languages, as `Locale` gives them —
    ///   `de-DE`, `en-GB`.
    static func languages(preferring preferred: [String]) -> [String] {
        var languages: [String] = []
        for identifier in preferred {
            guard languages.count < preferredLanguageLimit else { break }
            if let code = wikipediaCode(for: identifier), !languages.contains(code) {
                languages.append(code)
            }
        }
        if !languages.contains(fallbackLanguage) {
            languages.append(fallbackLanguage)
        }
        return languages
    }

    /// The site id Wikidata files a language's Wikipedia under — `dewiki`.
    static func site(for language: String) -> String {
        "\(language)wiki"
    }

    /// Whether `code` can stand as a Wikipedia's host name: two or three
    /// lowercase letters. Checked rather than trusted because it becomes part
    /// of an address this app connects to.
    static func isWikipediaLanguage(_ code: String) -> Bool {
        (2...3).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isLowercase }
    }

    private static func wikipediaCode(for identifier: String) -> String? {
        guard let language = Locale.Language(identifier: identifier).languageCode?.identifier.lowercased() else {
            return nil
        }
        let code = renamedLanguages[language] ?? language
        return isWikipediaLanguage(code) ? code : nil
    }

    // MARK: - The requests

    /// `item`'s links to the Wikipedias in `languages`, and its statements.
    static func entity(_ item: String, languages: [String]) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "ids", value: item),
            URLQueryItem(name: "props", value: "sitelinks|claims"),
            URLQueryItem(name: "sitefilter", value: languages.map(site(for:)).joined(separator: "|")),
        ]
        // The endpoint is a literal and every value is percent-encoded by
        // `URLComponents`, so this cannot fail; the fallback keeps the type
        // honest rather than force-unwrapped.
        return identified(URLRequest(url: components?.url ?? endpoint))
    }

    /// The summary of the article titled `title` on the Wikipedia in
    /// `language`, or `nil` for a language that cannot be a host name or a
    /// title that cannot be a path.
    static func summary(of title: String, language: String) -> URLRequest? {
        guard isWikipediaLanguage(language),
              let path = title.replacingOccurrences(of: " ", with: "_")
                  .addingPercentEncoding(withAllowedCharacters: titleCharacters),
              !path.isEmpty,
              let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)")
        else { return nil }
        return identified(URLRequest(url: url))
    }

    private static func identified(_ request: URLRequest) -> URLRequest {
        var request = request
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Wikimedia's User-Agent policy covers every one of its services, so
        // this is the header Commons is sent too. See ``TileCache/userAgent``.
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - The answers

    /// The body of a successful response, or the failure its status was.
    static func body(of data: Data, statusCode: Int) throws -> Data {
        guard successRange.contains(statusCode) else {
            throw WikidataPlaceFailure.server(statusCode: statusCode)
        }
        return data
    }

    /// The links and the image a `wbgetentities` answer holds.
    ///
    /// An item that no longer exists — merged into another, or deleted since
    /// the map was tagged — is an answer, an entity with nothing in it, rather
    /// than a failure to ask again.
    static func entity(from data: Data) throws -> WikidataEntity {
        let answer = try JSONDecoder().decode(EntityAnswer.self, from: data)
        if let error = answer.error {
            guard error.code == missingItemCode else { throw WikidataPlaceFailure.refused(code: error.code) }
            return WikidataEntity()
        }
        guard let entity = answer.entities.values.first else { return WikidataEntity() }
        return WikidataEntity(
            articles: entity.sitelinks.compactMapValues { BoundedText.bounded($0.title, to: .title) },
            image: image(among: entity.claims.image)
        )
    }

    /// The image an item's statements name: a preferred one before a normal
    /// one, as Wikidata's own ranking says, and never a deprecated one, which
    /// is a statement somebody has marked as wrong.
    private static func image(among statements: [Statement]) -> String? {
        let preferred = statements.filter { $0.rank == "preferred" }
        let normal = statements.filter { $0.rank == "normal" }
        return (preferred + normal)
            .lazy
            .compactMap(\.mainsnak.file)
            .first { $0.utf8.count <= maximumFileNameBytes }
    }

    /// The article a summary describes, or `nil` for a summary that is not
    /// one to show: a disambiguation page, an empty opening, or an address
    /// that is not a Wikipedia's.
    ///
    /// - Parameter language: The Wikipedia the summary was asked of, which is
    ///   what the article is filed under. Not the summary's own `lang`, which
    ///   for some Wikipedias is not their host name.
    static func article(from data: Data, language: String) throws -> WikipediaArticle? {
        let answer = try JSONDecoder().decode(SummaryAnswer.self, from: data)
        guard answer.type == articleType,
              let title = BoundedText.bounded(answer.titles?.normalized ?? answer.title, to: .title),
              let extract = BoundedText.bounded(answer.extract, to: .notes),
              let url = answer.contentURLs?.desktop?.page.flatMap(URL.init(string:)),
              url.scheme == "https",
              url.host()?.hasSuffix(".wikipedia.org") == true
        else { return nil }
        return WikipediaArticle(title: title, extract: extract, url: url, language: language)
    }
}

/// What a Wikidata item says that a place card reads: its articles and its
/// image.
nonisolated struct WikidataEntity: Equatable, Sendable {
    /// Each article's title, under the site id of its Wikipedia — `dewiki`.
    var articles: [String: String] = [:]
    /// The image's file name on Commons, without the `File:` namespace.
    var image: String?

    /// The first of `languages` with an article, and its title.
    func article(in languages: [String]) -> (language: String, title: String)? {
        languages.lazy.compactMap { language in
            articles[WikidataQuery.site(for: language)].map { (language, $0) }
        }.first
    }
}

// MARK: - The wire format

nonisolated private struct APIError: Decodable {
    let code: String
}

nonisolated private struct EntityAnswer: Decodable {
    let entities: [String: Entity]
    let error: APIError?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entities = try container.decodeIfPresent([String: Entity].self, forKey: .entities) ?? [:]
        error = try container.decodeIfPresent(APIError.self, forKey: .error)
    }

    enum CodingKeys: String, CodingKey {
        case entities = "entities"
        case error = "error"
    }
}

/// One item. Its links and its statements are read leniently: MediaWiki
/// encodes an empty object as `[]`, and an item with no links is an item with
/// nothing to show rather than an unreadable answer.
nonisolated private struct Entity: Decodable {
    let sitelinks: [String: SiteLink]
    let claims: Claims

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sitelinks = (try? container.decodeIfPresent([String: SiteLink].self, forKey: .sitelinks)) ?? [:]
        claims = (try? container.decodeIfPresent(Claims.self, forKey: .claims)) ?? Claims()
    }

    enum CodingKeys: String, CodingKey {
        case sitelinks = "sitelinks"
        case claims = "claims"
    }
}

nonisolated private struct SiteLink: Decodable {
    let title: String
}

/// The statements read: the image, and nothing else. Every other property
/// an item carries is left undecoded, whatever its shape.
nonisolated private struct Claims: Decodable {
    var image: [Statement] = []

    init() { /* an item with no statements */ }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = (try? container.decodeIfPresent([Statement].self, forKey: .image)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case image = "P18"
    }
}

nonisolated private struct Statement: Decodable {
    let rank: String
    let mainsnak: Snak
}

/// A statement's value, read as a file name when it is one. A statement
/// saying *no value* or *unknown value* carries none.
nonisolated private struct Snak: Decodable {
    let file: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try? container.decodeIfPresent(DataValue.self, forKey: .datavalue)
        file = value?.value.flatMap { BoundedText.bounded($0, to: .notes) }
    }

    enum CodingKeys: String, CodingKey {
        case datavalue = "datavalue"
    }
}

nonisolated private struct DataValue: Decodable {
    let value: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try? container.decode(String.self, forKey: .value)
    }

    enum CodingKeys: String, CodingKey {
        case value = "value"
    }
}

nonisolated private struct SummaryAnswer: Decodable {
    struct Titles: Decodable {
        let normalized: String?
    }

    struct ContentURLs: Decodable {
        let desktop: Page?
    }

    struct Page: Decodable {
        let page: String?
    }

    let type: String?
    let title: String?
    let titles: Titles?
    let extract: String?
    let contentURLs: ContentURLs?

    enum CodingKeys: String, CodingKey {
        case type = "type"
        case title = "title"
        case titles = "titles"
        case extract = "extract"
        case contentURLs = "content_urls"
    }
}
