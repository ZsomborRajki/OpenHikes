//
//  HikePlaceAdder.swift
//  OpenHikes
//
//  *Add Place*, from the map's pill: a place of the hiker's own, put onto a
//  saved hike at the spot the pill resolved, with its photographs.
//
//  Offered only where the pill is and only for a hike's own screen — see
//  ``PhotoCaptureController/Subject/placeAnchor`` — and pushed at the spot
//  the pill read at the tap, the photograph's rule: the live match while
//  auto-follow has one, otherwise wherever the elevation graph's tracker is.
//  A pin stands there while the form is up, in the chosen kind's glyph and
//  colour, and the map is moved onto it before the screen arrives.
//
//  ## The place screen's questions, and none of its other buttons
//
//  Name, kind and note are what ``HikePlaceEditor`` asks of a place the
//  hiker made, and *Take Photo* and *Add Photos* are ``HikePlaceView``'s.
//  There is no *Show on Map* — the map is already on the pin — and no
//  *Share* or *Remove*, because there is nothing on the hike yet to share or
//  remove. It starts as a viewpoint called "Viewpoint" with no note.
//
//  ## Photographs wait for *Add*
//
//  Nothing reaches the hike until the hiker says *Add*: a camera frame or a
//  picked picture is held here, shown in the strip, and can be taken back
//  out. That is why this screen presents its own camera and picker rather
//  than asking the pill's — the pill files straight into the hike, and a
//  cancelled form must leave no photograph behind. *Add* then files each one
//  through the same ``HikePhotoImport`` path, under the new place, and opens
//  the place's screen.
//

import OpenHikesData
import PhotosUI
import SwiftData
import SwiftUI

struct HikePlaceAdder: View {
    let hike: Hike
    let spot: HikePlaceSpot
    var placePins: TrailPlacePinController?
    /// Called with the new place's id once it and its photographs are on the
    /// hike.
    let onAdded: (UUID) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext)
    private var modelContext
    @AppStorage(SettingsKey.savePhotosToLibrary)
    private var savePhotosToLibrary = SettingsDefault.savePhotosToLibrary
    @State private var draft = HikePlaceDraft()
    @State private var photos: [HikePlaceStagedPhoto] = []
    @State private var capture = PhotoCaptureState()
    @State private var isAdding = false
    /// Photographs taken or picked that are still being read into the strip.
    /// *Add* waits for them: it files what the strip holds, and a frame
    /// straight off the camera that arrived a moment after it would be lost.
    @State private var stagingCount = 0
    /// The place, once it is on the hike, while an alert about a photograph
    /// that did not make it is still up. The place's screen opens when the
    /// alert goes.
    @State private var addedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                header
                actions
                fields
                HikePlaceStagedPhotoStrip(photos: photos) { removed in
                    photos.removeAll { $0.id == removed }
                }
                TrailPlaceFactsAndLocation(facts: [], coordinate: spot.coordinate)
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .disabled(isAdding)
        .navigationTitle(Text("New Place"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // A form, not a page: it is left by Cancel or by Add, and a back
        // swipe that threw away a typed name and three photographs would be
        // the easiest gesture on the screen.
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isAdding)
                    .accessibilityIdentifier("hike-place-adder-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                if isAdding || stagingCount > 0 {
                    ProgressView()
                } else {
                    Button("Add", action: add)
                        .accessibilityIdentifier("hike-place-adder-add")
                }
            }
        }
        .background {
            HikePlacePinClaim(hike: hike, controller: placePins, placeholder: draft.placeholder(at: spot))
        }
        .photoCapturePickers($capture, onCaptured: stage, onPicked: stage)
        .photoCaptureAlerts($capture)
        .onChange(of: capture.failure) { _, failure in
            guard failure == nil, let addedID else { return }
            onAdded(addedID)
        }
        .accessibilityIdentifier("hike-place-adder")
    }

    private var header: some View {
        let shown = draft.placeholder(at: spot).place
        return PlaceCardHeader {
            TrailPlaceBadge(systemImage: shown.systemImageName, tint: shown.tint)
        } title: {
            Text(draft.displayName)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("hike-place-adder-title")
        } subtitle: {
            Text("Added by you")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await openCamera() }
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("hike-place-adder-camera")
            Button {
                capture.pickedPhotos = []
                capture.showLibraryPicker = true
            } label: {
                Label("Add Photos", systemImage: "photo.on.rectangle")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("hike-place-adder-library")
        }
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fields: some View {
        StatList(title: String(localized: "Details")) {
            TextField("Name", text: $draft.name, prompt: Text(TrailPlace.unnamedName(for: draft.symbol)))
                .trailPlaceRow()
                .accessibilityIdentifier("hike-place-adder-name")
            LabeledContent("Kind") {
                TrailPlaceKindPicker(selection: Binding(get: { draft.symbol }, set: { draft.setKind($0) }))
                    .labelsHidden()
            }
            .trailPlaceRow()
            TextField("Note", text: $draft.note, axis: .vertical)
                .lineLimit(1...6)
                .trailPlaceRow()
                .accessibilityIdentifier("hike-place-adder-note")
        }
    }

    /// Opens this screen's own camera — see the header for why not the pill's.
    /// The unavailable case is silent for the reason
    /// ``OpenHikesView/presentCamera()`` gives: it is a simulator.
    private func openCamera() async {
        switch await CameraAccess.request() {
        case .granted: capture.showCamera = true
        case .denied: capture.cameraAccessDenied = true
        case .unavailable: break
        }
    }

    private func stage(_ frame: CapturedFrame) {
        stagingCount += 1
        Task {
            defer { stagingCount -= 1 }
            let thumbnail = await HikePlaceStagedPhoto.thumbnail(of: frame.image)
            photos.append(HikePlaceStagedPhoto(source: .captured(frame), thumbnail: thumbnail))
        }
    }

    /// Loads what was picked now rather than at *Add*, so the strip can show
    /// it and a picture that cannot be read is reported while the hiker is
    /// still choosing.
    private func stage(_ items: [PhotosPickerItem]) {
        stagingCount += 1
        Task {
            defer { stagingCount -= 1 }
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    capture.failure = .importFailed
                    continue
                }
                let thumbnail = await HikePlaceStagedPhoto.thumbnail(of: data)
                photos.append(HikePlaceStagedPhoto(
                    source: .picked(data, assetLocalIdentifier: item.itemIdentifier),
                    thumbnail: thumbnail
                ))
            }
        }
    }

    /// Puts the place on the hike, files every held photograph under it, and
    /// opens it — after the alert, if a photograph did not make it.
    private func add() {
        guard !isAdding, stagingCount == 0 else { return }
        let place = draft.place(at: spot)
        guard hike.isAttached, hike.addPlace(place, in: modelContext) else { return }
        try? modelContext.save()
        isAdding = true
        let staged = photos
        let savesCaptures = savePhotosToLibrary
        Task {
            var failure: PhotoCaptureState.Failure?
            for photo in staged {
                guard hike.isAttached else { return }
                if let lost = await photo.file(
                    under: place,
                    of: hike,
                    savesCapturesToPhotoLibrary: savesCaptures
                ) {
                    // A lost capture outranks a failed import: the one is
                    // gone, the other is still in the library.
                    if failure != .captureNotStored { failure = lost }
                }
            }
            isAdding = false
            guard let failure else {
                onAdded(place.id)
                return
            }
            addedID = place.id
            capture.failure = failure
        }
    }
}

