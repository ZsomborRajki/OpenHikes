//
//  SeededWikidataPlaceSource.swift
//  OpenHikes
//
//  What Wikipedia says about the seeded summit, said by nobody.
//
//  The Wikidata half of `--ui-test-trail-points=seeded`, behind the same door
//  as ``SeededCommonsPhotoSource``: a launch gets one only by naming that
//  scenario, the whole file is `#if DEBUG`, and no suite reaches Wikimedia by
//  falling into anything. ``SeededTrailPointSource``'s summit carries
//  ``item``; every other place carries none, so a card for any of them draws
//  what it drew before this existed.
//
//  What is faked is only the network. The words, the link and the photograph
//  go through the real lookup, the real section and the real credit — so an
//  accessibility audit of the summit's card audits the section a hiker sees.
//

import CoreGraphics
import Foundation
import OpenHikesData

#if DEBUG

/// A stand-in for Wikidata, Wikipedia and Commons that knows one place.
nonisolated struct SeededWikidataPlaceSource: WikidataPlaceSourcing {
    /// The item the seeded summit links to: Wikidata's own sandbox, so the
    /// one id that could ever leave a seeded launch names nothing real.
    static let item = "Q4115189"

    static let article = WikipediaArticle(
        title: "Thumsee Kopf",
        extract: """
        Thumsee Kopf is a wooded summit above the Thumsee, a small lake west of Bad Reichenhall. \
        A path climbs to it from the lake's eastern shore.
        """,
        url: articleURL,
        language: "en"
    )

    /// Who took the photograph, and what it is shared under.
    static let author = "Lena Gruber"
    static let licenseName = "CC BY 4.0"

    /// A frame the seeded Commons photographs do not use, so the two never
    /// draw the same picture.
    private static let frame = 12
    /// The width Commons' thumbnails are fetched at, and a landscape's height.
    private static let frameWidth = 960.0
    private static let frameHeight = 640.0
    private static let frameSize = CGSize(width: frameWidth, height: frameHeight)
    // swiftlint:disable force_unwrapping
    private static let articleURL = URL(string: "https://en.wikipedia.org/wiki/Wikipedia:Sandbox")!
    private static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    private static let filePage = URL(string: "https://commons.wikimedia.org/wiki/File:Seeded_place_photo.jpg")!
    // swiftlint:enable force_unwrapping

    @concurrent
    func place(_ item: String) async -> WikidataPlace? {
        guard item == Self.item else { return nil }
        let photo = await SeededPhotoFixture.encodedImage(index: Self.frame, size: Self.frameSize).map { data in
            WikidataPhoto(
                credit: CommonsPhotoCredit(
                    author: Self.author,
                    license: HikePhotoLicense(name: Self.licenseName, url: Self.licenseURL, sourceURL: Self.filePage)
                ),
                imageData: data
            )
        }
        return WikidataPlace(item: item, article: Self.article, photo: photo)
    }
}

#endif
