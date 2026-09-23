//
//  TrailPointSource.swift
//  OpenHikes
//
//  Where the places near a drawn trail come from.
//
//  One request, one answer, and nothing held in memory. What a search answers
//  is drawn as candidates and is gone on the next search or when the maker
//  closes — unlike ``CuratedTrailSource``, whose unit is a *relation* a hiker
//  comes back to and which therefore keeps a memory cache in front of its disk
//  one.
//
//  **What is kept is on disk, and it is kept for one case.** A refused search
//  would otherwise draw an empty map in a valley that answered an hour ago,
//  and three of five first attempts came back `504` the day this was measured.
//  So a successful search is written down, and the failure branch of a search
//  — and nowhere else — reads it back as *what happens to be on this device
//  near here*. See ``TrailPointStore``, which owns that bargain, the cap and
//  the argument for both.
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
//  mutable. The conversation behind it does, and that one is an actor; the
//  store is a value over a directory, like ``CuratedTrailStore``.
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

    /// Places already on this device standing within `area`, nearest its
    /// centre first, asking nothing of Overpass.
    ///
    /// **What a refused search draws instead of nothing.** It makes no claim
    /// to be the area's places — nothing records which areas have been
    /// searched — so it is only ever used where the alternative is an empty
    /// map and the hiker has already been told the search was refused. The
    /// same bargain ``CuratedTrailSourcing/cachedTrails(near:limit:)`` makes
    /// one feature over, and for the same reasons.
    ///
    /// Never throws. A cache with nothing in it is an answer, and this is
    /// reached on a path where something has already failed.
    @concurrent
    func cachedPlaces(near area: CommunitySearchArea, limit: Int) async -> [TrailPlace]
}

nonisolated extension TrailPointSourcing {
    /// Nothing, for a source that keeps nothing.
    ///
    /// A default rather than a requirement every conformance restates: the
    /// stand-ins a suite runs against reach no network, so there is nothing
    /// for them to have failed to reach and nothing for them to fall back to.
    @concurrent
    func cachedPlaces(near area: CommunitySearchArea, limit: Int) async -> [TrailPlace] { [] }
}

/// Places from the public Overpass API.
nonisolated struct TrailPointSource: TrailPointSourcing {
    typealias Transport = @Sendable (URLRequest) async throws -> OverpassHTTPResponse

    private let conversation: OverpassConversation
    /// Where an answer is written down, or `nil` for a launch with nowhere to
    /// write — which is what a `Caches` directory the system will not name
    /// looks like.
    private let store: TrailPointStore?

    /// - Parameters:
    ///   - clock: See *Deliberate test seams* in the repository instructions.
    ///     The rate-limit gate is only observable against time somebody else
    ///     is holding, and so is a stored place's age.
    ///   - directory: where answers are kept. `nil` keeps nothing, which is
    ///     what a suite about the wire format wants.
    ///   - transport: `nil` builds the live one, which is the only thing here
    ///     that reaches the network.
    init(
        endpoint: URL = OverpassRequest.defaultEndpoint,
        clock: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        directory: URL? = TrailPointStore.defaultDirectory(),
        transport: Transport? = nil
    ) {
        conversation = OverpassConversation(
            subject: "a place search",
            endpoint: endpoint,
            clock: clock,
            pause: pause,
            transport: transport
        )
        store = directory.map { TrailPointStore(directory: $0, clock: clock) }
    }

    func places(near area: CommunitySearchArea) async throws -> [TrailPlace] {
        let boxes = TrailPointQuery.searchBoxes(for: area)
        guard let query = TrailPointQuery.query(in: boxes) else { return [] }
        let found = try await conversation.fetch(
            query,
            awaiting: TrailPointQuery.timeoutSeconds
        ) { body in
            try TrailPointDecoding.found(in: body)
        }
        // Written before the answer is handed back, and everything Overpass
        // said rather than the forty that will be drawn: which forty those are
        // was decided against the line as it stood, and a hiker who has drawn
        // somewhere else since would come back to a fall-back ranked for a
        // trail they no longer have. See ``TrailPointStore``.
        store?.save(found)
        return found.map(\.place)
    }

    /// `@concurrent` rather than taking the caller's isolation, for the reason
    /// ``CuratedTrailSource/cachedTrails(near:limit:)`` is: it reads every file
    /// in the cache directory, which is not work to do on the actor a hiker is
    /// waiting on — and it is what the requirement asks for, so a version
    /// without it would be witnessed by the protocol extension's `[]` instead
    /// and this would quietly never run.
    @concurrent
    func cachedPlaces(near area: CommunitySearchArea, limit: Int) async -> [TrailPlace] {
        store?.places(near: area, limit: limit) ?? []
    }
}
