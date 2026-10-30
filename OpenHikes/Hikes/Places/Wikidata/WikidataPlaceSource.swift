//
//  WikidataPlaceSource.swift
//  OpenHikes
//
//  Wikidata, Wikipedia and Commons, asked what they know about one place.
//
//  ## Four requests, two at a time at most
//
//  The item first, because it says which article and which picture there are.
//  Then the article's summary and the picture's details together, because
//  they are on different services and neither needs the other — the summary
//  is Wikipedia's REST API rather than the Action API Wikimedia asks a client
//  to call one at a time, so at most one Action API request is in flight here
//  at any moment. Last, the picture itself, from Wikimedia's image servers.
//  Measured from a desk on 2026-10-30, the four took about a second for the
//  Watzmann, whose picture is 86 KB.
//
//  ## What costs what
//
//  An item with neither an article in the hiker's languages nor a picture
//  costs one request and answers `nil`, which ``WikidataPlaceLookup`` keeps
//  for the launch. An article that has gone since the item linked it is no
//  article. A picture that may not be shown — no image, a licence this app
//  cannot honour, a file that is not a photograph, bytes that are not a
//  picture — is no picture, and the article is shown without it.
//
//  A failure is not an answer, and is asked again the next time the card
//  opens. The item or the article failing throws. The picture failing —
//  Commons busy, the download cut off by a card closed before it arrived —
//  costs the picture this once: beside an article, the article is answered in
//  an answer marked incomplete, so the lookup asks again rather than keeping
//  it; alone, it throws like the rest, because answered as `nil` it would be
//  kept as *nothing to show* and hide the section for the launch.
//
//  ## What is sent
//
//  The item's id, the article's title and the picture's file name, with the
//  app's User-Agent. Not the hiker's position and not who they are — though
//  which place a hiker is reading about can say where they are, which the
//  privacy policy says in those words. Over Low Data Mode nothing is sent at
//  all, as for the Commons photographs: the picture alone is more than the
//  rest of the card, for a hiker who turned that on to spend less.
//

import Foundation
import OpenHikesData
import os

/// Wikidata, Wikipedia and Commons, through their public APIs.
nonisolated struct WikidataPlaceSource: WikidataPlaceSourcing {
    /// The seam a suite replaces — ``WikimediaCommonsSource/Transport``'s
    /// shape, and for the same reason: nothing here may reach the network
    /// from a test.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// What an article that does not exist is answered with.
    private static let notFound = 404

    private static let logger = Logger(subsystem: "OpenHikes", category: "Places")

    /// Ephemeral, uncached and refused over Low Data Mode — see this file's
    /// header. The session ``WikimediaCommonsSource`` uses has the same
    /// configuration, for the same services.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": TileCache.userAgent]
        return URLSession(configuration: configuration)
    }()

    /// The Wikipedias asked, in the order an article is chosen from — see
    /// ``WikidataQuery/languages(preferring:)``.
    let languages: [String]
    private let transport: Transport

    init(
        languages: [String] = WikidataQuery.languages(preferring: Locale.preferredLanguages),
        transport: Transport? = nil
    ) {
        self.languages = languages
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    @concurrent
    func place(_ item: String) async throws -> WikidataPlace? {
        let entity = try await WikidataQuery.entity(from: body(of: WikidataQuery.entity(item, languages: languages)))
        async let picture = photo(named: entity.image)
        let summary = try await article(in: entity)
        do {
            return WikidataPlace(item: item, article: summary, photo: try await picture)
        } catch {
            // A picture that could not be had is not a picture there is none
            // of. With no article it was the whole answer — see this file's
            // header.
            guard let summary else { throw error }
            Self.logger.info("A place's photograph failed: \(String(describing: error), privacy: .public)")
            return WikidataPlace(item: item, article: summary, photo: nil, isComplete: false)
        }
    }

    /// The summary of the first article `entity` links in ``languages``, or
    /// `nil` for none — no link, or a link to a page that has gone or is not
    /// an article.
    private func article(in entity: WikidataEntity) async throws -> WikipediaArticle? {
        guard let (language, title) = entity.article(in: languages),
              let summary = WikidataQuery.summary(of: title, language: language)
        else { return nil }
        let (data, statusCode) = try await transport(summary)
        guard statusCode != Self.notFound else { return nil }
        return try WikidataQuery.article(
            from: WikidataQuery.body(of: data, statusCode: statusCode),
            language: language
        )
    }

    /// The photograph named `name`, with its credit, or `nil` for no name
    /// and for every way a picture can fail to be one this app shows.
    ///
    /// Throws when the picture could not be had at all — Commons busy or out
    /// of reach, the download cut off — which ``place(_:)`` tells apart from
    /// a picture there is none of.
    private func photo(named name: String?) async throws -> WikidataPhoto? {
        guard let name else { return nil }
        let files = try await CommonsPhotoQuery.files(
            from: commonsBody(of: CommonsPhotoQuery.imageInfo(ofFileTitled: name))
        )
        // `files(from:)` has already left out what may not be shown — the
        // licence, the type, the size and the host are checked there.
        guard let file = files.first else { return nil }
        let image = try await commonsBody(of: CommonsPhotoQuery.download(file.thumbnailURL))
        guard ImageDataFormat.detect(in: image) != nil else { return nil }
        return WikidataPhoto(credit: file.credit, imageData: image)
    }

    private func body(of request: URLRequest) async throws -> Data {
        let (data, statusCode) = try await transport(request)
        return try WikidataQuery.body(of: data, statusCode: statusCode)
    }

    /// A Commons answer, read the way every other one is. There is no second
    /// try after a busy one here, as there is for a route's photographs: the
    /// next card to open asks again instead.
    private func commonsBody(of request: URLRequest) async throws -> Data {
        let (data, statusCode) = try await transport(request)
        return try CommonsPhotoQuery.body(of: data, statusCode: statusCode)
    }
}
