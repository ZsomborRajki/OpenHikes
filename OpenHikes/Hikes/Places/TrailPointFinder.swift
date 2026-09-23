//
//  TrailPointFinder.swift
//  OpenHikes
//
//  What OpenStreetMap has to say about the ground near the trail being drawn,
//  and the one tap that asks.
//
//  The map can **tell a hiker** what is there — the waterfall a hundred
//  metres off the line, the spring on the climb, the hut at the saddle. It is
//  the difference between a drawing tool and a planning one.
//
//  A stable `@Observable` reference type for the reason ``TrailDraft`` is one:
//  the pill is a UIKit control on the map and the controller that acts on the
//  answer is not, and both read this.
//
//  ## What is found goes on the trail
//
//  A search's answer is handed to the controller, which adds it to the draft
//  as its places — pins on the map, and a place sheet on each where a hiker
//  reads what OpenStreetMap says about it and removes what they do not want. There is no provisional tier: an offer
//  the hiker had to tap to accept was a second kind of pin meaning *not yet*,
//  and the place sheet already has *Remove*.
//
//  ## Except when Overpass refuses, and this device already knows something
//
//  Then the places come off the disk instead — see ``TrailPointStore``, which
//  is what a successful search writes — and the caption under the pill still
//  says the search was refused. It is the same bargain the curated list makes
//  one feature over: three of five first attempts came back `504` the day this
//  was measured, and the twenty places a valley answered with an hour ago beat
//  nothing.
//
//  ## One tap, one request, and never a pan
//
//  Behind a button for the reason *Search this area* is: Overpass allows a
//  handful of slots per address, this app is one of thousands asking, and the
//  editor already spends one request per leg. A search that followed the map
//  would spend one per pan on top of that. So the pill is the whole of what
//  asks, a second tap while one is out is refused, and **nothing here may ever
//  block drawing**.
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

    /// Whether a search is out. Draws the pill's spinner.
    private(set) var isSearching = false

    /// What the last search has to say for itself, or `nil`.
    private(set) var notice: TrailPointNotice?

    /// The circle the map is showing, when it is small enough to ask about —
    /// see ``regionDidSettle(_:)``.
    private(set) var searchableArea: CommunitySearchArea?

    /// Whether this launch can ask at all. False under tests, which reach no
    /// network.
    var isAvailable: Bool { source != nil }

    /// Whether the pill can be tapped. False with every switch off as well as
    /// while the map is too wide or a search is out: there is nothing left to
    /// ask for.
    var canSearch: Bool { searchableArea != nil && !isSearching && !filter.shown.isEmpty }

    /// Which kinds of place a search asks for — the maker's switches.
    let filter: TrailPlaceFilter

    @ObservationIgnored private let source: (any TrailPointSourcing)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deliver: (([TrailPlace]) -> Void)?

    init(source: (any TrailPointSourcing)? = nil, filter: TrailPlaceFilter = TrailPlaceFilter(defaults: nil)) {
        self.source = source
        self.filter = filter
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Where an answer goes. Set once, by the controller.
    func onFound(_ deliver: @escaping ([TrailPlace]) -> Void) {
        self.deliver = deliver
    }

    /// Takes the map's settled region, and offers a search only while the
    /// visible circle is within ``TrailPointQuery/maximumRadiusMeters``.
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

    /// Asks what is in the visible area, ranked against `route` and leaving out
    /// anything already `placed`.
    func search(along route: [RouteCoordinate], avoiding placed: [TrailPlace]) {
        guard let source, let area = searchableArea, canSearch else { return }
        let symbols = filter.shown
        isSearching = true
        task?.cancel()
        task = Task { [weak self] in
            let outcome = await Self.answer(
                from: source,
                near: area,
                showing: symbols,
                along: route,
                avoiding: placed
            )
            guard let self, !Task.isCancelled else { return }
            receive(outcome)
        }
    }

    func dismissNotice() {
        guard notice != nil else { return }
        notice = nil
    }

    /// Drops a search in flight and the caption — what the maker closing does.
    func clear() {
        task?.cancel()
        task = nil
        if isSearching { isSearching = false }
        if notice != nil { notice = nil }
    }

    private enum Outcome {
        case found([TrailPlace])
        case refused(CuratedTrailOutage, standingIn: [TrailPlace])
        case cancelled
    }

    private static func answer(
        from source: any TrailPointSourcing,
        near area: CommunitySearchArea,
        showing symbols: Set<TrailPlaceSymbol>,
        along route: [RouteCoordinate],
        avoiding placed: [TrailPlace]
    ) async -> Outcome {
        // Filtered here as well as in the request, before the ranking spends
        // any of its forty on a kind that is switched off: the store answers
        // with whatever it kept, under the symbol it was drawn as when it was
        // kept, and a source is only asked to leave the others out.
        let wanted = { (place: TrailPlace) in place.symbol.map(symbols.contains) ?? true }
        do {
            let found = try await source.places(near: area, showing: symbols).filter(wanted)
            return .found(
                await TrailPointRanking.offered(from: found, along: route, in: area, excluding: placed)
            )
        } catch {
            guard let outage = CuratedTrailOutage(error) else { return .cancelled }
            let stored = await source.cachedPlaces(near: area, limit: TrailPointQuery.maximumStoredResults)
                .filter(wanted)
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

    /// Hands over what landed, less any kind switched off while it was out —
    /// a switch turned off takes its pins off the map, and a search that
    /// landed a moment later must not put them back.
    private func receive(_ outcome: Outcome) {
        isSearching = false
        switch outcome {
        case .cancelled:
            return
        case .found(let found):
            let places = found.filter(filter.admits)
            notice = places.isEmpty ? .nothingHere : nil
            deliver?(places)
        case let .refused(outage, standingIn):
            Self.logger.info(
                """
                A place search was refused: \
                \(String(describing: outage), privacy: .public); \
                adding \(standingIn.count, privacy: .public) places already on this device.
                """
            )
            notice = .outage(outage)
            deliver?(standingIn.filter(filter.admits))
        }
    }
}
