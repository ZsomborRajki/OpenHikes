//
//  TrailPointFinder.swift
//  OpenHikes
//
//  What OpenStreetMap has to say about the ground near the trail being drawn,
//  and the one tap that asks.
//
//  Phase 4 let a hiker mark a place and say what it is. This is the phase
//  where the map can **tell them** what is there — the waterfall a hundred
//  metres off the line, the spring on the climb, the hut at the saddle. It is
//  the difference between a drawing tool and a planning one.
//
//  A stable `@Observable` reference type for the reason ``TrailDraft`` is one,
//  and it is the same three-cornered geometry: the pill is a UIKit control on
//  the map, the pins are MapKit annotations, the list of what came back is a
//  section of a screen two pushes down inside the sheet, and none of the three
//  can see the others. They all read this.
//
//  ## Candidates are not places
//
//  Nothing here is in the draft, on the disk or in the saved hike. A candidate
//  is drawn in its own provisional style, is replaced wholesale by the next
//  search, and goes when the maker closes — see ``clear()``. The hiker taking
//  one is the only thing that puts anything anywhere, and what that writes is
//  an ordinary ``TrailPlace`` through the controller, exactly as *Mark a
//  Place* does.
//
//  ## Except when Overpass refuses, and this device already knows something
//
//  Then the pins come off the disk instead — see ``TrailPointStore``, which is
//  what a successful search writes. They are still candidates, they are still
//  drawn as an offer, and the caption under the pill still says the search was
//  refused, because what is drawn is *what happens to be on this device near
//  here* rather than an answer. It is the same bargain the curated list makes
//  one feature over, for the same reason: three of five first attempts came
//  back `504` the day this was measured, and drawing the twenty places a
//  valley answered with an hour ago beats drawing nothing.
//
//  ## One tap, one request, and never a pan
//
//  Behind a button for the reason *Search this area* is: Overpass allows a
//  handful of slots per address, this app is one of thousands asking, and the
//  editor already spends one request per leg. A search that followed the map
//  would spend one per pan on top of that. So the pill is the whole of what
//  asks, a second tap while one is out is refused, and **nothing here may ever
//  block drawing** — the line, the legs, the list and Save do not know this
//  file exists.
//

import CoreLocation
import Foundation
import MapKit
import Observation
import os

/// The caption under the maker's *Search this area*: what the last search has
/// to say for itself.
///
/// Two kinds of sentence rather than one, for the reason
/// ``CuratedTrailNotice`` draws the same distinction one feature over: an
/// outage is a failure, wears the warning glyph and is answered by waiting; an
/// area with nothing mapped in it is not a failure at all and is answered by
/// looking somewhere else. Flattening them would put a warning triangle on a
/// perfectly good answer.
///
/// Its own type rather than ``CuratedTrailNotice`` because every sentence
/// differs: that one says *trails*, and this is about what is on the ground
/// beside one. What the two share is the shape they reach the pill in — see
/// ``MapCaptionNotice``.
nonisolated enum TrailPointNotice: Equatable, Sendable {
    /// OpenStreetMap answered, and there is nothing here worth offering.
    case nothingHere
    /// OpenStreetMap could not be reached, or asked us to wait.
    case outage(CuratedTrailOutage)

    /// The sentence, the glyph and whether it is a warning.
    var caption: MapCaptionNotice {
        switch self {
        case .nothingHere:
            MapCaptionNotice(
                text: String(localized: "Nothing mapped here — try another area"),
                symbolName: "mappin.slash",
                isWarning: false
            )
        case .outage(let outage):
            MapCaptionNotice(
                text: Self.text(of: outage),
                symbolName: "exclamationmark.triangle.fill",
                isWarning: true
            )
        }
    }

    /// One short line about a refusal.
    ///
    /// The *busy* sentence is word for word ``CuratedTrailOutage``'s, because
    /// it is the same sentence about the same server and two translations of
    /// it would be two ways of saying one thing. The other two are not: those
    /// name *trails*, which is the half of OpenStreetMap this pill is not
    /// asking about.
    private static func text(of outage: CuratedTrailOutage) -> String {
        switch outage {
        case .busy:
            return String(localized: "OpenStreetMap is busy · try again")
        case .rateLimited(let retryAfter):
            guard let wait = CuratedTrailOutage.wait(retryAfter) else {
                return String(localized: "OpenStreetMap rate-limited")
            }
            return String(localized: "OpenStreetMap rate-limited · \(wait)")
        case .unavailable:
            return String(localized: "OpenStreetMap unavailable")
        }
    }
}

/// The places near the drawing that nobody has taken yet.
@MainActor
@Observable
final class TrailPointFinder {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    /// What is on offer, in along-route order, each with how far along the
    /// line it sits. Observed by the map, which draws the pins, and by the
    /// maker's own list.
    private(set) var rows: [TrailPlaceRow] = []

