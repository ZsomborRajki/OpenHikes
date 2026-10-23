//
//  HikePlaceRows.swift
//  OpenHikes
//
//  A hike's places in the order they are met along its line, measured once
//  per line and kept.
//
//  ``Hike/orderedPlaces`` projects every place onto every segment of the
//  route before it sorts — a day's recording with forty places marked is
//  eight hundred thousand projections — and every screen about a hike's
//  places read it in its body: the detail screen's *Places* section, the pins
//  it claims, a place's own screen and its card, *Places Around Trail*. A
//  body re-runs for a photograph added, a place renamed, a sync that touched
//  nothing about the line, and each of those paid for the whole projection
//  again on the main thread.
//
//  ## What is kept, and what throws it away
//
//  Where a place sits depends on the line and on where the place stands, and
//  on nothing else. So the anchors are kept per hike against the route they
//  were measured along, and per place against its id and coordinate: a
//  rename, a note, a re-kind or a photograph reuses them, an edited or synced
//  route measures every place again, and a place added or moved measures that
//  place alone. The rows themselves are rebuilt on every read — sorting a few
//  dozen places is nothing — so what they say is always the hike as it is now.
//
//  Comparing the route is what makes this both cheap and right. SwiftData
//  hands back the same array storage while the column is unchanged, and
//  `Array`'s `==` answers on that identity before it reads a single element.
//  A route that really was rewritten — *Edit Route*, or a sync — is another
//  array and is compared element by element, once.
//
//  ## Off the main actor, past a budget
//
//  Measuring that fits ``synchronousBudget`` is done there and then, so a
//  short trail — or one place added to a long one — never draws without its
//  distances. Anything bigger is measured off the main actor, and the rows
//  read meanwhile carry what is already known: an unmeasured place sorts last
//  with no distance, as the maker's list does while its own ranking is out —
//  see ``TrailDraft/placeRows``. ``revision`` is the one observed property,
//  bumped when an answer lands, so a screen redraws once for that and never
//  for the bookkeeping a read does.
//

import Foundation
import Observation
import OpenHikesData

@Observable
final class HikePlaceRows {
    /// Where each of the places sits along the route — what this keeps.
    /// ``TrailPlaceOrder/anchors(of:along:)`` outside a test.
    typealias Measure = @Sendable ([TrailPlace], [RouteCoordinate]) -> [UUID: TrailPlaceAnchor]

    /// How many projections — segments times places — are measured inside
    /// the read that needs them: one place added to a ten-thousand-point
    /// line, which a Debug build on the simulator measured at about six
    /// milliseconds. Past it a read draws what it has and the rest arrives a
    /// moment later; forty places on a day's recording, which measured at
    /// over a hundred and fifty, always go off the main actor.
    static let synchronousBudget = 10_000

    /// How many hikes' anchors are kept. Each holds on to its route, which is
    /// the hike's own storage while the hike is unchanged and a copy once it
    /// is not, so this is bounded rather than one per hike ever opened.
    private static let keptHikes = 8

    /// Bumped when anchors measured off the main actor land. Read by every
    /// read, so the screens that drew without them draw again.
    private(set) var revision = 0

    @ObservationIgnored private var measured: [UUID: Measured] = [:]
    /// The owners in ``measured``, least recently read first.
    @ObservationIgnored private var recent: [UUID] = []
    /// What is being measured off the main actor, per owner, so a read while
    /// it is out does not ask again.
    @ObservationIgnored private var inFlight: [UUID: Request] = [:]
    @ObservationIgnored private let budget: Int
    @ObservationIgnored private let measure: Measure

