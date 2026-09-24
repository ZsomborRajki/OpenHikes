//
//  HikePlaceView.swift
//  OpenHikes
//
//  One of a saved hike's places, on its own screen.
//
//  The maker's place card, for a trail that is finished: the same header, the
//  same OpenStreetMap facts and the same location rows — see
//  `TrailPlaceCardParts.swift` — with the photographs of the place where the
//  maker has *Add Stop*. Pushed rather than raised as a sheet, because it is a
//  screen of the hike's in the way the photo viewer and a walk's summary are:
//  back goes to the trail, and the map behind it keeps drawing the trail.
//
//  ## What the hiker can change, and why it is so little
//
//  **Photographs, on every place.** A place from OpenStreetMap is otherwise
//  read-only — its name and kind are the map's to state, and its card links to
//  where they are corrected. A place the hiker made (added while recording, or
//  read out of a `.gpx`) can also be renamed, re-kinded and annotated. Both
//  kinds can be removed, which returns their photographs to the hike's gallery
//  rather than deleting them. See ``TrailPlace/isHikersOwn``.
//
//  ## Photographs go through the camera pill's own path
//
//  The screen claims the map's camera pill with its place — see
//  ``PhotoCaptureController/Subject/placeID`` — so a picture taken from the
//  pill, or from the two buttons here that ask the pill's own questions, is
//  filed under the place by the one path every photograph already takes.
//  There is no second importer to drift from the first.
//

import SwiftData
import SwiftUI

struct HikePlaceView: View {
    let hike: Hike
    let placeID: UUID
    let mapController: MapController
    var photoCapture: PhotoCaptureController?
    var photoPins: PhotoMapPinController?
    var placePins: TrailPlacePinController?
    var store: HikePhotoStore = .shared
    /// Collapses the sheet so the place is in view when the map frames it.
    var onShowOnMap: () -> Void = { /* no-op default */ }
    var onOpenPhoto: (HikePhoto) -> Void = { _ in /* no-op default */ }
    /// Opens another of the hike's places, from its pin.
    var onOpenPlace: (UUID) -> Void = { _ in /* no-op default */ }

    @Environment(\.modelContext)
    private var modelContext
    @Environment(\.dismiss)
    private var dismiss
    @State private var isEditing = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        Group {
            if let card = HikePlaceCard(hike: hike, placeID: placeID) {
                content(card)
            } else {
                // Removed — here, or on another device while this was open.
                Color.clear.onAppear { dismiss() }
            }
        }
        .navigationTitle(Text("Place"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Every place of the trail stays on the map while one of them is
        // open, so the hiker can see where this one sits and tap the next.
        .trailPlacePins(placePins, rows: hike.orderedPlaces, onOpen: onOpenPlace)
    }

    private func content(_ card: HikePlaceCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                header(card)
                actions(card)
                if !card.note.isEmpty {
                    Text(card.note)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("hike-place-note")
                }
                HikePlacePhotoStrip(
                    photos: hike.photos(ofPlace: placeID),
                    store: store,
                    onOpen: onOpenPhoto
                )
                TrailPlaceFactsAndLocation(
                    facts: card.facts,
                    coordinate: card.coordinate,
                    openStreetMapURL: card.openStreetMapURL
                )
                removeButton
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .toolbar {
            if card.isEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { isEditing = true }
                        .accessibilityIdentifier("hike-place-edit")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            HikePlaceEditor(place: card.place) { name, symbol, note in
                hike.editPlace(id: placeID, name: name, symbol: symbol, note: note)
                try? modelContext.save()
            }
        }
        .confirmationDialog(
            "Remove \(card.title)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Place", role: .destructive) { remove() }
                .accessibilityIdentifier("hike-place-remove-confirm")
        } message: {
            Text("Its photos stay in this hike's gallery.")
        }
        // A photograph taken now is of this place, pinned where it stands.
        .photoCaptureSubject(photoCapture, for: hike, place: placeID) { card.coordinate }
        .photoMapPins(photoPins, photos: hike.photos(ofPlace: placeID)) { photoID in
            guard let photo = hike.photos.first(where: { $0.id == photoID }) else { return }
            onOpenPhoto(photo)
        }
        .accessibilityIdentifier("hike-place-screen")
    }

    private func header(_ card: HikePlaceCard) -> some View {
        PlaceCardHeader {
            TrailPlaceBadge(systemImage: card.systemImage, tint: card.tint)
        } title: {
            Text(card.title)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("hike-place-title")
        } subtitle: {
            Text([card.subtitle, card.provenance].compactMap(\.self).joined(separator: " · "))
        }
    }

    private func actions(_ card: HikePlaceCard) -> some View {
        HStack(spacing: 8) {
            Button {
                photoCapture?.requestCamera()
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("hike-place-camera")
            Button {
                photoCapture?.requestLibrary()
            } label: {
                Label("Add Photos", systemImage: "photo.on.rectangle")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("hike-place-library")
            Button {
                onShowOnMap()
                mapController.showPhotoSpot(card.coordinate)
            } label: {
                Label("Show on Map", systemImage: "map")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("hike-place-show-on-map")
            ShareLink(
                item: TrailPlaceCoordinates.mapsURL(card.coordinate, named: card.title),
                subject: Text(card.title),
                message: Text([card.title, TrailPlaceCoordinates.text(card.coordinate)].joined(separator: "\n"))
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("hike-place-share")
        }
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        // One height for the row, whichever button's word needs the most room
        // at the hiker's type size.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var removeButton: some View {
        Button("Remove Place", systemImage: "trash", role: .destructive) {
            isConfirmingRemoval = true
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityIdentifier("hike-place-remove")
    }

    /// Takes the place off the hike. The screen closes itself once the card
    /// has nothing to show — see `body` — rather than here as well, which
    /// would pop the screen underneath it too.
    private func remove() {
        hike.removePlace(id: placeID, in: modelContext)
        try? modelContext.save()
    }
}

/// The photographs filed under one place, and what to do when there are none.
///
/// Its own view so the strip's `LazyHStack` and the thumbnails' decodes belong
/// to it rather than to the whole screen — the shape ``HikePhotoSection``
/// takes, and for its reasons.
private struct HikePlacePhotoStrip: View {
    let photos: [HikePhoto]
    let store: HikePhotoStore
    let onOpen: (HikePhoto) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photos")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if photos.isEmpty {
                Text("No photos of this place yet. Take one here, or add some from your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: PhotoTileMetrics.spacing) {
                        ForEach(photos.enumerated(), id: \.element.id) { index, photo in
                            Button { onOpen(photo) } label: {
                                HikePhotoThumbnail(
                                    photo: photo,
                                    store: store,
                                    size: PhotoTileMetrics.stripTileSize,
                                    cornerRadius: PhotoTileMetrics.cornerRadius,
                                    label: String(localized: "Photo \(index + 1) of \(photos.count)")
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("hike-place-photos")
            }
        }
    }
}
