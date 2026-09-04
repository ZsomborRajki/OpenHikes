//
//  HikePhotoViewer.swift
//  OpenHikes
//
//  One photo, as large as the sheet will allow, with a way to the next and the
//  previous one.
//
//  Pushed onto the sheet's own navigation stack rather than presented as a
//  full-screen cover. A cover over a detented sheet tears the sheet down when
//  it dismisses — the same iOS behaviour `OpenHikesView` already works around
//  for the GPX importer — and pushing keeps the back gesture, the toolbar and
//  the sheet's glass instead of fighting them. The push raises the detent to
//  `.large`, so "as large as the sheet will allow" is the whole screen.
//
//  Paging is a horizontally paged `ScrollView` rather than a `TabView`, so a
//  swipe and the two buttons drive the same `scrollPosition` and cannot
//  disagree about which photo is showing.
//
//  A page that cannot be drawn says so, and says which thing happened. The
//  store answers "not decoded yet" and "there is no file" with the same `nil`,
//  and a viewer that renders a spinner for both turns a missing photo into a
//  screen that never resolves; ``PhotoDisplay`` is what separates them.
//
//  The two failures are not the same news either. A file that is here and
//  unreadable may be readable in a moment, so that page offers to ask again or
//  to take the row that claims the file out of the hike. A file that is not
//  here has nothing to wait for: photo pixels stay on the device that took
//  them — see *Settled decisions* in the repository instructions — so that
//  page explains itself and offers nothing, because both of the other page's
//  buttons would be lies about what pressing them does.
//

import CoreLocation
import MapKit
import SwiftUI

struct HikePhotoViewer: View {
    let hike: Hike
    /// The photo the gallery strip was tapped on. Only the initial position —
    /// paging afterwards is this view's own state.
    let startID: UUID
    var highlight: RouteHighlight
    var mapController: MapController
    /// Told just before this screen dismisses itself to show a photo's place
    /// on the map, so the sheet can get out of the way rather than snapping
    /// back over the coordinate it was asked to reveal.
    var onShowOnMap: () -> Void = { /* no-op default */ }
    var store: HikePhotoStore = .shared

    @State private var currentID: UUID?
    @State private var didRestoreStart = false

    /// The sorted gallery, read once per body pass and handed down.
    ///
    /// It used to be a computed property, which made every use of it look free
    /// — and there were six, so a swipe cost six full sorts of the hike's
    /// photos, each one allocating a `uuidString` per comparison. A computed
    /// property that does real work is invisible at its call sites, which is
    /// exactly how that survived review; passing the value down makes the cost
    /// countable and pays it once.
    ///
    /// There is deliberately no `photos` property here any more. One existed,
    /// spelled `hike.orderedPhotos`, and its innocence is the whole bug — so
    /// the sort is now written out at each of the three places that take a
    /// snapshot, where it is visible.

    private func index(of id: UUID?, in photos: [HikePhoto]) -> Int? {
        guard let id else { return nil }
        return photos.firstIndex { $0.id == id }
    }

    var body: some View {
        RenderSignpost.mark("PhotoViewerBody")
        let photos = hike.orderedPhotos
        let currentIndex = index(of: currentID, in: photos)
        // A photo is shown against black everywhere in iOS, and the strip's
        // tiles are letterboxed here rather than cropped, so the backdrop is
        // doing real work: it's what the un-filled edges of a portrait shot on
        // a landscape screen become.
        return ZStack {
            Color.black.ignoresSafeArea()
            if photos.isEmpty {
                emptyState
            } else {
                pages(photos)
            }
        }
        .overlay(alignment: .bottom) { controls(photos, currentIndex: currentIndex) }
        .navigationTitle(title(photos, currentIndex: currentIndex))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The backdrop is black whatever the device is set to, so the bar has
        // to be told that: without this the title renders in the light
        // scheme's label colour and is black on black.
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar { toolbarContent(currentIndex.map { photos[$0] }) }
        .accessibilityIdentifier("photo-viewer")
        .onAppear {
            // Assigning the scroll position before the scroll view exists is
            // ignored, so the opening photo is set on the first appearance and
            // never again — a re-entry after a delete keeps whatever the user
            // was last looking at.
            guard !didRestoreStart else { return }
            didRestoreStart = true
            currentID = photos.contains { $0.id == startID }
                ? startID
                : photos.first?.id
        }
        // A viewer with nothing left to view is a dead end; deleting the last
        // photo returns to the hike. Through the modifier rather than an
        // `.onChange` closing over `dismiss`, because the environment's
        // dismiss action would then be an input of this body — see
        // ``DismissButton``. It cost seven passes of this screen, each one
        // re-sorting the gallery, for a single backgrounding.
        .dismiss(when: photos.isEmpty)
    }

    // MARK: - Pages

