//
//  WikidataPlace.swift
//  OpenHikes
//
//  What Wikipedia says about a place OpenStreetMap links to Wikidata.
//
//  A place card knew what the map says about a hut — its height, its hours,
//  whether there is water — and nothing about the hut itself. Wikipedia does,
//  in the hiker's own language, and OpenStreetMap already says which article
//  to read: the element's `wikidata` tag names the item, and the item names
//  the article in every language that has one. So this asks by that link, an
//  exact join rather than a search near the place, which is why it is the
//  Wikipedia article *about this hut* and never one about a hut nearby.
//
//  ## Where the link is
//
//  Measured on 2026-10-30 over the Berchtesgaden box the place search tests
//  use: 9 of 15 huts carried the tag, 72 of 200 summits and 10 of 26 named
//  lakes, against 2 of 124 viewpoints and 2 of 19 waterfalls. Of 137 hiking
//  routes, 3 did, every one of them a long-distance path. So this is for the
//  card of a place, the kinds a hiker taps to read about; most cards have
//  no link, and draw what they drew before.
//
//  ## A photograph without an article is still worth showing
//
//  The same day, the items behind those links: of the 9 huts, 8 had a German
//  article, none an English one, and all 9 named a photograph; of 72 summits,
//  40 German, 15 English and 34 photographs; of 10 lakes, 7, 3 and 10. So a
//  phone in English reading a German valley finds an article for few of its
//  huts and a picture of every one, and a card that needed both would have
//  shown that hiker nothing. The section stands on either half — see
//  ``WikidataPlaceSection``.
//
//  ## Asked on open, never for a list
//
//  The rule the Commons photographs and the curated routes' heights follow,
//  and for the same reason: a search finds hundreds of places and a hiker
//  opens one. Nothing here runs until a card is drawn with an item on it, and
//  what came back is kept in memory for the rest of the launch — see
//  ``WikidataPlaceLookup`` — and nowhere else.
//
//  ## Shown, never kept
//
//  Only the item is written down, on the place, because it is OpenStreetMap's
//  fact about the place. The article's words are Wikipedia's, under CC BY-SA,
//  and the photograph is its author's, under the licence Commons names: both
//  are drawn with their credit and their link, and neither is copied into a
//  hike, a shared file or a community upload. That is what keeps the
//  share-alike terms on the screen they are shown on.
//

import Foundation

/// What a place card shows from Wikimedia: the article OpenStreetMap's link
/// leads to, the item's photograph, or both — never neither, which is no
/// answer to show and is `nil` instead. See ``init(item:article:photo:)``.
nonisolated struct WikidataPlace: Equatable, Sendable {
    /// The Wikidata item asked about — `Q` and a number — which is what a
    /// card holds this answer against.
    let item: String
    /// `nil` for an item with no article in any of the hiker's languages.
    let article: WikipediaArticle?
    /// `nil` for an item that names no image, names one this app may not
    /// show, or whose picture did not arrive.
    let photo: WikidataPhoto?

    /// What there is to show about `item`, or `nil` when there is nothing.
    init?(item: String, article: WikipediaArticle?, photo: WikidataPhoto?) {
        guard article != nil || photo != nil else { return nil }
        self.item = item
        self.article = article
        self.photo = photo
    }

    /// The section's heading: where what it shows comes from, the way a
    /// place's subtitle says *From OpenStreetMap*. A photograph with no
    /// article beside it is Commons', and a heading naming Wikipedia would
    /// claim words the section does not have.
    var heading: String {
        article == nil
            ? String(localized: "From Wikimedia Commons")
            : String(localized: "From Wikipedia")
    }
}

/// One Wikipedia article's summary: its title, its opening paragraph and
/// where to read the rest.
nonisolated struct WikipediaArticle: Equatable, Sendable {
    var title: String
    /// The article's opening, as plain text, bounded the way prose arriving
    /// from elsewhere is — see ``WikidataQuery/article(from:)``.
    var extract: String
    /// The article itself, on the Wikipedia it was read from.
    var url: URL
    /// The language code of that Wikipedia — `de` for de.wikipedia.org.
    var language: String
}

/// The photograph a Wikidata item names, as Commons served it, and the credit
/// it is owed.
nonisolated struct WikidataPhoto: Equatable, Sendable {
    var credit: CommonsPhotoCredit
    /// The thumbnail's bytes. Kept encoded, and decoded where it is drawn —
    /// see ``WikidataPlacePhotoView`` — because a few dozen of these held as
    /// bitmaps would be a hundred megabytes for cards nobody has open.
    var imageData: Data
}

/// Where a place card's Wikipedia section comes from.
///
/// A protocol for the reason ``CommonsPhotoSourcing`` is one: the conformance
/// that ships reaches three Wikimedia services, and no suite may reach any.
nonisolated protocol WikidataPlaceSourcing: Sendable {
    /// What Wikipedia and Commons have about `item`, or `nil` when there is
    /// nothing to show: an item with neither an article in any language asked
    /// for nor a photograph this app may show, or an item that no longer
    /// exists.
    ///
    /// Throws when the answer could not be had at all — offline, refused,
    /// busy. The difference is what ``WikidataPlaceLookup`` keeps: `nil` is an
    /// answer, and a failure is asked again the next time the card opens.
    @concurrent
    func place(_ item: String) async throws -> WikidataPlace?
}

/// Why asking Wikidata or Wikipedia produced nothing usable.
///
/// Never shown to a hiker — a card whose question failed draws what it drew
/// before — so these exist to be logged and to keep the branches apart in a
/// test.
nonisolated enum WikidataPlaceFailure: Error, Equatable {
    /// The API answered with an error of its own.
    case refused(code: String)
    case server(statusCode: Int)
}
