//
//  HikePlacesAroundSearch.swift
//  OpenHikes
//
//  What *Places Around Trail* has found, and what of it the screen shows.
//
//  ## Asked once, filtered many times
//
//  The line is asked about once, as far out as the widest *Within* the hiker
//  has chosen and for the kinds switched on — see ``TrailPlaceCorridorSearch``.
//  Every answer keeps where it sits against the line, worked out off the main
//  actor as it lands, so narrowing *Within* or switching a kind off is a
//  filter over rows already measured rather than another request to a
//  volunteer-run server. Only widening *Within*, or switching on a kind the
//  last request left out, asks again.
//
//  ## Two ways a place is found, and one list
//
//  Along the line, within the chosen reach; and in an area the hiker pointed
//  the map at and asked about with *Search This Area*. A place found the second
//  way is shown whatever the reach — the hiker asked about that spot — which is
//  what lets a summit across the valley be added to a trail that never climbs
//  it.
//
//  Adding is immediate, one place at a time, the way Apple Maps adds a place to
//  a guide: each goes through ``HikePlaceChange``, which saves before it
//  answers. There is no *Add* for a batch and no *Cancel* to lose it with.
//
//  ## Kept for as long as the screen is on the stack
//
//  The screen is drawn in the sheet in portrait and in the side panel in
//  landscape, so a turn of the phone builds it again. While this was the
//  screen's own state, the screen built in the new host started from nothing:
//  the open card closed, the *Within* chosen and what *Search This Area* added
//  were gone, and the line was asked about again (#1170). ``SheetPresentation``
//  keeps one of these for each such screen on the stack, as it keeps *Add
//  Place*'s form, and lets it go when the screen is popped, withdrawing a
//  request still out. Until then a request goes on through a turn, or a screen
//  pushed over this one, and the screen that comes up waits for its answer
//  rather than asking again.
//

import Algorithms
import CoreLocation
import Foundation
import Observation
import OpenHikesData
import os
import SwiftData

/// How far off the line *Places Around Trail* looks.
enum TrailPlaceReach: Hashable, Identifiable {
    case around
    case nearby
    /// What a hiker walking the line passes — the maker's save rule.
    case onTrail

    /// The segments, nearest first.
    static let choices: [Self] = [.onTrail, .nearby, .around]

    var id: Self { self }

    var meters: Double {
        switch self {
        case .onTrail: TrailPlaceAnchor.touchedOffRouteMeters
        case .nearby: 500
        case .around: 1000
        }
    }