    init(
        budget: Int = HikePlaceRows.synchronousBudget,
        measure: @escaping Measure = { places, route in TrailPlaceOrder.anchors(of: places, along: route) }
    ) {
        self.budget = budget
        self.measure = measure
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// `hike`'s places in the order they are met along its route — what
    /// ``Hike/orderedPlaces`` answers, without measuring again what nothing
    /// has moved.
    ///
    /// Empty for a hike that has been deleted or detached, before the route
    /// is read: it is external storage, and faulting it in off a deleted row
    /// traps. See ``Hike/orderedPlaces``.
    func rows(of hike: Hike) -> [TrailPlaceRow] {
        guard hike.isAttached else { return [] }
        return rows(of: hike.places, along: hike.route, for: hike.id)
    }

    /// One of `hike`'s places with where it sits — what
    /// ``Hike/placeRow(id:)`` answers — or `nil` for one that has gone.
    func row(_ id: UUID, of hike: Hike) -> TrailPlaceRow? {
        rows(of: hike).first { $0.id == id }
    }

    /// `places` in the order they are met along `route`, with the anchors
    /// kept for `owner` reused wherever the route and the place are where
    /// they were.
    func rows(of places: [TrailPlace], along route: [RouteCoordinate], for owner: UUID) -> [TrailPlaceRow] {
        // Read whatever else happens, so an answer landing later redraws
        // every screen that drew without it.
        _ = revision
        guard route.count > 1, !places.isEmpty else { return TrailPlaceOrder.ordered(places, anchors: [:]) }
        var entry = measured[owner].flatMap { $0.route == route ? $0 : nil } ?? Measured(route: route)
        // The storage just read, so the next comparison is answered by
        // identity even when this read had to compare element by element.
        entry.route = route
        let missing = places.filter { entry.anchors[Spot($0)] == nil }
        if !missing.isEmpty {
            if (route.count - 1) * missing.count <= budget {
                entry.record(measure(missing, route), of: missing)
            } else {
                request(missing, along: route, for: owner)
            }
        }
        // Only what the places are now, so a moved or removed place's old
        // anchor is not kept for a spot nothing stands on.
        let spots = Set(places.map(Spot.init))
        entry.anchors = entry.anchors.filter { spots.contains($0.key) }
        remember(entry, for: owner)
        let known = places.compactMap { place in entry.anchors[Spot(place)].map { (place.id, $0) } }
        // Two rows sharing an id, which nothing writes, keep the first's
        // anchor rather than trap.
        return TrailPlaceOrder.ordered(places, anchors: Dictionary(known, uniquingKeysWith: { first, _ in first }))
    }

    private func request(_ places: [TrailPlace], along route: [RouteCoordinate], for owner: UUID) {
        let wanted = Request(route: route, spots: Set(places.map(Spot.init)))
        if let flying = inFlight[owner], flying.route == route, wanted.spots.isSubset(of: flying.spots) { return }
        inFlight[owner] = wanted
        Task { [weak self, measure] in
            let anchors = await Self.measuring(places, along: route, with: measure)
            self?.land(anchors, of: places, along: route, for: owner, answering: wanted)
        }
    }

    @concurrent
    nonisolated private static func measuring(
        _ places: [TrailPlace],
        along route: [RouteCoordinate],
        with measure: Measure
    ) async -> [UUID: TrailPlaceAnchor] {
        measure(places, route)
    }

    private func land(
        _ anchors: [UUID: TrailPlaceAnchor],
        of places: [TrailPlace],
        along route: [RouteCoordinate],
        for owner: UUID,
        answering request: Request
    ) {
        if inFlight[owner] == request { inFlight[owner] = nil }
        // A line edited while this was out has been asked about since, and
        // an owner no longer kept will be asked about when it is read again:
        // this answer is about neither.
        guard var entry = measured[owner], entry.route == route else { return }
        entry.record(anchors, of: places)
        measured[owner] = entry
        revision += 1
    }

    private func remember(_ entry: Measured, for owner: UUID) {
        measured[owner] = entry
        guard recent.last != owner else { return }
        recent.removeAll { $0 == owner }
        recent.append(owner)
        while recent.count > Self.keptHikes {
            let evicted = recent.removeFirst()
            measured[evicted] = nil
            inFlight[evicted] = nil
        }
    }
}

/// A place as far as its anchor is concerned: which one, and where it stands.
/// Its name, kind and note are not here, so changing them keeps the anchor.
nonisolated private struct Spot: Hashable {
    let id: UUID
    let latitude: Double
    let longitude: Double

    init(_ place: TrailPlace) {
        id = place.id
        latitude = place.latitude
        longitude = place.longitude
    }
}

/// One owner's anchors and the route they were measured along.
private struct Measured {
    var route: [RouteCoordinate]
    var anchors: [Spot: TrailPlaceAnchor] = [:]

    mutating func record(_ measured: [UUID: TrailPlaceAnchor], of places: [TrailPlace]) {
        for place in places {
            if let anchor = measured[place.id] { anchors[Spot(place)] = anchor }
        }
    }
}

/// One measurement sent off the main actor.
private struct Request: Equatable {
    let route: [RouteCoordinate]
    let spots: Set<Spot>
}

extension Hike {
    /// ``orderedPlaces``, from `rows` where there is one — every screen with
    /// a map — and measured on the spot where there is not: a preview, and a
    /// test that hosts a section with no map.
    func orderedPlaces(preparedBy rows: HikePlaceRows?) -> [TrailPlaceRow] {
        rows?.rows(of: self) ?? orderedPlaces
    }

    /// ``placeRow(id:)``, from `rows` where there is one.
    func placeRow(id: UUID, preparedBy rows: HikePlaceRows?) -> TrailPlaceRow? {
        guard let rows else { return placeRow(id: id) }
        return rows.row(id, of: self)
    }
}
