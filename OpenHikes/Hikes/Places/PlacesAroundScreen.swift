//
//  PlacesAroundScreen.swift
//  OpenHikes
//
//  What *Places Around Trail* and *Places Nearby* are both: a list over the
//  map of what OpenStreetMap has around a hike, with the hike's own places
//  beside the pale ones, a card over the sheet for any of them, and a press on
//  the map for a place of the hiker's own.
//
//  Written twice until now, down to the doc comments, which had started to
//  say different things about the same lines. What the two screens differ in
//  stays theirs — ``HikePlacesAroundView`` asks along a line, as far off it as
//  its *Within* segment says; ``HikePlacesNearbyView`` asks about a frame
//  around the hiker — and is handed in as the list, what the screen asks as it
//  comes up, *Search This Area*, and what it does with an answer.
//

import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI

struct PlacesAroundScreen<Content: View>: View {
    let hike: Hike
    let around: TrailPlacesAround
    let mapController: MapController
    let placePins: TrailPlacePinController?
    let search: HikePlacesAroundSearch
    /// The found places not on the hike, drawn on the map as pale pins.
    let candidates: [TrailPlaceRow]
    /// Brings the sheet down to its middle, so the map is in view.
    let onShowMap: () -> Void
    /// Opens one of the hike's photographs, from a place's card.
    let onOpenPhoto: (HikePhoto) -> Void
    /// Opens *Add Place* at a spot the hiker pressed on the map.
    let onAddPlace: (HikePlaceSpot) -> Void
    /// What the screen asks as it comes up, once it holds the map.
    let onAttach: () -> Void
    /// *Search This Area*, from the pill on the map.
    let onSearchArea: () -> Void
    /// What to do with an answer from the finder, while the hike is still in
    /// the store: *Search This Area*'s on both screens, and on *Places
    /// Nearby* — which asks nothing any other way — its first question's and
    /// *Try Again*'s too.
    let onFound: ([TrailPlace]) -> Void
    /// The screen's chips, status and list, given the rows' actions.
    @ViewBuilder let content: (PlacesAroundRows) -> Content

    @Environment(\.modelContext) private var modelContext
    @State private var token: Int?
    /// Set when an add was refused. The screen stays as it was under it, so
    /// tapping ⊕ again is the retry.
    @State private var refusal: HikePlaceRefusal?

    var body: some View {
        @Bindable var search = search
        ScrollView {
            content(PlacesAroundRows(open: open, add: add))
                .padding()
        }
        .softScrollEdgeEffect(for: .top)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The hike's own places stay on the map beside the pale ones, and a
        // tap on one opens its card — the claim the screen under this one
        // held, taken over while this one is on top.
        .background(HikePlacePinClaim(hike: hike, controller: placePins, onOpen: select))
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
        .onChange(of: candidates, initial: true) { _, rows in
            if let token { around.show(rows, token: token) }
        }
        .sheet(isPresented: $search.selection.isPresent()) {
            HikePlaceAroundCard(search: search, hike: hike, placeRows: placePins?.placeRows, onAdd: add) { photo in
                // The card goes first: a push under a presented sheet lands
                // behind it.
                search.selection = nil
                onOpenPhoto(photo)
            }
        }
        .hikePlaceRefusalAlert($refusal)
    }

    private func attach() {
        token = around.attach(TrailPlacesAround.Handlers(
            select: select,
            searchArea: onSearchArea,
            dropPin: { coordinate in
                onAddPlace(HikePlaceSpot(coordinate))
            }
        ))
        around.finder.onFound { [hike, onFound] places in
            guard hike.isAttached else { return }
            onFound(places)
        }
        if let token { around.show(candidates, token: token) }
        onShowMap()
        onAttach()
    }

    private func detach() {
        search.cancel()
        guard let token else { return }
        around.detach(token: token)
        self.token = nil
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

/// The rows of either list, each opening its place's card and adding it —
/// what ``PlacesAroundScreen`` hands the list it draws.
struct PlacesAroundRows {
    let open: (TrailPlaceAroundEntry) -> Void
    let add: (UUID) -> Void

    /// The row for `entry`, with how far away it is where the screen has no
    /// line to say so along — see ``TrailPlaceAroundRow/distance``.
    func row(_ entry: TrailPlaceAroundEntry, distance: String? = nil) -> TrailPlaceAroundRow {
        TrailPlaceAroundRow(
            entry: entry,
            distance: distance,
            onOpen: { open(entry) },
            onAdd: { add(entry.id) }
        )
    }
}
