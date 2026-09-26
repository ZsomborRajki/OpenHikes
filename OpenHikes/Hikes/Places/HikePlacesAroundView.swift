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
//  it. A tap on a pale pin or a row opens the place's card; ⊕ adds it straight
//  away. The hike's own rows open their own screen, as they do everywhere.
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
    /// Opens one of the hike's places.
    var onOpenPlace: (UUID) -> Void = { _ in /* no-op default */ }
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
        // tap on one opens it — the claim the hike's screen held, taken over
        // while this one is on top.
        .background(HikePlacePinClaim(hike: hike, controller: placePins, onOpen: onOpenPlace))
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
        .onChange(of: candidates, initial: true) { _, rows in
            if let token { around.show(rows, token: token) }
        }
        .onChange(of: search.reach) { searchIfNeeded() }
        .onChange(of: filter.hidden) { searchIfNeeded() }
        .sheet(isPresented: isShowingCard) {
            HikePlaceAroundCard(search: search, hike: hike, onAdd: add, onAddPhoto: addAndOpen)
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
        if entry.isAdded {
            onOpenPlace(entry.id)
        } else {
            // The card is about a spot on the map, so the map comes into
            // view with it rather than staying under a full-height list.
            search.selection = entry.id
            onShowMap()
            mapController.showPhotoSpot(entry.row.place.clCoordinate)
        }
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

    /// Adds the place and opens it, where its photographs are taken.
    private func addAndOpen(_ id: UUID) {
        do throws(HikePlaceRefusal) {
            try search.add(id, to: hike, in: modelContext)
            search.selection = nil
            onOpenPlace(id)
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
            .accessibilityHint(entry.isAdded ? Text("Opens the place") : Text("Shows the place's card"))
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

/// Apple Maps' place card, for a place found around the trail and not on it
/// yet: what it is, how far off the trail, and *Add*.
///
/// Presented from inside the screen, like the maker's card — see
/// ``TrailPlaceSheet`` — with the map left live behind its smaller detents, so
/// tapping the next pale pin moves the card to it.
private struct HikePlaceAroundCard: View {
    let search: HikePlacesAroundSearch
    let hike: Hike
    let onAdd: (UUID) -> Void
    let onAddPhoto: (UUID) -> Void

    @State private var detent: PresentationDetent = .medium

    var body: some View {
        Group {
            if let id = search.selection, let row = search.row(id) {
                card(row)
            } else {
                Color.clear.onAppear { search.selection = nil }
            }
        }
        .presentationDetents([SheetPresentation.compactDetent, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationCompactAdaptation(.none)
    }

    private func card(_ row: TrailPlaceRow) -> some View {
        let card = HikePlaceCard(row: row)
        return VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            PlaceCardHeader {
                TrailPlaceBadge(systemImage: card.systemImage, tint: card.tint)
            } title: {
                Text(card.title)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("places-around-card-title")
            } subtitle: {
                Text([card.subtitle, TrailPlaceRowView.offTrail(row)].compactMap(\.self).joined(separator: " · "))
            } trailing: {
                Button("Close", systemImage: "xmark") { search.selection = nil }
                    .glassButtonStyle()
                    .placeCardControl()
                    .accessibilityIdentifier("places-around-card-close")
            }
            actions(row, title: card.title)
            TrailPlaceFactsAndLocation(
                facts: card.facts,
                coordinate: card.coordinate,
                openStreetMapURL: card.openStreetMapURL
            )
        }
        .padding(.horizontal)
        .padding(.top, 20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("places-around-card")
    }

    private func actions(_ row: TrailPlaceRow, title: String) -> some View {
        HStack(spacing: 8) {
            Button { onAdd(row.id) } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("places-around-card-add")
            Button { onAddPhoto(row.id) } label: {
                Label("Add Photo", systemImage: "camera")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityHint(Text("Adds the place, then opens it to take or add photos"))
            .accessibilityIdentifier("places-around-card-photo")
            ShareLink(
                item: TrailPlaceCoordinates.mapsURL(row.place.clCoordinate, named: title),
                subject: Text(title),
                message: Text([title, TrailPlaceCoordinates.text(row.place.clCoordinate)].joined(separator: "\n"))
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("places-around-card-share")
        }
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        .fixedSize(horizontal: false, vertical: true)
    }
}
