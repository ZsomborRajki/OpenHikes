//
//  HikePlacesSession.swift
//  OpenHikes
//
//  What either place-search screen holds until its route is popped. The
//  portrait sheet and the landscape panel replace one another, but neither
//  owns the search, its open card, or Nearby's original frame. Keeping those
//  here makes a turn a change of host rather than another Overpass request.
//
//  A host's disappearance and the route ending are different events. During
//  a turn the map claim, including an in-flight area search, stays until the
//  replacement claims it. A covered screen releases the map as before; only
//  leaving the route cancels the corridor search. Revoking the old card host
//  before the layout changes also prevents its dismissal from closing the
//  new host's card.
//

import CoreLocation
import Foundation
import MapKit
import Observation
import OpenHikesData
import SwiftUI

@Observable
final class HikePlacesSession {
    let search = HikePlacesAroundSearch()
    /// Nearby's distances stay measured from where the screen first opened.
    private(set) var origin: CLLocationCoordinate2D?
    /// The area and kinds Nearby last asked, including an interrupted request.
    @ObservationIgnored private(set) var asked = PlacesNearbySearch()

    @ObservationIgnored private var activeHost: UUID?
    @ObservationIgnored private weak var around: TrailPlacesAround?
    @ObservationIgnored private var mapToken: Int?
    @ObservationIgnored private var hasEnded = false

    nonisolated deinit { /* intentionally empty */ }

    func attach(host: UUID, to around: TrailPlacesAround, handlers: TrailPlacesAround.Handlers) -> Int? {
        guard !hasEnded else { return nil }
        activeHost = host
        self.around = around
        let token = around.attach(handlers)
        mapToken = token
        return token
    }

    func detach(host: UUID, token: Int) {
        // A replaced host no longer owns either the card or the map. Keep
        // the old claim across a rotation gap, even if it disappears first.
        guard activeHost == host else { return }
        activeHost = nil
        around?.detach(token: token)
        if mapToken == token { mapToken = nil }
    }

    /// Called synchronously before SwiftUI tears down the outgoing host.
    func willReplaceHost() {
        activeHost = nil
    }

    func cardBinding(for host: UUID) -> Binding<Bool> {
        Binding(
            get: { self.search.selection != nil },
            set: { presented in
                guard !presented, !self.hasEnded, self.activeHost == host else { return }
                self.search.selection = nil
            }
        )
    }

    /// A pop retires this session even if its disappearing view still holds it.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        activeHost = nil
        search.cancel()
        search.selection = nil
        if let mapToken { around?.detach(token: mapToken) }
        mapToken = nil
        around = nil
    }

    @discardableResult func searchAlongIfNeeded(
        _ route: [RouteCoordinate],
        from source: (any TrailPointSourcing)?,
        showing symbols: Set<TrailPlaceSymbol>
    ) -> Task<Void, Never>? {
        guard search.needsSearch(showing: symbols) else { return nil }
        return searchAlong(route, from: source, showing: symbols)
    }

    @discardableResult func searchAlong(
        _ route: [RouteCoordinate],
        from source: (any TrailPointSourcing)?,
        showing symbols: Set<TrailPlaceSymbol>
    ) -> Task<Void, Never>? {
        guard !hasEnded, let source, !symbols.isEmpty else { return nil }
        return search.search(along: route, from: source, showing: symbols)
    }

    // MARK: - Nearby's first frame and later requests

    /// The line and fix are read once, and only an unanswered request is retried.
    func askNearbyFirst(
        using finder: TrailPointFinder,
        avoiding held: [TrailPlace],
        line: () -> [CLLocationCoordinate2D],
        position: () -> CLLocationCoordinate2D?,
        show: (MKCoordinateRegion) -> Void
    ) {
        guard !hasEnded else { return }
        if asked.hasAsked {
            if let area = asked.interrupted { askNearby(area, using: finder, avoiding: held) }
            return
        }
        let here = position()
        guard let region = PlacesNearbyFrame.region(line: line(), position: here) else { return }
        origin = here ?? region.center
        show(region)
        askNearby(PlacesNearbyFrame.area(of: region), using: finder, avoiding: held)
    }

    func askNearby(_ area: CommunitySearchArea, using finder: TrailPointFinder, avoiding held: [TrailPlace]) {
        guard !hasEnded else { return }
        if origin == nil { origin = area.coordinate }
        let symbols = finder.filter.shown
        let taken = finder.search(in: area, along: [], avoiding: held)
        asked.ask(area, for: symbols, isTaken: taken)
    }

    @discardableResult func receiveNearby(
        _ places: [TrailPlace],
        using finder: TrailPointFinder,
        avoiding held: [TrailPlace]
    ) -> Task<Void, Never>? {
        guard !hasEnded else { return nil }
        // No line to measure along: Nearby orders by distance from the origin.
        let receiving = search.receiveArea(places, along: [])
        asked.answer(keeping: finder.filter.shown)
        askNearbyAgainIfWider(using: finder, avoiding: held)
        return receiving
    }

    func retryNearby(using finder: TrailPointFinder, avoiding held: [TrailPlace]) {
        if let area = asked.area { askNearby(area, using: finder, avoiding: held) }
    }

    func askNearbyAgainIfWider(using finder: TrailPointFinder, avoiding held: [TrailPlace]) {
        if let area = asked.widened(showing: finder.filter.shown) {
            askNearby(area, using: finder, avoiding: held)
        }
    }
}
