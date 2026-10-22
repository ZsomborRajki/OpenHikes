//
//  HikePlaceAdder.swift
//  OpenHikes
//
//  *Add Place*, from the map's pill: a place of the hiker's own, put onto a
//  saved hike at the spot the pill resolved, with its photographs.
//
//  Opened from the pill on a hike's own screen — see
//  ``PhotoCaptureController/Subject/placeAnchor`` — at the spot the pill read
//  at the tap, the photograph's rule: the live match while auto-follow has
//  one, otherwise wherever the elevation graph's tracker is. Also from a
//  press on the map on *Places Around Trail* and *Places Nearby*, and from a
//  recording's *Add Place*, at the hiker's last fix — see
//  ``RecordingPlaceSheet``.
//
//  ## The map places it
//
//  A pin stands in the middle of the map while the form is up, in the chosen
//  kind's glyph and colour, and the map is moved to put the spot under it.
//  The pin stays put and the map moves: wherever the hiker leaves the map is
//  where the place is added, which is how a viewpoint noticed fifty metres
//  after it was passed gets put back where it is. See
//  `MapPlacePlacement.swift`.
//
//  ## The place screen's questions, and none of its other buttons
//
//  Name, kind and note are what ``HikePlaceEditor`` asks of a place the
//  hiker made, and *Take Photo* and *Add Photos* are ``HikePlaceView``'s.
//  There is no *Show on Map* — the map is already on the pin — and no
//  *Share* or *Remove*, because there is nothing on the hike yet to share or
//  remove. It starts as a viewpoint called "Viewpoint" with no note.
//
//  The photographs it is holding are drawn right under *Take Photo* and *Add
//  Photos*, as ``HikePlaceView`` draws a place's own, and the questions under
//  them. Under the questions, the strip was past the foot of a landscape
//  panel and of the sheet at its middle detent — the height the form opens
//  at — so a picture that arrived there changed nothing the hiker could see.
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
//  ## Held by the sheet, not by this view
//
//  What the form has been told and handed — the name, kind and note, the
//  photographs it is holding, and the camera or picker it has open — is a
//  ``HikePlaceAdderSession`` the sheet keeps for as long as the form is on
//  its stack. A turn of the phone moves the form between the sheet and the
//  side panel, which replaces this view; see that type for what it cost while
//  all of it was this view's own state.
//

import OpenHikesData
import SwiftData
import SwiftUI

struct HikePlaceAdder: View {
    let hike: Hike
    let spot: HikePlaceSpot
    var placePins: TrailPlacePinController?
    /// Everything the form has been told and handed, kept by the sheet rather
    /// than here: a rotation replaces this view — see
    /// ``HikePlaceAdderSession``.
    @Bindable var session: HikePlaceAdderSession
    /// Called with the new place's id once it and its photographs are on the
    /// hike.
    let onAdded: (UUID) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKey.savePhotosToLibrary) private var savePhotosToLibrary = SettingsDefault.savePhotosToLibrary

    /// The strip's identity in the form's scroll view, which a photograph
    /// arriving scrolls to — see ``HikePlaceStagedPhotoArrival``.
    private static let stripID = "hike-place-adder-strip"

    var body: some View {
        // A reader rather than a bound scroll position, so the hiker's own
        // scrolling writes nothing into this view — ``RecordingView``'s reason.
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                    header
                    Text("Move the map to put the pin where the place is.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("hike-place-adder-placement-hint")
                    actions
                    HikePlaceStagedPhotoStrip(session: session)
                        .id(Self.stripID)
                        .background {
                            HikePlaceStagedPhotoArrival(session: session) {
                                withAnimation { scroller.scrollTo(Self.stripID) }
                            }
                        }
                    fields
                    HikePlaceAdderLocation(spot: spot, placePins: placePins)
                }
                .padding()
            }
        }
        .softScrollEdgeEffect(for: .top)
        .disabled(session.isAdding)
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
                Button(role: .cancel, action: onCancel)
                    .disabled(session.isAdding)
                    .accessibilityIdentifier("hike-place-adder-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                // A view of its own: a `.toolbar` closure is evaluated with
                // the body around it, so reading the staging count here would
                // re-run this whole form at every photograph's arrival — the
                // thing the strip reads the session itself to avoid.
                HikePlaceAdderAddButton(session: session, add: add)
            }
        }
        .background {
            HikePlacePinClaim(hike: hike, controller: placePins, placeholder: session.draft.placeholder(at: spot))
        }
        // The session's own staging rather than this view's: a camera this
        // form presented can outlive it by a turn of the phone, and its
        // picture belongs to the form the new host draws.
        .photoCapturePickers(
            $session.capture,
            onCaptured: { frame in session.stage(frame) },
            onPicked: { items in session.stage(items) }
        )
        .photoCaptureAlerts($session.capture)
        .hikePlaceRefusalAlert($session.refusal)
        .onChange(of: session.capture.failure) { _, failure in
            guard failure == nil, let addedID = session.addedID else { return }
            onAdded(addedID)
        }
        .accessibilityIdentifier("hike-place-adder")
    }

    private var header: some View {
        let shown = session.draft.placeholder(at: spot).place
        return PlaceCardHeader {
            TrailPlaceBadge(systemImage: shown.systemImageName, tint: shown.tint)
        } title: {
            Text(session.draft.displayName)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("hike-place-adder-title")
        } subtitle: {
            Text("Added by you")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            TrailPlacePhotoButtons(
                cameraIdentifier: "hike-place-adder-camera",
                libraryIdentifier: "hike-place-adder-library",
                onCamera: { Task { await openCamera() } },
                onLibrary: {
                    session.capture.pickedPhotos = []
                    session.capture.showLibraryPicker = true
                }
            )
        }
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fields: some View {
        StatList(title: String(localized: "Details")) {
            TextField(
                "Name",
                text: $session.draft.name,
                prompt: Text(TrailPlace.unnamedName(for: session.draft.symbol))
            )
            .trailPlaceRow()
            .accessibilityIdentifier("hike-place-adder-name")
            LabeledContent("Kind") {
                TrailPlaceKindPicker(
                    selection: Binding(get: { session.draft.symbol }, set: { session.draft.setKind($0) })
                )
                .labelsHidden()
            }
            .trailPlaceRow()
            TextField("Note", text: $session.draft.note, axis: .vertical)
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
        case .granted: session.capture.showCamera = true
        case .denied: session.capture.cameraAccessDenied = true
        case .unavailable: break
        }
    }

    /// Puts the place on the hike, files every held photograph under it, and
    /// opens it — after the alert, if a photograph did not make it. A refused
    /// save leaves the form and its photographs as they were.
    private func add() {
        guard !session.isAdding, session.stagingCount == 0, hike.isAttached else { return }
        // Where the pin stands now, not where the form opened.
        let place = session.draft.place(at: placePins?.placement(of: spot) ?? spot)
        do throws(HikePlaceRefusal) {
            guard try HikePlaceChange.add(place, to: hike, in: modelContext) else { return }
        } catch {
            session.refusal = error
            return
        }
        session.isAdding = true
        let staged = session.photos
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
            session.isAdding = false
            guard let failure else {
                onAdded(place.id)
                return
            }
            session.addedID = place.id
            session.capture.failure = failure
        }
    }
}

