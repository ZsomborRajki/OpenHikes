//
//  HikePlacesNearbyView.swift
//  OpenHikes
//
//  *Places Nearby*: what OpenStreetMap has mapped around a walk being
//  recorded, on the map and in a list, to add to it one at a time.
//
//  *Places Around Trail*'s screen for a line that does not exist yet. A saved
//  hike is asked about along its whole length, as far off it as the *Within*
//  segment says — see ``HikePlacesAroundView``. A recording has no line to ask
//  along until it stops, and the question a hiker has halfway round is *what
//  is around me*, so there is no segment: the screen frames the walk so far
//  and the hiker's position (``PlacesNearbyFrame``), asks about what that
//  frame shows, and after that *Search This Area* on the map asks about
//  wherever the hiker has moved it. Never a search per pan — see
//  ``TrailPointFinder`` on what Overpass allows.
//
//  Everything else is *Places Around Trail*'s: the kind chips, the pale pins
//  beside the walk's own, the card over the sheet that adds a place and then
//  photographs it, and a press on the map for a place of the hiker's own. A
//  place added here is on the recording at once, exactly as *Add Place* in the
//  recording screen's bar puts one there — through ``HikePlaceChange``.
//

import CoreLocation
import MapKit
import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI

struct HikePlacesNearbyView: View {
    let hike: Hike
    let around: TrailPlacesAround
    let mapController: MapController
    var placePins: TrailPlacePinController?
    /// The walk recorded so far, read once as the screen opens.
    var line: () -> [CLLocationCoordinate2D] = { [] }
    /// Where the hiker is, read once as the screen opens. What every row's
    /// distance is measured from.
    var position: () -> CLLocationCoordinate2D? = { nil }
    /// Brings the sheet down to its middle, so the map is in view.
    var onShowMap: () -> Void = { /* no-op default */ }
    /// Opens one of the walk's photographs, from a place's card.
    var onOpenPhoto: (HikePhoto) -> Void = { _ in /* no-op default */ }
    /// Opens *Add Place* at a spot the hiker pressed on the map.
    var onAddPlace: (HikePlaceSpot) -> Void = { _ in /* no-op default */ }

    @Environment(\.modelContext) private var modelContext
    @State private var search = HikePlacesAroundSearch()
    @State private var token: Int?
    /// Set when an add was refused. The screen stays as it was under it, so
    /// tapping ⊕ again is the retry.
    @State private var refusal: HikePlaceRefusal?
    /// What the rows are measured from: the hiker as the screen opened, or
    /// the middle of the first search where there was no fix to read.
    @State private var origin: CLLocationCoordinate2D?
    /// What has been asked, so switching a kind on asks that area again,
    /// *Try Again* has something to retry, and coming back to the screen asks
    /// nothing unless a search was cut off.
    @State private var asked = PlacesNearbySearch()

    private var filter: TrailPlaceFilter { around.finder.filter }

