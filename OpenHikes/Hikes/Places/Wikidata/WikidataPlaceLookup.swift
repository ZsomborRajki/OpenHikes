//
//  WikidataPlaceLookup.swift
//  OpenHikes
//
//  The place cards' one way to Wikipedia, and what it has already answered.
//
//  A hiker opens a hut's card, closes it, taps the summit beside it and comes
//  back to the hut: in the maker that is ordinary, and every reopening would
//  otherwise be the same four requests for the same paragraph. So what came
//  back is kept for the rest of the launch, in memory and nowhere else — the
//  words are Wikipedia's and the picture is its author's, and neither is
//  written to the device; see ``WikidataPlace``. A card reopened reads it in
//  its first pass, so the section is there when the card is rather than a
//  moment after.
//
//  An answer of *nothing to show* is kept as well: it is an answer, and the
//  same item will give it again. A failure is not kept — offline in a valley
//  is the commonest one, and the next card opened on a better signal should
//  ask. Nor is what a question cut short answered: a card closed before its
//  photograph arrived would otherwise leave *nothing to show* kept for a place
//  that has a photograph. An article whose photograph failed is the one kept
//  in between — drawn by the next card at once, and asked for again, so that
//  card can add the photograph.
//
//  Set once, at the root, as the environment's ``EnvironmentValues/wikidataLookup``,
//  for the reason ``AppTips`` is: the maker's place card, a saved hike's place
//  screen and the place searches' card all read it, through the rows they
//  share, and none of them should have to be handed it.
//

import os
import SwiftUI

/// Asks a ``WikidataPlaceSourcing`` about places, and keeps what it answered.
final class WikidataPlaceLookup {
    /// How many items' answers are kept. A valley's cards are a few dozen
    /// places at most, and an answer with its picture is a hundred kilobytes
    /// or so — a few megabytes for every card a hiker has opened this launch.
    static let capacity = 32

    private static let logger = Logger(subsystem: "OpenHikes", category: "Places")

    private let source: any WikidataPlaceSourcing
    /// Every answer kept, `nil` for *nothing to show*. One that is not
    /// ``WikidataPlace/isComplete`` is kept to be drawn, and asked again.
    private var answers: [String: WikidataPlace?] = [:]
    /// The kept items, oldest first, which is the order they go in.
    private var kept: [String] = []

    init(source: any WikidataPlaceSourcing) {
        self.source = source
    }

    /// What an earlier question about `item` answered, or `nil` when it has
    /// not been answered or there was nothing to show — so a card reopened
    /// can draw its section in the pass that draws the card.
    func answered(_ item: String) -> WikidataPlace? {
        answers[item].flatMap(\.self)
    }

    /// What a card about `item` draws: `described`, the answer the card was
    /// handed, when it is about `item` — and otherwise what an earlier card
    /// was handed. A card the maker hands another place keeps its state, so
    /// an answer about the last place is never drawn under the new one.
    func shown(for item: String?, described: WikidataPlace?) -> WikidataPlace? {
        guard let item else { return nil }
        if let described, described.item == item { return described }
        return answered(item)
    }

    /// A photograph's picture at the width it was fetched at, or `nil` for
    /// bytes that are not one — decoded off the main actor, for the reason
    /// ``CommunityPhotoTile/decode(_:maxPixelSize:)`` is.
    @concurrent
    static func image(from data: Data) async -> Image? {
        guard let cgImage = PhotoDownsampling.image(from: data, maxPixelSize: CommonsPhotoQuery.thumbnailWidth) else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1)
    }

    /// What there is to show about `item`, asked once per launch — and again
    /// while its photograph has failed.
    ///
    /// `nil` for nothing to show, and for a question that failed or was cut
    /// short — which is not kept, and is asked again the next time. Only a
    /// failure is logged: a cancelled question is a card that closed.
    func place(_ item: String) async -> WikidataPlace? {
        if let answered = answers[item], answered?.isComplete ?? true { return answered }
        do {
            let place = try await source.place(item)
            // Cancelled by a card that closed, so it may be less than there
            // is — a picture cut off — and nobody is waiting for it.
            guard !Task.isCancelled else { return nil }
            keep(place, for: item)
            return place
        } catch where Task.isCancelled || error is CancellationError {
            return nil
        } catch {
            Self.logger.info(
                "Wikidata could not be asked about a place: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func keep(_ place: WikidataPlace?, for item: String) {
        // Two cards asking at once both land here; the second answer is the
        // same answer, and is not a second entry.
        if answers.updateValue(place, forKey: item) == nil {
            kept.append(item)
        }
        while kept.count > Self.capacity {
            answers[kept.removeFirst()] = nil
        }
    }
}

// `nonisolated` for the reason the tips' key's extension is: `@Entry` writes
// its key as a type nested in this extension. See *Concurrency* in
// `AGENTS.md`.
nonisolated extension EnvironmentValues {
    /// What the place cards ask Wikipedia through, or `nil` for a launch that
    /// must not ask — set once, by the app's root view. Absent from every
    /// preview and every suite, which is the point of a default; see
    /// ``OpenHikesModel/makeWikidataLookup()``.
    @Entry var wikidataLookup: WikidataPlaceLookup?
}
