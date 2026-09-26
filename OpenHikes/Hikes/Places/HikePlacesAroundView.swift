//
//  HikePlacesAroundView.swift
//  OpenHikes
//
//  *Places Around Trail*: what OpenStreetMap has mapped on and around a saved
//  hike, on the map and in a list, to add to it one at a time.
//
//  Apple Maps' search results, for a trail. The map behind the sheet carries
//  every place found — the hike's own at full strength, the rest pale — and the
//  sheet carries the kind chips, how far off the line to look, and the same
//  places as a list in two sections: what the line passes, and what is near
//  it. ⊕ adds a place straight away, and a tap on any pin or row opens its
//  card over the sheet — see ``HikePlaceAroundCard`` — whether or not the hike
//  has it yet, so the map stays in view and nothing is pushed over this
//  screen but *Add Place*.
//
//  A place that is not on the trail is still worth having on it: the hut up
//  the side path the hiker walked to for lunch, the summit they took a
//  photograph of from the ridge. And where OpenStreetMap has mapped nothing, a
//  press and hold on the map adds a place of the hiker's own right there,
//  through the same form as *Add Place* from the camera pill.
//
//  Pushed rather than raised as a sheet, because the map is the point of it: a
//  sheet over the sheet would cover the places it is about.
//

import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI

struct HikePlacesAroundView: View {
    let hike: Hike
    let around: TrailPlacesAround
    let mapController: MapController
    var placePins: TrailPlacePinController?
    /// Brings the sheet down to its middle, so the map is in view.
    var onShowMap: () -> Void = { /* no-op default */ }
    /// Opens one of the hike's photographs, from a place's card.
    var onOpenPhoto: (HikePhoto) -> Void = { _ in /* no-op default */ }
    /// Opens *Add Place* at a spot the hiker pressed on the map.
    var onAddPlace: (HikePlaceSpot) -> Void = { _ in /* no-op default */ }

    @Environment(\.modelContext)
    private var modelContext
    @State private var search = HikePlacesAroundSearch()
    @State private var token: Int?
    /// Set when an add was refused. The screen stays as it was under it, so
    /// tapping ⊕ again is the retry.
    @State private var refusal: HikePlaceRefusal?

    private var filter: TrailPlaceFilter { around.finder.filter }

    var body: some View {
        let candidates = search.candidates(showing: filter.shown, held: hike.places)
        let listing = TrailPlaceAroundListing(held: hike.orderedPlaces, candidates: candidates)
        ScrollView {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 12) {
                    TrailPlaceKindChips(filter: filter)
                    reachPicker
                }
                status(listing)
                section("On This Trail", entries: listing.onTrail, identifier: "places-around-on-trail")
                section("Nearby", entries: listing.nearby, identifier: "places-around-nearby")
                footer
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .navigationTitle(Text("Places Around Trail"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The hike's own places stay on the map beside the pale ones, and a
        // tap on one opens its card — the claim the hike's screen held, taken
        // over while this one is on top.
        .background(HikePlacePinClaim(hike: hike, controller: placePins, onOpen: select))
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
        .onChange(of: candidates, initial: true) { _, rows in
            if let token { around.show(rows, token: token) }
        }
        .onChange(of: search.reach) { searchIfNeeded() }
        .onChange(of: filter.hidden) { searchIfNeeded() }
        .sheet(isPresented: isShowingCard) {
            HikePlaceAroundCard(search: search, hike: hike, onAdd: add) { photo in
                // The card goes first: a push under a presented sheet lands
                // behind it.
                search.selection = nil
                onOpenPhoto(photo)
            }
        }
        .hikePlaceRefusalAlert($refusal)
        .accessibilityIdentifier("places-around-screen")
    }

    private var reachPicker: some View {
        Picker("Within", selection: $search.reach) {
            ForEach(TrailPlaceReach.choices) { reach in
                Text(reach.label).tag(reach)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("places-around-reach")
    }

    @ViewBuilder
    private func status(_ listing: TrailPlaceAroundListing) -> some View {
        switch search.phase {
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking around the trail…")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("places-around-searching")
        case .failed(let outage):
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(TrailPointNotice.outage(outage).caption.text)
            } actions: {
                // The community page's retry, and for the reason it has one: a
                // bare text button here is a 64 × 18 pt target (#662).
                Button("Try Again") { searchNow() }
                    .glassButtonStyle()
            }
        case .found:
            if let outage = search.outage {
                Label(TrailPointNotice.outage(outage).caption.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if listing.isEmpty {
                ContentUnavailableView(
                    "Nothing Mapped",
                    systemImage: "mappin.slash",
                    description: Text("OpenStreetMap has nothing of these kinds this close to the trail.")
                )
            }
        }
    }

    @ViewBuilder
    private func section(
        _ title: LocalizedStringKey,
        entries: [TrailPlaceAroundEntry],
        identifier: String
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        TrailPlaceAroundRow(
                            entry: entry,
                            onOpen: { open(entry) },
                            onAdd: { add(entry.id) }
                        )
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                .placeCardGroup()
                .accessibilityIdentifier(identifier)
            }
        }
    }

    private var footer: some View {
        Text(
            """
            Places from OpenStreetMap. Press and hold the map to add a place \
            of your own anywhere, on the trail or off it.
            """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var isShowingCard: Binding<Bool> {
        Binding(get: { search.selection != nil }, set: { if !$0 { search.selection = nil } })
    }

    // MARK: - What the screen does

    private func attach() {
        token = around.attach(TrailPlacesAround.Handlers(
            select: { id in
                search.selection = id
            },
            searchArea: {
                around.finder.search(along: hike.route, avoiding: hike.places)
            },
            dropPin: { coordinate in
                onAddPlace(HikePlaceSpot(coordinate))
            }
        ))
        around.finder.onFound { [search, hike] places in
            guard hike.isAttached else { return }
            search.receiveArea(places, along: hike.route)
        }
        if let token {
            around.show(search.candidates(showing: filter.shown, held: hike.places), token: token)
        }
        onShowMap()
        mapController.fitToRoute()
        searchIfNeeded()
    }

    private func detach() {
        search.cancel()
        guard let token else { return }
        around.detach(token: token)
        self.token = nil
    }

    private func searchIfNeeded() {
        guard search.needsSearch(showing: filter.shown) else { return }
        searchNow()
    }

    private func searchNow() {
        guard let source = around.finder.source, hike.isAttached, !filter.shown.isEmpty else { return }
        search.search(along: hike.route, from: source, showing: filter.shown)
    }

    private func open(_ entry: TrailPlaceAroundEntry) {
        select(entry.id)
        mapController.showPhotoSpot(entry.row.place.clCoordinate)
    }

    /// Opens a place's card. The card is about a spot on the map, so the map
    /// comes into view with it rather than staying under a full-height list.
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

/// One place in the list: the row every place list draws, and ⊕ to add it or
/// a tick for one the hike already has.
private struct TrailPlaceAroundRow: View {
    let entry: TrailPlaceAroundEntry
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                TrailPlaceRowView(row: entry.row)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows the place's card"))
            if entry.isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(Text("On this hike"))
                    .accessibilityIdentifier("places-around-added")
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(Text("Add \(entry.row.place.displayName)"))
                .accessibilityIdentifier("places-around-add")
            }
        }
    }
}