    var body: some View {
        let candidates = search.candidates(showing: filter.shown, held: hike.places)
        let entries = PlacesNearbyEntry.sorted(held: hike.orderedPlaces, candidates: candidates, from: origin)
        ScrollView {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                TrailPlaceKindChips(filter: filter)
                PlacesNearbyStatus(finder: around.finder, isEmpty: entries.isEmpty, onRetry: retry)
                list(entries)
                footer
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .navigationTitle(Text("Places Nearby"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The walk's own places stay on the map beside the pale ones, and a
        // tap on one opens its card — the recording screen's claim, taken over
        // while this one is on top.
        .background(HikePlacePinClaim(hike: hike, controller: placePins, onOpen: select))
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
        .onChange(of: candidates, initial: true) { _, rows in
            if let token { around.show(rows, token: token) }
        }
        .onChange(of: filter.hidden) { askAgainIfWider() }
        .sheet(isPresented: isShowingCard) {
            HikePlaceAroundCard(search: search, hike: hike, onAdd: add) { photo in
                // The card goes first: a push under a presented sheet lands
                // behind it.
                search.selection = nil
                onOpenPhoto(photo)
            }
        }
        .hikePlaceRefusalAlert($refusal)
        .accessibilityIdentifier("places-nearby-screen")
    }

    @ViewBuilder
    private func list(_ entries: [PlacesNearbyEntry]) -> some View {
        if !entries.isEmpty {
            VStack(spacing: 0) {
                ForEach(entries) { nearby in
                    TrailPlaceAroundRow(
                        entry: nearby.entry,
                        distance: nearby.meters.map(Self.length),
                        onOpen: { open(nearby.entry) },
                        onAdd: { add(nearby.id) }
                    )
                    if nearby.id != entries.last?.id { Divider() }
                }
            }
            .placeCardGroup()
            .accessibilityIdentifier("places-nearby-list")
        }
    }

    private var footer: some View {
        Text(
            """
            Places from OpenStreetMap, in the area the map shows. Move the map \
            and tap Search This Area to look somewhere else, or press and hold \
            it to add a place of your own.
            """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var isShowingCard: Binding<Bool> {
        Binding(get: { search.selection != nil }, set: { if !$0 { search.selection = nil } })
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    // MARK: - What the screen does

    private func attach() {
        token = around.attach(TrailPlacesAround.Handlers(
            select: select,
            searchArea: {
                if let area = around.finder.searchableArea { ask(area) }
            },
            dropPin: { coordinate in
                onAddPlace(HikePlaceSpot(coordinate))
            }
        ))
        around.finder.onFound { [search, hike] places in
            guard hike.isAttached else { return }
            // No line to measure along: the rows are ordered by distance from
            // the hiker instead — see ``PlacesNearbyEntry``.
            search.receiveArea(places, along: [])
            asked.answer(keeping: filter.shown)
            // A kind switched on while this was out was refused then.
            askAgainIfWider()
        }
        if let token {
            around.show(search.candidates(showing: filter.shown, held: hike.places), token: token)
        }
        onShowMap()
        // Back from a screen pushed over this one — *Add Place*, or a
        // photograph — which took the claim and with it cancelled anything
        // out. The map stays where the hiker left it, and only a search that
        // never answered is asked again.
        if asked.hasAsked {
            if let area = asked.interrupted { ask(area) }
            return
        }
        let here = position()
        guard let region = PlacesNearbyFrame.region(line: line(), position: here) else { return }
        origin = here ?? region.center
        mapController.show(region)
        ask(PlacesNearbyFrame.area(of: region))
    }

    private func detach() {
        search.cancel()
        guard let token else { return }
        around.detach(token: token)
        self.token = nil
    }

    private func ask(_ area: CommunitySearchArea) {
        if origin == nil { origin = area.coordinate }
        let symbols = filter.shown
        let isTaken = around.finder.search(in: area, along: [], avoiding: hike.places)
        asked.ask(area, for: symbols, isTaken: isTaken)
    }

    private func retry() {
        if let area = asked.area { ask(area) }
    }

    /// Asks the last area again when a kind it left out has been switched on.
    /// Switching one off only filters what was already found.
    private func askAgainIfWider() {
        if let area = asked.widened(showing: filter.shown) { ask(area) }
    }

    private func open(_ entry: TrailPlaceAroundEntry) {
        select(entry.id)
        mapController.showPhotoSpot(entry.row.place.clCoordinate)
    }

    /// Opens a place's card, with the map in view — the card is about a spot
    /// on it.
    private func select(_ id: UUID) {
        search.selection = id
        onShowMap()
    }

    private func add(_ id: UUID) {
        do throws(HikePlaceRefusal) {
            if try search.add(id, to: hike, in: modelContext) {
                HapticMoment.targetHit.play()
            }
        } catch {
            refusal = error
        }
    }
}

/// What *Places Nearby* has asked the finder, and whether it has answered.
///
/// The kinds are the ones of the last request the finder *took*, not the last
/// one tried: the first search goes out the moment the screen opens, and a
/// kind switched on while it is out is refused. Recording that refusal as
/// asked would never ask for the kind at all.
struct PlacesNearbySearch: Equatable {
    /// The area last asked about — the frame, the pill or *Try Again* —
    /// whether or not the finder took it.
    private(set) var area: CommunitySearchArea?
    /// The kinds of the last request the finder took. Empty until it takes
    /// one, so the first kind switched on asks.
    private(set) var symbols: Set<TrailPlaceSymbol> = []
    /// Whether that request has answered.
    private(set) var isAnswered = false

    /// Whether the screen has asked anything yet — framed the map and asked
    /// about it, which it does once.
    var hasAsked: Bool { area != nil }

    /// The area to ask again as the screen comes back, if the last request
    /// never answered: a screen pushed over this one takes the map's claim,
    /// and giving it up cancels the search that is out.
    var interrupted: CommunitySearchArea? { isAnswered ? nil : area }

    /// The area to ask again when `shown` holds a kind the last request the
    /// finder took left out.
    func widened(showing shown: Set<TrailPlaceSymbol>) -> CommunitySearchArea? {
        shown.isSubset(of: symbols) ? nil : area
    }

    /// Records asking about `area` for `symbols`. Only the area is kept when
    /// the finder refused — one already out, or every kind switched off.
    mutating func ask(_ area: CommunitySearchArea, for symbols: Set<TrailPlaceSymbol>, isTaken: Bool) {
        self.area = area
        guard isTaken else { return }
        self.symbols = symbols
        isAnswered = false
    }

    /// Records that the request out has answered, with the kinds `shown`
    /// as it landed. The finder drops a kind switched off while it was out —
    /// see ``TrailPointFinder`` — so switching it back on must ask again.
    mutating func answer(keeping shown: Set<TrailPlaceSymbol>) {
        isAnswered = true
        symbols.formIntersection(shown)
    }
}

/// One row of *Places Nearby*: a place, whether the walk has it, and how far
/// it is from the hiker.
struct PlacesNearbyEntry: Identifiable, Equatable {
    let entry: TrailPlaceAroundEntry
    /// `nil` only before anything has been asked, when there is no origin.
    let meters: Double?

    var id: UUID { entry.id }

    /// The walk's own places and the found ones not on it, nearest first.
    ///
    /// Nearest to the hiker rather than along a line, because there is no
    /// line yet — and the nearest is what a hiker looking around is asking
    /// about. Ties keep the order they came in.
    static func sorted(
        held: [TrailPlaceRow],
        candidates: [TrailPlaceRow],
        from origin: CLLocationCoordinate2D?
    ) -> [Self] {
        let entries = held.map { TrailPlaceAroundEntry(row: $0, isAdded: true) }
            + candidates.map { TrailPlaceAroundEntry(row: $0, isAdded: false) }
        let measured = entries.map { entry in
            Self(
                entry: entry,
                meters: origin.map { RouteGeometry.distanceMeters(from: $0, to: entry.row.place.clCoordinate) }
            )
        }
        return measured.enumerated()
            .sorted { left, right in
                let lhs = left.element.meters ?? .infinity
                let rhs = right.element.meters ?? .infinity
                return lhs != rhs ? lhs < rhs : left.offset < right.offset
            }
            .map(\.element)
    }
}

/// What the last search has to say, over the list.
///
/// Its own view because it reads the finder, whose area moves every time the
/// map settles: a pan should redraw this line and not the list under it.
private struct PlacesNearbyStatus: View {
    let finder: TrailPointFinder
    let isEmpty: Bool
    let onRetry: () -> Void

    var body: some View {
        if finder.isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking around here…")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("places-nearby-searching")
        } else if case .outage(let outage) = finder.notice {
            if isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Search", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(TrailPointNotice.outage(outage).caption.text)
                } actions: {
                    Button("Try Again", action: onRetry)
                        .glassButtonStyle()
                }
            } else {
                Label(TrailPointNotice.outage(outage).caption.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else if isEmpty, finder.notice == .nothingHere {
            ContentUnavailableView(
                "Nothing Mapped",
                systemImage: "mappin.slash",
                description: Text("OpenStreetMap has nothing of these kinds here. Move the map to look somewhere else.")
            )
        } else if isEmpty, finder.searchableArea == nil {
            ContentUnavailableView(
                "Zoom In to Search",
                systemImage: "plus.magnifyingglass",
                description: Text("The map shows too wide an area to search. Zoom in, then tap Search This Area.")
            )
        }
    }
}