    /// Whether a search is out, drawn as a spinner in the pill.
    private(set) var isSearching = false

    /// What the last search had to say, or `nil` when it had nothing to say —
    /// which is what places arriving looks like. They are on the map, which is
    /// where a hiker reads them, and a caption saying so would be a label on a
    /// working screen.
    private(set) var notice: TrailPointNotice?

    /// The area a tap would ask about, or `nil` when it would ask nothing.
    ///
    /// `nil` above ``TrailPointQuery/maximumRadiusMeters``, which is the one
    /// state the pill is *disabled* in rather than withdrawn — the same answer
    /// the community list's own ceiling gets, and for the same reason: a
    /// control that vanished at a zoom level would be reporting policy by
    /// absence.
    private(set) var searchableArea: CommunitySearchArea?

    /// Whether this launch can ask at all. False for a preview, and for a
    /// suite or UI run with no source — the pill is then not offered, rather
    /// than offered and dead.
    var isAvailable: Bool { source != nil }

    /// Whether a tap would ask anything right now.
    var canSearch: Bool { searchableArea != nil && !isSearching }

    /// Whether anything is on offer at all.
    ///
    /// Read by ``TrailDraftController`` before it flattens the drawn line to
    /// hand here, which is the point of it: the line is thousands of
    /// coordinates once the legs have snapped, and building that array on
    /// every tap to hand it to a re-rank that has nothing to re-rank is a cost
    /// the commonest case — a hiker who has never tapped the pill — would pay
    /// for the whole of a drawing. Untracked, because it is read in an action
    /// rather than in a body.
    @ObservationIgnored var isOffering: Bool { !chosen.isEmpty }