/// The photographs *Add Place* is holding, each with a way to take it back.
///
/// Its own view so the strip belongs to it rather than to the form, whose
/// every keystroke would otherwise rebuild it — ``HikePlaceView``'s strip is
/// split out for the same reason.
private struct HikePlaceStagedPhotoStrip: View {
    /// The remove button's scrim, dark enough for its white cross to read
    /// over a bright sky.
    private static let scrimOpacity = 0.6
    private static let removeInset: CGFloat = 4
    /// What a tile shows for a photograph no thumbnail could be made of.
    private static let pendingOpacity = 0.2

    let photos: [HikePlaceStagedPhoto]
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photos")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if photos.isEmpty {
                Text("No photos yet. Take one here, or add some from your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: PhotoTileMetrics.spacing) {
                        ForEach(photos.enumerated(), id: \.element.id) { index, photo in
                            tile(photo, label: String(localized: "Photo \(index + 1) of \(photos.count)"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("hike-place-adder-photos")
            }
        }
    }

    private func tile(_ photo: HikePlaceStagedPhoto, label: String) -> some View {
        thumbnail(photo)
            .frame(width: PhotoTileMetrics.stripTileSize, height: PhotoTileMetrics.stripTileSize)
            .clipShape(.rect(cornerRadius: PhotoTileMetrics.cornerRadius))
            .overlay(alignment: .topTrailing) {
                Button("Remove Photo", systemImage: "xmark.circle.fill") { onRemove(photo.id) }
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(Self.scrimOpacity))
                    .font(.title3)
                    .padding(Self.removeInset)
                    .accessibilityLabel(Text("Remove \(label)"))
                    .accessibilityIdentifier("hike-place-adder-remove-photo")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func thumbnail(_ photo: HikePlaceStagedPhoto) -> some View {
        #if canImport(UIKit)
        if let image = photo.thumbnail {
            // Named by the tile it sits in.
            Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
        } else {
            Color.secondary.opacity(Self.pendingOpacity)
        }
        #else
        Color.secondary.opacity(Self.pendingOpacity)
        #endif
    }
}
