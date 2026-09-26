//
//  HikePlaceAroundCard.swift
//  OpenHikes
//
//  Apple Maps' place card, over *Places Around Trail*, for any place on its
//  map — one found around the trail, or one the hike already has.
//
//  One card for both, the way the maker's ``TrailPlaceSheet`` is one card for
//  whatever a tap lands on, because to the hiker it is one question: *what is
//  this, and what do I do with it?* A found place offers **Add**; once it is
//  on the hike the same card, still open, offers **Take Photo** and **Add
//  Photos** instead, with the place's photographs underneath. So adding a
//  place and photographing it is two taps on one card, with the map in view
//  the whole time.
//
//  ## Photographs through its own camera and picker
//
//  The map's camera pill presents its pickers from the sheet's root, and the
//  sheet is already presenting this card, so a picker asked for from here
//  would never appear. The card presents its own, the way ``HikePlaceAdder``
//  does, and files each picture the moment it arrives through
//  ``HikePlaceStagedPhoto`` — the one path every photograph of a place takes.
//
//  ## A sheet over the sheet
//
//  Presented from inside ``HikePlacesAroundView``, like the maker's card, with
//  the map left live behind its smaller detents: tapping the next pin moves the
//  card to it. A saved hike's own *Places* section still pushes the place's
//  full screen — see ``HikePlaceView`` — where it is edited and removed.
//

import OpenHikesData
import PhotosUI
import SwiftUI

struct HikePlaceAroundCard: View {
    let search: HikePlacesAroundSearch
    let hike: Hike
    /// Adds a found place to the hike.
    let onAdd: (UUID) -> Void
    /// Opens one of the place's photographs in the gallery.
    let onOpenPhoto: (HikePhoto) -> Void

    @State private var detent: PresentationDetent = .medium

    var body: some View {
        Group {
            if let id = search.selection, let content = Content(id: id, hike: hike, search: search) {
                HikePlaceAroundCardContent(
                    content: content,
                    hike: hike,
                    onAdd: onAdd,
                    onOpenPhoto: onOpenPhoto,
                    onClose: { search.selection = nil }
                )
            } else {
                // What the card was about has gone — removed on another
                // device while it was open.
                Color.clear.onAppear { search.selection = nil }
            }
        }
        .presentationDetents([SheetPresentation.compactDetent, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // A sheet stays a sheet in landscape, for the reason the maker's card
        // gives: a card over the whole map is a card about a spot nobody can
        // see.
        .presentationCompactAdaptation(.none)
    }

    /// What the card is about: a place the hike has, or one found around it.
    /// The hike is asked first, so a place that was just added is shown as
    /// the hike's.
    struct Content {
        let row: TrailPlaceRow
        let isOnHike: Bool

        @MainActor
        init?(id: UUID, hike: Hike, search: HikePlacesAroundSearch) {
            if let held = hike.placeRow(id: id) {
                row = held
                isOnHike = true
            } else if let found = search.row(id) {
                row = found
                isOnHike = false
            } else {
                return nil
            }
        }
    }
}

private struct HikePlaceAroundCardContent: View {
    let content: HikePlaceAroundCard.Content
    let hike: Hike
    let onAdd: (UUID) -> Void
    let onOpenPhoto: (HikePhoto) -> Void
    let onClose: () -> Void

    @AppStorage(SettingsKey.savePhotosToLibrary)
    private var savePhotosToLibrary = SettingsDefault.savePhotosToLibrary
    @State private var capture = PhotoCaptureState()
    /// How many photographs are being filed, so the strip can say so.
    @State private var filing = 0

    /// Room between the grabber and the title, as the maker's card leaves.
    private static let topPadding: CGFloat = 20

    private var place: TrailPlace { content.row.place }

    var body: some View {
        let card = HikePlaceCard(row: content.row)
        VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            header(card)
            actions(title: card.title)
            if content.isOnHike {
                if !card.note.isEmpty {
                    Text(card.note)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HikePlacePhotoStrip(photos: hike.photos(ofPlace: place.id), store: .shared, onOpen: onOpenPhoto)
                if filing > 0 {
                    ProgressView()
                        .accessibilityLabel(Text("Adding photos"))
                }
            }
            TrailPlaceFactsAndLocation(
                facts: card.facts,
                coordinate: card.coordinate,
                openStreetMapURL: card.openStreetMapURL
            )
        }
        .padding(.horizontal)
        .padding(.top, Self.topPadding)
        // Hung from the top of whatever the detent offers, for the reason the
        // maker's card gives: without the `minHeight` a card taller than the
        // smallest detent was centred, its title above the top edge.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .photoCapturePickers($capture, onCaptured: file, onPicked: file)
        .photoCaptureAlerts($capture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("places-around-card")
    }

    private func header(_ card: HikePlaceCard) -> some View {
        PlaceCardHeader {
            TrailPlaceBadge(systemImage: card.systemImage, tint: card.tint)
        } title: {
            Text(card.title)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("places-around-card-title")
        } subtitle: {
            let parts = [
                card.subtitle,
                TrailPlaceRowView.offTrail(content.row),
                content.isOnHike ? String(localized: "On this hike") : nil,
            ]
            Text(parts.compactMap(\.self).joined(separator: " · "))
        } trailing: {
            Button("Close", systemImage: "xmark", action: onClose)
                .glassButtonStyle()
                .placeCardControl()
                .accessibilityIdentifier("places-around-card-close")
        }
    }

    private func actions(title: String) -> some View {
        HStack(spacing: 8) {
            if content.isOnHike {
                Button {
                    Task { await openCamera() }
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .labelStyle(TrailPlaceActionLabelStyle())
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("places-around-card-camera")
                Button {
                    capture.pickedPhotos = []
                    capture.showLibraryPicker = true
                } label: {
                    Label("Add Photos", systemImage: "photo.on.rectangle")
                        .labelStyle(TrailPlaceActionLabelStyle())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("places-around-card-library")
            } else {
                Button { onAdd(place.id) } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(TrailPlaceActionLabelStyle())
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("places-around-card-add")
            }
            ShareLink(
                item: TrailPlaceCoordinates.mapsURL(place.clCoordinate, named: title),
                subject: Text(title),
                message: Text([title, TrailPlaceCoordinates.text(place.clCoordinate)].joined(separator: "\n"))
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

    /// Opens the card's own camera — see the header for why not the pill's.
    /// The unavailable case is silent: it is a simulator.
    private func openCamera() async {
        switch await CameraAccess.request() {
        case .granted: capture.showCamera = true
        case .denied: capture.cameraAccessDenied = true
        case .unavailable: break
        }
    }

    /// Files a photograph the moment it is taken.
    private func file(_ frame: CapturedFrame) {
        file(HikePlaceStagedPhoto(source: .captured(frame), thumbnail: nil))
    }

    /// Files what was picked, one picture at a time.
    private func file(_ items: [PhotosPickerItem]) {
        filing += 1
        Task {
            defer { filing -= 1 }
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    capture.failure = .importFailed
                    continue
                }
                let source = HikePlaceStagedPhoto.Source.picked(data, assetLocalIdentifier: item.itemIdentifier)
                file(HikePlaceStagedPhoto(source: source, thumbnail: nil))
            }
        }
    }

    private func file(_ photo: HikePlaceStagedPhoto) {
        filing += 1
        let target = place
        let savesCaptures = savePhotosToLibrary
        Task {
            defer { filing -= 1 }
            guard hike.isAttached else { return }
            if let failure = await photo.file(under: target, of: hike, savesCapturesToPhotoLibrary: savesCaptures) {
                capture.failure = failure
            }
        }
    }
}
