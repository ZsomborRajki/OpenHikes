//
//  TrailPointSource.swift
//  OpenHikes
//
//  Where the places near a drawn trail come from.
//
//  One request, one answer, and nothing kept. That is the whole difference
//  between this and ``CuratedTrailSource``, which caches in memory and on disk
//  because its unit is a *relation* a hiker comes back to — panning to an area
//  again, opening a route whose line the list already fetched. There is no
//  equivalent here: what a search answers is drawn as candidates and is gone
//  on the next search or when the maker closes, deliberately, because nothing
//  offered has been chosen. Caching a page of things nobody took would be
//  keeping a list of everything a hiker has ever looked past.
//
//  The manners — the rate-limit gate, the one retry a busy answer gets, the
//  `User-Agent`, the reading of a `200` carrying a `remark` — are
//  ``OverpassConversation``'s and are not written again here. This type is the
//  query, the decode and the seam.
//
//  A `struct` rather than an actor for exactly that reason: it holds nothing
//  mutable. The conversation behind it does, and that one is an actor.
//

import Foundation

/// Where the trail maker's *Search this area* gets its answers.
///
/// A protocol for the same reason ``CuratedTrailSourcing`` and
/// ``TrailLegRouting`` are: the conformance below reaches a volunteer-run
/// public API, and no suite may. It is also the seam a launch that must not
/// ask goes through by simply not having one — see
/// ``TrailPointFinder/isAvailable``, which withdraws the pill rather than
/// offering a button that cannot answer.
nonisolated protocol TrailPointSourcing: Sendable {
    /// Every place worth offering within `area`, in no particular order.
    ///
    /// Unordered by contract, because the order that matters is against the
    /// line the hiker is drawing and that is not a thing a source knows — see
    /// ``TrailPointRanking``.
    ///
    /// Answers `[]` rather than throwing for an area too wide to ask about —
    /// see ``TrailPointQuery/maximumRadiusMeters``. That is an answer: at that
    /// zoom a map of five hundred pins is not what anybody asked for.
    ///
    /// Throws what Overpass said, which the caller draws as a caption rather
    /// than as a broken editor: **nothing here may ever block drawing.**
    @concurrent
    func places(near area: CommunitySearchArea) async throws -> [TrailPlace]
}

/// Places from the public Overpass API.
nonisolated struct TrailPointSource: TrailPointSourcing {
    typealias Transport = @Sendable (URLRequest) async throws -> OverpassHTTPResponse

    private let conversation: OverpassConversation

    /// - Parameters:
    ///   - clock: See *Deliberate test seams* in the repository instructions.
    ///     The rate-limit gate is only observable against time somebody else
    ///     is holding.
    ///   - transport: `nil` builds the live one, which is the only thing here
    ///     that reaches the network.
    init(
        endpoint: URL = OverpassRequest.defaultEndpoint,
        clock: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        transport: Transport? = nil
    ) {
        conversation = OverpassConversation(
            subject: "a place search",
            endpoint: endpoint,
            clock: clock,
            pause: pause,
            transport: transport
        )
    }

    func places(near area: CommunitySearchArea) async throws -> [TrailPlace] {
        let boxes = TrailPointQuery.searchBoxes(for: area)
        guard let query = TrailPointQuery.query(in: boxes) else { return [] }
        return try await conversation.fetch(query, awaiting: TrailPointQuery.timeoutSeconds) { body in
            try TrailPointDecoding.places(from: body)
        }
    }
}