    /// The segment's words: *On Trail*, then a distance in the hiker's units.
    var label: String {
        switch self {
        case .onTrail:
            String(localized: "On Trail")
        case .nearby, .around:
            Measurement(value: meters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
    }
}

/// One row of the list: a place, and whether the hike already has it.
struct TrailPlaceAroundEntry: Identifiable, Equatable {
    let row: TrailPlaceRow
    let isAdded: Bool

    var id: UUID { row.id }
}

/// The two sections of the list — what the line passes and what is near it —
/// each in walking order.
struct TrailPlaceAroundListing: Equatable {
    var onTrail: [TrailPlaceAroundEntry] = []
    var nearby: [TrailPlaceAroundEntry] = []

    var isEmpty: Bool { onTrail.isEmpty && nearby.isEmpty }

    /// The hike's own places and the found ones not on it, merged.
    ///
    /// In the order they are met walking the line: a place too far off to be
    /// described by a distance along it sorts after every one that can be,
    /// nearest the line first. Two places at the same point keep the order
    /// they came in, the hike's own first, because `sorted(by:)` is stable.
    init(held: [TrailPlaceRow], candidates: [TrailPlaceRow]) {
        let entries = held.map { TrailPlaceAroundEntry(row: $0, isAdded: true) }
            + candidates.map { TrailPlaceAroundEntry(row: $0, isAdded: false) }
        // `partitioned(by:)` answers (does not satisfy, satisfies), and each
        // half keeps the walking order.
        (nearby, onTrail) = entries.sorted { Self.key($0.row) < Self.key($1.row) }.partitioned(by: \.row.isOnTheLine)
    }

    init() { /* empty */ }

    private static func key(_ row: TrailPlaceRow) -> (along: Double, off: Double) {
        (row.anchor?.distanceAlongRouteMeters ?? .infinity, row.offRouteMeters ?? .infinity)
    }
}

@MainActor
@Observable
final class HikePlacesAroundSearch {
    enum Phase: Equatable {
        case searching
        case found
        /// Refused with nothing found, here or on this device.
        case failed(CuratedTrailOutage)
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "Places")

    private(set) var phase = Phase.searching
    /// The last refusal, when something was found anyway.
    private(set) var outage: CuratedTrailOutage?
    /// Everything found, with where each sits against the line. Not filtered
    /// by reach, kind or what the hike holds — see ``candidates(showing:held:)``.
    private(set) var found: [TrailPlaceRow] = []
    /// The places *Search This Area* found, shown whatever the reach.
    private(set) var askedAbout: Set<UUID> = []
    /// How far off the line the list reaches.
    var reach = TrailPlaceReach.around
    /// The place whose card is open. The screen in the new host presents the
    /// card again from it after a turn.
    var selection: UUID?

    /// Where each row of ``found`` sits, by id and by element; told about
    /// every row appended to it.
    @ObservationIgnored private var foundIndex = TrailPlaceFoundIndex()
    @ObservationIgnored private var searchedReach: Double?
    @ObservationIgnored private var searchedSymbols: Set<TrailPlaceSymbol> = []
    /// How far out and for which kinds the request that is out asks, while
    /// one is — see ``needsSearch(showing:)``.
    @ObservationIgnored private var asking: (reach: Double, symbols: Set<TrailPlaceSymbol>)?
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated deinit { /* intentionally empty */ }

    /// Whether the line has to be asked about again to show what is chosen: a
    /// wider reach than was asked for, or a kind the last request left out.
    ///
    /// A request still out counts as asked, so it is waited for rather than
    /// asked again. A turn of the phone builds the screen again while one can
    /// be out, and the new screen asks this as it comes up. The rule also
    /// holds for a reach narrowed, or a kind switched off, while one is out.
    func needsSearch(showing symbols: Set<TrailPlaceSymbol>) -> Bool {
        if let asking, reach.meters <= asking.reach, symbols.isSubset(of: asking.symbols) { return false }
        guard let searchedReach else { return true }
        return reach.meters > searchedReach || !symbols.isSubset(of: searchedSymbols)
    }

    /// Asks about `route`, as far out as ``reach``. Answers the search, which
    /// a test awaits rather than yielding until the phase moves.
    ///
    /// Nothing the hike holds is left out of the request: what it holds is
    /// left out of the list instead, so a place removed while the screen is
    /// up is offered again without asking again.
    @discardableResult func search(
        along route: [RouteCoordinate],
        from source: any TrailPointSourcing,
        showing symbols: Set<TrailPlaceSymbol>
    ) -> Task<Void, Never> {
        task?.cancel()
        phase = .searching
        let asked = max(reach.meters, searchedReach ?? 0)
        asking = (asked, symbols)
        let search = Task { [weak self] in
            let outcome: TrailPlaceCorridorSearch.Outcome
            do {
                outcome = try await TrailPlaceCorridorSearch.search(
                    along: route,
                    excluding: [],
                    from: source,
                    showing: symbols,
                    reaching: asked
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            receive(outcome, reach: asked, symbols: symbols)
        }
        task = search
        return search
    }

    func receive(_ outcome: TrailPlaceCorridorSearch.Outcome, reach: Double, symbols: Set<TrailPlaceSymbol>) {
        asking = nil
        merge(outcome.rows)
        outage = outcome.outage
        if let refusal = outcome.outage, found.isEmpty {
            Self.logger.info("A search around a trail was refused: \(String(describing: refusal), privacy: .public)")
            phase = .failed(refusal)
            return
        }
        // Only an answer that was not refused says the line has been asked
        // about: a refused one is tried again the next time anything changes.
        if outcome.outage == nil {
            searchedReach = reach
            searchedSymbols = symbols
        }
        phase = .found
    }

    /// Takes what *Search This Area* found, measured against `route` off the
    /// main actor. Answers the work, which a test awaits.
    @discardableResult func receiveArea(_ places: [TrailPlace], along route: [RouteCoordinate]) -> Task<Void, Never> {
        Task { [weak self] in
            let rows = await Self.ordered(places, along: route)
            guard let self else { return }
            let ids = merge(rows)
            askedAbout.formUnion(ids)
            if phase != .found, !found.isEmpty { phase = .found }
        }
    }

    /// The found places the list and the map offer: of a kind switched on,
    /// within reach or asked about, and not already on the hike.
    func candidates(showing symbols: Set<TrailPlaceSymbol>, held: [TrailPlace]) -> [TrailPlaceRow] {
        let within = found.filter { row in
            let kind = row.place.symbol.map(symbols.contains) ?? true
            let near = row.offRouteMeters.map { $0 <= reach.meters } ?? false
            return kind && (near || askedAbout.contains(row.id))
        }
        let unheld = Set(TrailPlaceHolding.unheld(within.map(\.place), by: held).map(\.id))
        return within.filter { unheld.contains($0.id) }
    }

    /// The found place `id`, if it was found.
    func row(_ id: UUID) -> TrailPlaceRow? {
        foundIndex.position(of: id).map { found[$0] }
    }

    /// Puts one found place on `hike` and saves it. Answers whether it went
    /// in; a refused save throws with the hike as it was — see
    /// ``HikePlaceChange/add(_:to:in:save:)``. A card open on it stays open,
    /// and becomes the card of a place the hike has.
    @discardableResult func add(
        _ id: UUID,
        to hike: Hike,
        in context: ModelContext,
        save: HikePlaceChange.Save = { try $0.save() }
    ) throws(HikePlaceRefusal) -> Bool {
        guard let place = row(id)?.place else { return false }
        return try HikePlaceChange.add(place, to: hike, in: context, save: save)
    }

    func cancel() {
        task?.cancel()
        task = nil
        asking = nil
    }

    /// Adds the rows not already found — one of each OpenStreetMap element,
    /// since an area search and the line both answer for the hut between them
    /// — and answers the ids that now stand for every row given. One pass over
    /// `rows`, whatever has been found — see ``TrailPlaceFoundIndex``.
    @discardableResult private func merge(_ rows: [TrailPlaceRow]) -> Set<UUID> {
        let merge = foundIndex.merge(rows)
        if !merge.added.isEmpty { found += merge.added }
        return merge.ids
    }

    @concurrent
    nonisolated private static func ordered(
        _ places: [TrailPlace],
        along route: [RouteCoordinate]
    ) async -> [TrailPlaceRow] {
        TrailPlaceOrder.ordered(places, along: route)
    }
}
