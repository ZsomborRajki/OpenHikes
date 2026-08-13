//
//  HikeSearch.swift
//  OpenTrails
//
//  Ranking the user's own hikes against the search query, and the memo that
//  keeps that ranking off the sheet's per-body path.
//

import Foundation

/// Imported/recorded hikes whose title matches the current query, with titles
/// that start with the query ranked above ones that merely contain it —
/// surfaced above map suggestions so a user's own trails come first.
///
/// The ranking folds every title and sorts the survivors, so it is the one
/// real cost in `MapSheet.body` — and that body runs far more often than the
/// query changes. Every detent change a sheet drag produces re-evaluates it,
/// as does any unrelated invalidation while the field is focused (a completer
/// result arriving, a selection changing). So the result is kept here, across
/// body passes, rather than rebuilt on each one.
///
/// The cache is keyed by what the ranking actually reads: the trimmed query,
/// and each hike's identity *and* title in order. Titles are part of the key
/// because a rename changes the ranking without changing the list; identity is
/// part of it because two trails can share a title, and returning the previous
/// pass's `Hike` objects for a list that has since been replaced would hand
/// the sheet rows pointing at deleted models.
final class HikeSearch {
    /// The trimmed query ``results`` answers. Empty means nothing is cached.
    private var query = ""
    /// The `hikes` argument that produced ``results``, reduced to the two
    /// properties the ranking depends on.
    private var inputs: [(id: UUID, title: String)] = []
    private var results: [Hike] = []

    /// Full re-ranks performed. The memo is otherwise invisible from outside —
    /// a cached pass and a recomputed one return the same hikes — so this is
    /// what pins it in tests.
    private(set) var rankingPasses = 0

    private static let foldingOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]

    func rankedHikes(matching searchText: String, in hikes: [Hike]) -> [Hike] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // No query, no results — and no reason to keep holding the last set of
        // hikes, which clearing the search field is the user's way of saying
        // they're done with. Retaining them here would keep a deleted trail's
        // model alive for as long as the sheet is on screen.
        guard !trimmedQuery.isEmpty else {
            reset()
            return []
        }

        if trimmedQuery == query, isCacheValid(for: hikes) { return results }

        rankingPasses += 1
        query = trimmedQuery
        inputs = hikes.map { (id: $0.id, title: $0.title) }
        results = Self.rank(inputs, matching: trimmedQuery)
            .map { hikes[$0] }
        return results
    }

    /// Drops the cached ranking and everything it holds onto.
    func clear() { reset() }

    private func reset() {
        query = ""
        inputs = []
        results = []
    }

    /// Cheap enough to run on every body pass — the point of the whole
    /// exercise — because it compares two values per hike and allocates
    /// nothing, where the ranking folds a string per hike and then sorts.
    private func isCacheValid(for hikes: [Hike]) -> Bool {
        guard inputs.count == hikes.count else { return false }
        for (cached, hike) in zip(inputs, hikes) where cached.id != hike.id || cached.title != hike.title {
            return false
        }
        return true
    }

    /// The ranking itself, over indices into the caller's array so the cached
    /// key and the cached result are built from one pass over the titles.
    private static func rank(_ inputs: [(id: UUID, title: String)], matching query: String) -> [Int] {
        let locale = Locale.current
        let queryKey = query.folding(options: foldingOptions, locale: locale)

        return inputs.indices
            .compactMap { index -> (index: Int, prefixRank: Int, titleKey: String)? in
                let titleKey = inputs[index].title.folding(options: foldingOptions, locale: locale)
                guard titleKey.contains(queryKey) else { return nil }
                return (index, titleKey.hasPrefix(queryKey) ? 0 : 1, titleKey)
            }
            .sorted { lhs, rhs in
                if lhs.prefixRank != rhs.prefixRank {
                    return lhs.prefixRank < rhs.prefixRank
                }
                return lhs.titleKey < rhs.titleKey
            }
            .map(\.index)
    }
}
