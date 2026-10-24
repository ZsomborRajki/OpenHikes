//
//  HikeNameMatch.swift
//  OpenHikes
//
//  One answer to "does this name match what was asked for".
//
//  ## Why it is its own type
//
//  ``HikeSearch`` ranks the hiker's own hikes against what they type into the
//  sheet, and it is mostly a cache: when to rank again, and what to keep. This
//  is the ranking it caches — the rule itself, apart from the bookkeeping.
//
//  ## What does not use it
//
//  Siri, the shortcut picker and the widget's configuration picker resolve a
//  name through ``HikeEntityQuery``, which matches against the App Group
//  catalogue with `SharedHikeCatalog.hikes(matching:)`. That lives in
//  OpenHikesShared, which cannot see this type, and it is deliberately the
//  weaker match: case and diacritics fold but width does not, a blank query is
//  every hike rather than none, and the order is the catalogue's, newest
//  first, rather than prefix first. Making the two one rule would mean moving
//  this type into that package, which it could do, since it needs only
//  Foundation.
//
//  ## The rule
//
//  Case, diacritics and width are all folded away, because none of them is
//  something a hiker is choosing when they name or look for a trail: "Thumsee"
//  and "thumsee" are the same walk, and so are "Zürichberg" and "Zurichberg",
//  which is what a keyboard without an umlaut types.
//
//  `contains` rather than `hasPrefix`, with a prefix *ranked above* a mere
//  containment. Anchoring outright would lose "Ridge" for a hike called
//  "North Ridge Trail", which is the name a hiker is most likely to reach for.
//

import Foundation

/// The folding and ordering both name searches share.
nonisolated enum HikeNameMatch {
    static let foldingOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]

    /// `name` reduced to the form two names are compared in.
    static func key(_ name: String, locale: Locale = .current) -> String {
        name.folding(options: foldingOptions, locale: locale)
    }

    /// How well a folded name answers a folded query, or `nil` for one that
    /// does not answer it at all.
    ///
    /// Lower is better, and the two ranks are the whole of the ordering:
    /// a name that *starts* with the query before one that merely contains it,
    /// then alphabetically among equals. Returned as a number rather than a
    /// `Bool` because it is both the filter and the sort key, so the two
    /// cannot read different rules.
    static func rank(nameKey: String, queryKey: String) -> Int? {
        guard nameKey.contains(queryKey) else { return nil }
        return nameKey.hasPrefix(queryKey) ? 0 : 1
    }

    /// The indices of `names` that answer `query`, best first.
    ///
    /// Over indices rather than over the names themselves so a caller can
    /// carry whatever it was ranking — a `Hike`, an entity, a row — without
    /// this knowing what that is.
    static func rankedIndices(of names: [String], matching query: String) -> [Int] {
        let locale = Locale.current
        let queryKey = key(query, locale: locale)
        return names.indices
            .compactMap { index -> (index: Int, rank: Int, nameKey: String)? in
                let nameKey = key(names[index], locale: locale)
                guard let rank = rank(nameKey: nameKey, queryKey: queryKey) else { return nil }
                return (index, rank, nameKey)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.nameKey < rhs.nameKey
            }
            .map(\.index)
    }
}