    @ObservationIgnored private let source: (any TrailPointSourcing)?
    /// The places this search chose, unranked. Kept beside ``rows`` so the
    /// drawing changing re-places them without re-choosing them — see
    /// ``TrailPointRanking``.
    @ObservationIgnored private var chosen: [TrailPlace] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(source: (any TrailPointSourcing)? = nil) {
        self.source = source
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Told where the map came to rest.
    ///
    /// Handed over rather than observed, in this direction only, exactly as
    /// ``CommunityBrowser/regionDidSettle(_:)`` and
    /// ``SearchCompleter/regionDidSettle(_:)`` are: a settle is a stored
    /// property write and a comparison, and this one asks nothing of the
    /// network — a search is only ever a tap.
    ///
    /// The radius is the zoom, read the same way the community list reads it
    /// so that one map cannot be two sizes; what differs is the ceiling it is
    /// tested against, which is this feature's own.
    func regionDidSettle(_ region: MKCoordinateRegion) {
        let radius = CommunityQueryPolicy.visibleRadiusMeters(for: region)
        guard radius > 0, radius <= TrailPointQuery.maximumRadiusMeters else {
            guard searchableArea != nil else { return }
            searchableArea = nil
            return
        }
        let area = CommunitySearchArea(coordinate: region.center, radiusMeters: radius)
        guard searchableArea != area else { return }
        searchableArea = area
    }

    /// Asks about the area the map is showing: what the pill runs.
    ///
    /// Refused while a search is out, which is what the spinner says on
    /// screen. A second question buys nothing — the first is already the
    /// answer — and costs a slot against a server that hands out a handful per
    /// address.
    ///
    /// - Parameters:
    ///   - route: The line as it stands, which is what the answers are ranked
    ///     against.
    ///   - placed: The places the hiker has already marked, so a search does
    ///     not offer them the hut that is already on their trail.
    func search(along route: [RouteCoordinate], avoiding placed: [TrailPlace]) {
        guard let source, let area = searchableArea, !isSearching else { return }
        isSearching = true
        task?.cancel()
        // Read here rather than inside the task, because it decides whether
        // the disk is touched at all and it is a main-actor read: a refusal
        // never replaces candidates that are already on offer, so there is
        // nothing to read the store for when there are some.
        let mayDrawFromDisk = !isOffering
        task = Task { [weak self] in
            let outcome = await Self.answer(
                from: source,
                near: area,
                along: route,
                avoiding: placed,
                mayDrawFromDisk: mayDrawFromDisk
            )
            guard let self, !Task.isCancelled else { return }
            receive(outcome, along: route)
        }
    }

    /// Re-places what is on offer against a line that has changed.
    ///
    /// Called wherever the drawing is committed — see
    /// ``TrailDraftController``. Costs nothing at all while nothing is on
    /// offer, which is nearly always.
    func rerank(along route: [RouteCoordinate]) {
        guard !chosen.isEmpty else { return }
        publish(TrailPointRanking.rows(of: chosen, along: route))
    }

    /// Takes one candidate off the offer, because it has just become a place.
    ///
    /// By identity, which survives the list being re-ranked under it: a
    /// candidate adopted from its pin and the row describing it are the same
    /// value. Silent about an id that is not on offer — a second tap on a
    /// callout whose pin has already gone is a race, not an error.
    func take(_ id: UUID) {
        guard chosen.contains(where: { $0.id == id }) else { return }
        chosen.removeAll { $0.id == id }
        publish(rows.filter { $0.id != id })
    }

    /// Takes the caption off by hand: what the *x* on it does.
    ///
    /// A write here rather than a flag on the control, for the reason
    /// ``CommunityBrowser/dismissCuratedNotice()`` is one: the caption
    /// describes the last search, and there is always a next search to say its
    /// own piece.
    func dismissNotice() {
        guard notice != nil else { return }
        notice = nil
    }

    /// Forgets everything on offer, and what the last search said.
    ///
    /// What closing the maker does. Nothing here is the hiker's, so there is
    /// nothing to keep — and a candidate restored a launch later would be this
    /// app claiming an answer it no longer has any reason to believe.
    func clear() {
        task?.cancel()
        task = nil
        chosen = []
        if isSearching { isSearching = false }
        if notice != nil { notice = nil }
        publish([])
    }

    /// What one search came back with, already chosen and already paid for off
    /// the main actor.
    ///
    /// An enumeration rather than a `Result`, because a refusal is not only an
    /// error here: it may arrive carrying the places this device already had,
    /// and the third case is not a failure at all — a cancelled search is one
    /// nobody is waiting for.
    private enum Outcome {
        case offered([TrailPlace])
        case refused(CuratedTrailOutage, standingIn: [TrailPlace])
        case cancelled
    }

    /// The whole of a search, with every route-sized step behind an `await`.
    ///
    /// `static` and handed everything it needs, so nothing here touches the
    /// finder while the finder is not looking: what comes back is one value,
    /// applied in one turn of the main actor by ``receive(_:along:)``.
    private static func answer(
        from source: any TrailPointSourcing,
        near area: CommunitySearchArea,
        along route: [RouteCoordinate],
        avoiding placed: [TrailPlace],
        mayDrawFromDisk: Bool
    ) async -> Outcome {
        do {
            let found = try await source.places(near: area)
            return .offered(
                await TrailPointRanking.offered(
                    from: found,
                    along: route,
                    in: area,
                    excluding: placed
                )
            )
        } catch {
            // A cancelled search is not a refusal and must not be drawn as
            // one — the same carve-out ``CuratedTrailOutage/init(_:)`` makes,
            // and the same two spellings of it. There is nothing to report
            // because nobody is waiting: the hiker closed the maker.
            guard let outage = CuratedTrailOutage(error) else { return .cancelled }
            guard mayDrawFromDisk else { return .refused(outage, standingIn: []) }
            // Only now, on a path where a round trip has already failed, is
            // every file in the cache directory worth reading — see
            // ``TrailPointStore/places(near:limit:)``. More are asked for than
            // will be drawn, because the store can only sort by distance from
            // the middle of the map and the line decides the rest.
            let stored = await source.cachedPlaces(
                near: area,
                limit: TrailPointQuery.maximumStoredResults
            )
            return .refused(
                outage,
                standingIn: await TrailPointRanking.offered(
                    from: stored,
                    along: route,
                    in: area,
                    excluding: placed
                )
            )
        }
    }

    /// One answer, however long it took, applied in one turn.
    private func receive(_ outcome: Outcome, along route: [RouteCoordinate]) {
        isSearching = false
        switch outcome {
        case .cancelled:
            return
        case .offered(let places):
            chosen = places
            publish(TrailPointRanking.rows(of: places, along: route))
            notice = places.isEmpty ? .nothingHere : nil
        case let .refused(outage, standingIn):
            Self.logger.info(
                """
                A place search was refused: \
                \(String(describing: outage), privacy: .public); \
                drawing \(standingIn.count, privacy: .public) places already on this device.
                """
            )
            // The candidates that were already on offer stay. They are still
            // true — this refusal is about the request that was going to
            // replace them — and taking a map's worth of pins away to report
            // that a server is busy would be the failure doing more damage
            // than the thing that failed. `standingIn` is empty in exactly
            // that case; see ``search(along:avoiding:)``.
            if !standingIn.isEmpty, chosen.isEmpty {
                chosen = standingIn
                publish(TrailPointRanking.rows(of: standingIn, along: route))
            }
            // Whatever was drawn, the caption still says the search failed.
            // What came off the disk is not an answer and must never be
            // offered as one — see ``TrailPointStore``.
            notice = .outage(outage)
        }
    }

    /// Writes `updated` down, and only when it would draw differently.
    ///
    /// The map rebuilds its annotations from this and the list rebuilds its
    /// rows, so a same-value write is a pass through both for nothing.
    private func publish(_ updated: [TrailPlaceRow]) {
        guard rows != updated else { return }
        rows = updated
    }

}
