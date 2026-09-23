//
//  TrailLegMemo.swift
//  OpenHikes
//
//  The shapes this drawing has already been given, kept so that editing it
//  does not ask for them again.
//
//  Phase 2 could get away without this. A line that only ever grows keeps
//  every leg it has resolved, because ``TrailDraft``'s `rebuildLegs` matches
//  the legs it already holds against the new list by ``TrailLegEnds`` and a
//  new point at the end changes none of them. Editing breaks that in the
//  ordinary case: deleting a point drops two legs and makes one, putting it
//  back asks for the two again, and neither of them is in the list any more
//  to be matched against.
//
//  So the settled answers are remembered separately from the list they are
//  currently arranged into. The effect a hiker sees is that **a stop put back
//  where it was restores the line rather than redrawing it straight and
//  fetching it again** — and the same is true of a reorder that puts an
//  adjacency back and of dragging a point away and back.
//
//  ## What is remembered, and what deliberately is not
//
//  Only ``TrailLegSnap/snapped`` and ``TrailLegSnap/unmapped(_:)``: the two
//  that are *answers*. A refusal is not remembered for the same reason
//  ``OverpassTrailLegRouter`` does not cache one — *Retry* has to be able to
//  ask again — and neither ``TrailLegSnap/freehand`` nor
//  ``TrailLegSnap/routing`` is worth a slot, since a leg that is not
//  remembered is born straight and freehand anyway.
//
//  ## Why it is bounded, and why by insertion rather than by use
//
//  A long editing session resolves a leg per adjacency it ever had, and a
//  snapped leg through a valley is hundreds of coordinates. Unbounded, this
//  would be a drawing that grows in memory for as long as it is edited — and
//  it is a convenience, so the failure of dropping one is a leg re-asked from
//  the router, which usually answers from its own cache without a request.
//
//  Oldest-first rather than least-recently-used, because the two differ only
//  under a pattern this cannot have: the legs of one drawing are all near each
//  other and are re-asked in bursts, so recency and age order them almost
//  identically, and an eviction policy that needs a touch on every read is a
//  write on the drawing's hottest path.
//

import Foundation

/// The settled leg shapes a drawing has been given, bounded.
nonisolated struct TrailLegMemo: Equatable, Sendable {
    /// How many settled legs are kept.
    ///
    /// Generous against what a drawing actually produces — a twenty-point
    /// trail has nineteen legs, and every edit to it adds at most two
    /// adjacencies — so the cap is reached only by a session that has been
    /// rearranged for a long time, which is exactly the one that should stop
    /// growing.
    static let capacity = 256

    private var shapes: [TrailLegEnds: TrailLeg] = [:]
    /// The keys in the order they were first written, which is what an
    /// eviction takes from the front of.
    private var order: [TrailLegEnds] = []

    var isEmpty: Bool { shapes.isEmpty }
    var count: Int { shapes.count }

    /// Remembers `leg`, if it is the kind worth remembering.
    ///
    /// Silently ignores the others rather than refusing them, because every
    /// caller would otherwise have to repeat the rule above — and the rule is
    /// about the leg rather than about the caller.
    mutating func remember(_ leg: TrailLeg) {
        guard Self.isWorthRemembering(leg.snap) else { return }
        if shapes.updateValue(leg, forKey: leg.ends) == nil {
            order.append(leg.ends)
            evictIfNeeded()
        }
    }

    mutating func remember(_ legs: [TrailLeg]) {
        for leg in legs { remember(leg) }
    }

    /// The shape this leg was last given, retargeted at the waypoint it now
    /// arrives at, or `nil` if it has not been resolved.
    ///
    /// Retargeted here rather than by the caller because the identity is the
    /// one thing about a remembered leg that is *not* still true: the ends are
    /// two places and do not move, but which waypoint the leg arrives at is a
    /// fact about the list it is currently in.
    func leg(_ ends: TrailLegEnds, arrivingAt id: UUID) -> TrailLeg? {
        guard var leg = shapes[ends] else { return nil }
        leg.id = id
        return leg
    }

    /// Whether a leg in this state is an answer rather than a failure or a
    /// state of waiting. See the file header.
    private static func isWorthRemembering(_ snap: TrailLegSnap) -> Bool {
        switch snap {
        case .snapped, .unmapped: true
        case .freehand, .refused, .directionsUnavailable, .routing: false
        }
    }

    private mutating func evictIfNeeded() {
        while order.count > Self.capacity {
            shapes.removeValue(forKey: order.removeFirst())
        }
    }
}

/// A router's settled answers by their two ends, bounded the way the memo is.
///
/// Each router lives as long as the app does — the maker holds one per travel
/// mode — so an unbounded cache is a line drawn in May still in memory in
/// August, a few hundred coordinates per leg ever asked. Oldest first past
/// ``TrailLegMemo/capacity``, for the reason the memo gives; losing one costs
/// a question, which for the trail graph is usually answered from the tiles
/// on disk.
nonisolated struct TrailLegAnswerCache: Sendable {
    private var answers: [TrailLegEnds: TrailLegRoute] = [:]
    /// The keys in the order they were first answered.
    private var order: [TrailLegEnds] = []

    var count: Int { answers.count }

    subscript(ends: TrailLegEnds) -> TrailLegRoute? { answers[ends] }

    /// Keeps `route` as the answer for `ends`. Only a settled answer belongs
    /// here — a refusal is never cached, so *Try Again* can ask again.
    mutating func store(_ route: TrailLegRoute, for ends: TrailLegEnds) {
        if answers.updateValue(route, forKey: ends) == nil { order.append(ends) }
        while order.count > TrailLegMemo.capacity {
            answers.removeValue(forKey: order.removeFirst())
        }
    }
}
