//
//  CommunityPageBudget.swift
//  OpenHikes
//
//  How much of a query's answer one browse request is allowed to collect,
//  once blocked authors are taken out of it.
//
//  Its own type for the reason ``CommunityQueryPolicy`` is: the interesting
//  behaviour is invisible in the result. A request that stopped after one page
//  and a request that spent four look identical from the outside, and the case
//  that made this necessary — a first page of nothing but blocked hikes — is
//  one nobody can see by reading the transport.
//
//  ## Why paging exists at all
//
//  ``CloudKitCommunityTransport`` deliberately asked for one page and dropped
//  the cursor, on the grounds that the limit is already more rows than fit on
//  a phone. That reasoning stops holding the moment rows are removed after the
//  fact. A walker who has blocked a prolific author can be handed a page of
//  twenty-five hikes that are all theirs, and the twenty-sixth — an ordinary
//  hike by somebody else — is then unreachable: the list draws *No shared
//  hikes here*, and asking the same question again returns the same blocked
//  page forever. Blocking one person would have emptied the map.
//
//  So the exclusion happens *before* the budget is spent rather than after it,
//  and a page eaten by blocked rows buys another.
//
//  ## Why the cap is fixed and small
//
//  The public database's quota is shared by every walker using the app, and
//  the thing this is guarding against is pathological rather than ordinary:
//  somebody would have to have blocked most of the authors publishing near
//  them. ``maxRequests`` bounds what that costs. Past it the answer is
//  whatever was collected, including nothing — which is the honest reading of
//  "everything near here is from people you have blocked".
//
//  A walker who has blocked nobody pays exactly one request, as before: the
//  first page satisfies the limit and nothing asks for a second.
//

import Foundation

/// Collects pages of a listing query until there are enough rows a walker is
/// allowed to see, or until the request budget runs out.
nonisolated struct CommunityPageBudget {
    /// How many round trips one browse request may spend.
    ///
    /// Four rather than one because a page can be entirely blocked, and four
    /// rather than unbounded because a walker who has blocked everybody must
    /// not be able to walk the whole table by panning. See this file's header.
    static let maxRequests = 4

    /// How many rows the caller asked for.
    let limit: Int
    /// The authors whose rows do not count towards it.
    let excluded: Set<String>

    private(set) var kept: [CommunityListing] = []
    /// Pages actually fetched. Read by tests, which is the only way the
    /// difference between one round trip and four is observable.
    private(set) var requestsMade = 0

    init(limit: Int, excluding excluded: Set<String>) {
        self.limit = limit
        self.excluded = excluded
    }

    /// Takes one page and says whether another is worth asking for.
    ///
    /// - Parameter hasMore: Whether the server offered a cursor. A page that
    ///   is the last one ends the request however short it left the list —
    ///   asking again would return nothing, twice.
    /// - Returns: `true` when the caller should fetch the next page.
    mutating func accept(_ page: [CommunityListing], hasMore: Bool) -> Bool {
        requestsMade += 1
        // The early return is the ordinary path: most walkers have blocked
        // nobody, and filtering a page against an empty set is a pass over
        // twenty-five rows that can only ever keep all of them.
        kept += excluded.isEmpty ? page : page.filter { !excluded.contains($0.authorID) }
        return hasMore && kept.count < limit && requestsMade < Self.maxRequests
    }

    /// What the caller returns: never more than it asked for, however many
    /// pages it took to find them.
    var results: [CommunityListing] {
        kept.count <= limit ? kept : Array(kept.prefix(limit))
    }
}