    private func pages(_ photos: [HikePhoto]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos) { photo in
                    HikePhotoPage(photo: photo, store: store) { delete(photo) }
                        .containerRelativeFrame(.horizontal)
                        .id(photo.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentID)
        .ignoresSafeArea(edges: .bottom)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Photos",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Photos you take on this hike appear here.")
        )
    }

    // MARK: - Controls

    /// Previous and next, merged into one pill.
    ///
    /// Disabled rather than hidden at the two ends: a control that disappears
    /// moves the one beside it, and at the end of a gallery that would shift
    /// the button the user is about to press.
    private func controls(_ photos: [HikePhoto], currentIndex: Int?) -> some View {
        GlassStack(spacing: 6) {
            HStack(spacing: 6) {
                stepButton(
                    systemImage: "chevron.left",
                    label: "Previous photo",
                    identifier: "previous-photo-button",
                    offset: -1,
                    photos: photos,
                    currentIndex: currentIndex
                )
                stepButton(
                    systemImage: "chevron.right",
                    label: "Next photo",
                    identifier: "next-photo-button",
                    offset: 1,
                    photos: photos,
                    currentIndex: currentIndex
                )
            }
        }
        .padding(.bottom, 20)
        .opacity(photos.count > 1 ? 1 : 0)
        .accessibilityHidden(photos.count <= 1)
    }

    private func stepButton(
        systemImage: String,
        label: LocalizedStringKey,
        identifier: String,
        offset: Int,
        photos: [HikePhoto],
        currentIndex: Int?
    ) -> some View {
        Button {
            step(by: offset)
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .minimumTapTarget()
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .disabled(destination(from: currentIndex, by: offset, in: photos) == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ current: HikePhoto?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let current, let coordinate = current.coordinate {
                ShowPhotoOnMapButton(
                    coordinate: coordinate,
                    highlight: highlight,
                    mapController: mapController,
                    onShowOnMap: onShowOnMap
                )
            }
            if let current {
                Button(role: .destructive) {
                    delete(current)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete photo")
                .accessibilityIdentifier("photo-delete-button")
            }
        }
    }

    // MARK: - Titles

    private func title(_ photos: [HikePhoto], currentIndex: Int?) -> String {
        guard let index = currentIndex else { return String(localized: "Photo") }
        return String(localized: "\(index + 1) of \(photos.count)")
    }

    // MARK: - Actions

    /// The index `offset` steps away, or `nil` at either end.
    private func destination(from index: Int?, by offset: Int, in photos: [HikePhoto]) -> Int? {
        guard let index else { return nil }
        let target = index + offset
        return photos.indices.contains(target) ? target : nil
    }

    private func step(by offset: Int) {
        let photos = hike.orderedPhotos
        guard let target = destination(
            from: index(of: currentID, in: photos),
            by: offset,
            in: photos
        ) else { return }
        withAnimation { currentID = photos[target].id }
    }

    private func delete(_ photo: HikePhoto) {
        // Step off the photo first: removing the one the scroll view is
        // resting on leaves `scrollPosition` pointing at an id that no longer
        // exists, and the view stays blank until something else moves it.
        let photos = hike.orderedPhotos
        let currentIndex = index(of: currentID, in: photos)
        let successor = destination(from: currentIndex, by: 1, in: photos)
            ?? destination(from: currentIndex, by: -1, in: photos)
        currentID = successor.map { photos[$0].id }
        HikePhotoImport.remove(photo, from: hike, store: store)
    }
}

/// Moves the map's selection dot to the photo's place on the trail and gets
/// out of the way so it can be seen.
///
/// A view rather than a button in the viewer's toolbar closure, because it is
/// the second of that screen's two readers of the environment's dismiss action
/// — see ``DismissButton`` for what declaring it costs the body around it.
///
/// The camera is framed on the coordinate at a fixed, close span rather than
/// re-fitted to the whole route: the point of the button is to see where one
/// photo was taken, and a route-wide fit would put it back in the middle of
/// everything.
///
/// "Out of the way" is the whole sheet, not just this screen. Popping alone
/// restores the height the hike was being read at, which on a screen that had
/// been at `.large` is a sheet closing straight back over the pin — so the
/// sheet is asked to collapse first, and the pop then finds that decision
/// already made.
private struct ShowPhotoOnMapButton: View {
    let coordinate: CLLocationCoordinate2D
    var highlight: RouteHighlight
    var mapController: MapController
    let onShowOnMap: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    /// Close enough to see the bend in the trail the photo was taken from.
    private static let regionMeters: CLLocationDistance = 500

    var body: some View {
        Button {
            highlight.move(to: coordinate)
            mapController.show(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: Self.regionMeters,
                    longitudinalMeters: Self.regionMeters
                )
            )
            onShowOnMap()
            dismiss()
        } label: {
            Image(systemName: "mappin.and.ellipse")
        }
        .accessibilityLabel("Show where this photo was taken")
        .accessibilityIdentifier("photo-show-on-map-button")
    }
}

