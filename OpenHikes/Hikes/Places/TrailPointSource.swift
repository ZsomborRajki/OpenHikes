//
//  TrailPointSource.swift
//  OpenHikes
//
//  Where the places near a drawn trail come from.
//
//  One request, one answer, and — for now — nothing kept. That is the whole
//  difference between this and ``CuratedTrailSource``, which caches in memory
//  and on disk because its unit is a *relation* a hiker comes back to: panning
//  to an area again, opening a route whose line the list already fetched. What
//  a search answers here is drawn as candidates and is gone on the next search
//  or when the maker closes.
//
//  **That is a deferral rather than a decision, and the issue records which.**
//  A store of the same shape ``CuratedTrailStore`` has — one file per element,
//  read back only as *what happens to be on this device near here* — is worth
//  having for the case this type otherwise handles badly: a refused search
//  draws an empty map, in a valley that may have answered an hour ago, and
//  three of five first attempts came back `504` the day this was measured. It
//  is listed under Phase 6 of #607 with the two constraints it has to keep: the
//  OSM element id belongs on the stored record and never on ``TrailPlace``,
//  which is the value ``TrailPoint`` mirrors, and the file cap is picked
//  against the fetch rather than copied from the curated one — a page there is
//  25 relations, and one search here fetches some 578 elements to offer 40.
//
//  What stays refused is the *other* shape: one file per search **box**, so a
//  later search inside a stored one costs no request. That is the coverage
//  index this repository has already declined once, and a box that merely
//  overlaps answers partially while looking complete.
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