/// Where the place will go, following the map as it is moved under the pin.
///
/// Its own view so a settle of the map redraws these rows and not the form —
/// the reason ``HikePlaceStagedPhotoStrip`` is split out.
private struct HikePlaceAdderLocation: View {
    let spot: HikePlaceSpot
    let placePins: TrailPlacePinController?

    var body: some View {
        TrailPlaceFactsAndLocation(facts: [], coordinate: (placePins?.placement(of: spot) ?? spot).coordinate)
    }
}

/// *Add*, or a spinner while it cannot be tapped yet: while photographs are
/// still being read into the strip, or are being filed under the new place.
private struct HikePlaceAdderAddButton: View {
    let session: HikePlaceAdderSession
    let add: () -> Void

    var body: some View {
        if session.isAdding || session.stagingCount > 0 {
            ProgressView()
        } else {
            Button(role: .confirm, action: add)
                .accessibilityIdentifier("hike-place-adder-add")
        }
    }
}

/// Brings the strip wholly into view as a photograph arrives in it.
///
/// Right under the photo buttons the strip is mostly in view already, but the
/// foot of a landscape panel cuts across it, and a picture is meant to be seen
/// arriving: one that landed out of sight closed the camera on a form that
/// looked exactly as it had, which reads as the picture never having made it.
/// The smallest scroll that shows the strip whole leaves *Take Photo* on
/// screen for the next one. Its own view, reading the count, so an arrival
/// re-runs this and not the form.
private struct HikePlaceStagedPhotoArrival: View {
    let session: HikePlaceAdderSession
    let reveal: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: session.photos.count) { held, holding in
                if holding > held { reveal() }
            }
    }
}

/// The photographs *Add Place* is holding, each with a way to take it back.
///
/// Its own view so the strip belongs to it rather than to the form, whose
/// every keystroke would otherwise rebuild it — ``HikePlaceView``'s strip is
/// split out for the same reason. It reads the photographs off the session
/// itself, so one arriving redraws the strip and not the form.
private struct HikePlaceStagedPhotoStrip: View {
    /// The remove button's scrim, dark enough for its white cross to read
    /// over a bright sky.
    private static let scrimOpacity = 0.6
    private static let removeInset: CGFloat = 4
    /// What a tile shows for a photograph no thumbnail could be made of.
    private static let pendingOpacity = 0.2

    let session: HikePlaceAdderSession

    var body: some View {
        let photos = session.photos
        VStack(alignment: .leading, spacing: 8) {
            Text("Photos")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if photos.isEmpty {
                Text("No photos yet. Take one here, or add some from your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { tiles in
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
                    // The newest goes on the end, which is past the edge of a
                    // landscape panel from the fourth on.
                    .onChange(of: photos.last?.id) { _, newest in
                        guard let newest else { return }
                        withAnimation { tiles.scrollTo(newest) }
                    }
                }
            }
        }
    }

    private func tile(_ photo: HikePlaceStagedPhoto, label: String) -> some View {
        thumbnail(photo)
            .frame(width: PhotoTileMetrics.stripTileSize, height: PhotoTileMetrics.stripTileSize)
            .clipShape(.rect(cornerRadius: PhotoTileMetrics.cornerRadius))
            .overlay(alignment: .topTrailing) {
                Button("Remove Photo", systemImage: "xmark.circle.fill") { session.remove(photo.id) }
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