/// One full-bleed page.
///
/// Separate from the viewer so paging redraws a page rather than the toolbar,
/// the title and the button pill with it — and so the `.task(id:)` that
/// decodes belongs to the page that needs it and is cancelled when that page
/// is recycled.
private struct HikePhotoPage: View {
    let photo: HikePhoto
    let store: HikePhotoStore
    /// Takes this photo's row out of the hike, for the case where its file is
    /// not coming back.
    ///
    /// Handed down rather than done here so it goes through the viewer's own
    /// `delete(_:)`, which steps the paging off this page first — a page that
    /// removes itself while the scroll view is resting on it leaves
    /// `scrollPosition` pointing at an id that no longer exists.
    var onRemove: () -> Void

    @State private var display = PhotoDisplay.loading
    /// Bumped by "Try Again", and part of the load's identity below.
    ///
    /// Retry is worth offering rather than being a placebo: an unreadable file
    /// is often a temporary condition — a photo whose bytes haven't finished
    /// coming down from a restore, a volume that wasn't mounted — and the
    /// alternative to a button is leaving the screen and coming back. Which is
    /// also why only that state offers it: nothing is on its way to a device
    /// that simply never had the file.
    @State private var attempt = 0

    var body: some View {
        ZStack {
            switch display {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityElement()
                    .accessibilityLabel(Self.label(for: photo))
            case .ready(let loaded):
                Image(photoImage: loaded.image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityElement()
                    .accessibilityLabel(Self.label(for: photo))
            case .unavailable(let reason):
                unavailable(reason)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Attempt(photo: photo.id, count: attempt)) {
            display = .loading
            display = await HikePhotoLoader.display(for: photo, in: store)
        }
    }

    /// A photo the hike still lists and the disk cannot produce, in whichever
    /// of the two ways that happened.
    @ViewBuilder
    private func unavailable(_ reason: PhotoUnavailability) -> some View {
        switch reason {
        case .notOnThisDevice:
            notOnThisDevice
        case .unreadable:
            unreadable
        }
    }

    /// A photo whose file is not here and is not coming.
    ///
    /// Nothing to press, on purpose. "Try Again" would be a placebo — photo
    /// files do not travel between devices and nothing is fetching this one,
    /// which is a decision rather than an omission; see *Settled decisions* in
    /// the repository instructions. And the removal the other state offers
    /// would take the row out of the hike on *every* device, including the one
    /// whose copy of the picture is perfectly fine. The toolbar's trash is
    /// still there for somebody who means exactly that; it is not what this
    /// page suggests they meant.
    private var notOnThisDevice: some View {
        ContentUnavailableView {
            Label("Not on This Device", systemImage: "icloud.slash")
        } description: {
            Text(
                """
                OpenHikes keeps photo files on the device that took them \u{2014} \
                only where and when the photo was taken travels with the hike.
                """
            )
        }
        .accessibilityIdentifier("photo-not-on-this-device")
        .environment(\.colorScheme, .dark)
    }

    /// A file that is here and could not be read.
    ///
    /// Both ways out are here because neither one is always right. The file
    /// may yet be readable — bytes still arriving from a restore, a volume
    /// that wasn't mounted — so the load can be asked for again; and when it
    /// never will be, the row claiming it is the thing to remove. That exit is
    /// what this state had none of, since it was indistinguishable from a load
    /// in progress and the toolbar's own delete was the only thing that could
    /// end it.
    private var unreadable: some View {
        VStack(spacing: Self.recoverySpacing) {
            ContentUnavailableView {
                Label("Photo Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    """
                    The file behind this photo is here but couldn\u{2019}t be read.
                    """
                )
            }
            // The buttons are siblings rather than `actions:` for the reason
            // `DiscoveryEmptyState` keeps them there: SwiftUI pushes a
            // container's identifier onto every descendant, so a button inside
            // this one would answer to this name instead of its own.
            .accessibilityIdentifier("photo-unavailable")

            HStack(spacing: Self.recoverySpacing) {
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("photo-retry-button")
                Button("Remove Photo", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("photo-remove-button")
            }
        }
        // The backdrop is black whatever the device is set to, so this subtree
        // has to be told which scheme it is being read against — the same
        // thing the navigation bar is told in the viewer above, and for the
        // same reason: without it the title and the description are black on
        // black.
        .environment(\.colorScheme, .dark)
    }

    private static let recoverySpacing: CGFloat = 16

    /// What a page's load is keyed on: the photo, and how many times the user
    /// has asked for it again.
    ///
    /// `.task(id:)` restarts on any change to this, which is what makes retry
    /// a bump of one integer rather than a second path into the loader.
    private struct Attempt: Hashable {
        let photo: UUID
        let count: Int
    }

    /// VoiceOver cannot describe a photograph, so it gets what the app does
    /// know about it: when it was taken, and whether it has a place on the
    /// trail.
    private static func label(for photo: HikePhoto) -> String {
        let taken = HikeFormat.timestamp(photo.capturedAt)
        return photo.isAnchored
            ? String(localized: "Photo taken \(taken), pinned to the trail")
            : String(localized: "Photo taken \(taken)")
    }
}
