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
//  `.large`, so "as large as the sheet will allow" is the whole screen. In
//  landscape there is no sheet: the side panel the stack lives in widens to
//  the whole window instead — see ``MapSidePanel``.
//
//  The pages are ``HikePhotoPager``, which the share form's gallery pages
//  through as well.
//
//  *Show on map* keeps the gallery open. It frames the photograph's spot,
//  opens its pin and drops the sheet to the middle detent — in landscape, the
//  panel back to its column — so the picture and the place it was taken are
//  on screen together. From there a swipe moves the open callout to the next
//  photograph's pin, or closes it for one with no place on the trail, without
//  zooming: the hiker paging through the walk chose the zoom they are reading
//  it at, so a pin out of view is slid into it rather than framed. A tap on
//  the photograph, or a drag, gives it the whole screen again.
//
//  All of which needs the pins on the map while the gallery is up, so this
//  screen claims the hike's pins for itself rather than leaving them to the
//  hike screen underneath, whose claim goes when this one is pushed over it —
//  see ``HikePhotoPinClaim``.
//
//  A page that cannot be drawn says so, and says which thing happened. The
//  store answers "not decoded yet" and "there is no file" with the same `nil`,
//  and a viewer that renders a spinner for both turns a missing photo into a
//  screen that never resolves; ``PhotoDisplay`` is what separates them.
//
//  The two failures are not the same news either. A file that is here and
//  unreadable may be readable in a moment, so that page offers to ask again or
//  to take the row that claims the file out of the hike. A file that is not
//  here has nothing to wait for: photo pixels stay on the device the photo was
//  added on — see *Settled decisions* in the repository instructions — so that
//  page explains itself and offers nothing, because both of the other page's
//  buttons would be lies about what pressing them does.
//
//  The toolbar is held to that same rule, which it is easy not to be: it is
//  drawn once for the screen rather than per page, so a button that suits the
//  picture in front of the hiker is not thereby a button that suits the next
//  one. *Share* is the one this bites — a page with no file behind it would
//  otherwise raise the share sheet and then fail inside it, which is the
//  failure arriving after the gesture rather than in place of it. Which pages
//  have a file is ``HikePhotoViewer/shareablePhotos``.
//

import CoreLocation
import MapKit
import OpenHikesData
import SwiftUI

struct HikePhotoViewer: View {
    let hike: Hike
    /// The photo the gallery strip was tapped on. Only the initial position —
    /// paging afterwards is remembered by the navigation session.
    let startID: UUID
    var highlight: RouteHighlight
    var mapController: MapController
    /// The sheet this screen is pushed into: lowered by *Show on map* to bring
    /// the map in under the gallery, raised again by a tap on the photograph,
    /// and asked whether the map is in view before a page moves its pin.
    /// `nil` in a preview or a test that has no sheet around it.
    var presentation: SheetPresentation?
    /// The pins on the map: drawn while this screen is up, and the one for the
    /// photograph on screen opened by *Show on map*. `nil` in a preview or a
    /// test that has no map behind it.
    var photoPins: PhotoMapPinController?
    var store: HikePhotoStore = .shared

    var selection = PhotoViewerSelection()

    @State private var currentID: UUID?
    @State private var didRestoreStart = false
    /// Up while the trash button is waiting for an answer. The same question
    /// the swipe in *My Hikes* now asks, for the same reason: the file goes
    /// with the row, and photo pixels stay on the device the photo was added
    /// on — so this device is the only place they were.
    @State private var showDeleteConfirmation = false

    /// The photographs whose files are on this device, as the pages that drew
    /// them found out.
    ///
    /// What *Share* is offered on. `ShareLink` builds its item up front and
    /// only reaches the file when the system asks the exporter for it — by
    /// which time the sheet is up and the only thing left to do is throw
    /// ``HikePhotoFile/NotOnThisDevice``, in front of a hiker who has already
    /// chosen who they were sending it to. So the question is asked before the
    /// button is offered rather than after it is pressed.
    ///
    /// Filled from the pages' own loads rather than by a check of its own, for
    /// two reasons that agree: every page already learns this on the way to
    /// drawing itself — a decode that returned a picture is a file that is
    /// there — and ``HikePhotoStore/hasImage(for:)`` asserts it is off the
    /// main thread, which is exactly where a toolbar's condition is evaluated.
    @State private var shareablePhotos: Set<UUID> = []

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
        let photos = hike.orderedPhotos
        let currentIndex = index(of: currentID, in: photos)
        // A coarse flag that moves when the map is brought in or covered
        // again, which is exactly when the photograph's tap changes meaning.
        let coversMap = presentation?.isShowingFullHeightScreen ?? true
        // The black surface and the bar that has to be told about it are
        // ``photoGalleryChrome()``, which the community gallery wears too.
        return Group {
            if photos.isEmpty {
                emptyState
            } else {
                pages(photos, coversMap: coversMap)
            }
        }
        .photoGalleryChrome()
        // The hike's pins, for as long as the gallery is up — the hike screen
        // that drew them is pushed under this one and has handed its claim
        // back. A tap on one pages here rather than pushing a second gallery.
        .background {
            HikePhotoPinClaim(hike: hike, controller: photoPins) { showFromPin($0) }
        }
        .overlay(alignment: .bottom) { bottomBar(photos, currentIndex: currentIndex) }
        .navigationTitle(title(photos, currentIndex: currentIndex))
        .toolbar {
            toolbarContent(
                currentIndex.map { photos[$0] },
                position: currentIndex.map { $0 + 1 }
            )
        }
        .accessibilityIdentifier("photo-viewer")
        .onAppear {
            // Assigning the scroll position before the scroll view exists is
            // ignored, so the opening photo is set on the first appearance and
            // never again — a re-entry after a delete keeps whatever the user
            // was last looking at.
            guard !didRestoreStart else { return }
            didRestoreStart = true
            let restoredID = selection.currentID ?? startID
            currentID = photos.contains { $0.id == restoredID }
                ? restoredID
                : photos.first?.id
        }
        .onChange(of: currentID) { _, id in
            // A scroll view may report nil while its host is being removed.
            // Only an actual page replaces the remembered selection.
            guard let id else { return }
            selection.currentID = id
            followOnMap(id)
        }
        // A viewer with nothing left to view is a dead end; deleting the last
        // photo returns to the hike. Through the modifier rather than an
        // `.onChange` closing over `dismiss`, because the environment's
        // dismiss action would then be an input of this body — see
        // ``DismissButton``. It cost seven passes of this screen, each one
        // re-sorting the gallery, for a single backgrounding.
        .dismiss(when: photos.isEmpty)
        .confirmationDialog(
            "Delete this photograph?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: currentIndex.map { photos[$0] }
        ) { photo in
            Button("Delete Photo", role: .destructive) { delete(photo) }
            Button("Cancel", role: .cancel) { /* intentionally empty */ }
        } message: { _ in
            Text("The photograph is deleted from this device for good.")
        }
    }

    // MARK: - Pages

    /// The pages, and what a tap on one does: nothing while the gallery has
    /// the whole screen, and gives it back once the map has been brought in.
    private func pages(_ photos: [HikePhoto], coversMap: Bool) -> some View {
        HikePhotoPager(
            photos: photos,
            currentID: $currentID,
            store: store,
            onFileFound: { id, found in noteFile(for: id, found: found) },
            onRemove: { delete($0) },
            onTapPhoto: coversMap ? nil : { presentation?.coverMapWithFullHeightScreen() }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Photos",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Photos you take on this hike appear here.")
        )
    }

    // MARK: - Controls

    /// What stands over the bottom of the photograph: who took it, and the
    /// way to the next one.
    ///
    /// One ``GlassStack`` around both, which is the rule this app follows
    /// wherever two pieces of glass sit near each other — separate containers
    /// each sample the backdrop for themselves, and two that nearly touch
    /// render as two panes rather than merging as they approach. See that
    /// type, where the cost is the argument.
    ///
    /// The credit is above the pill rather than beside it, and its visibility
    /// is its own: the pill goes transparent on a gallery of one, and a credit
    /// is exactly as due on a single photograph as on the fortieth.
    private func bottomBar(_ photos: [HikePhoto], currentIndex: Int?) -> some View {
        GlassStack(spacing: 6) {
            VStack(spacing: 10) {
                credit(currentIndex.map { photos[$0] })
                stepControls(photos, currentIndex: currentIndex)
            }
        }
        .padding(.bottom, 20)
    }

    /// Previous and next, merged into one pill.
    ///
    /// Disabled rather than hidden at the two ends: a control that disappears
    /// moves the one beside it, and at the end of a gallery that would shift
    /// the button the user is about to press.
    private func stepControls(_ photos: [HikePhoto], currentIndex: Int?) -> some View {
        PhotoStepControls(
            previousIdentifier: "previous-photo-button",
            nextIdentifier: "next-photo-button",
            // This gallery's own question about its own list: it is handed the
            // photographs and the index from above rather than holding them.
            hasDestination: { destination(from: currentIndex, by: $0, in: photos) != nil },
            step: { step(by: $0) }
        )
        .photoStepVisibility(count: photos.count)
    }

    /// Who took the photograph on screen, when that is somebody other than
    /// the hiker looking at it and other than whoever published the walk.
    ///
    /// Drawn from ``HikePhoto/importedAuthorName``, which is set on exactly
    /// one kind of row: a copy of a photograph another hiker *contributed* to
    /// a shared trail, taken when this hiker saved that trail — see
    /// ``CommunityImport``. Everything else draws nothing, which is almost
    /// every photograph in almost every library.
    ///
    /// It is the same credit the community gallery puts under the same
    /// picture, and the reason it has to survive the import is that the import
    /// is the point at which the picture stops sitting under the name of the
    /// person who took it. A hike's own *Shared by* row names whoever
    /// published the route, which for these is the wrong person.
    @ViewBuilder
    private func credit(_ photo: HikePhoto?) -> some View {
        if let name = photo?.importedAuthorName, !name.isEmpty {
            Text("Photo by \(name)")
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(.regular, in: Capsule())
                // The backdrop is black whatever the device is set to, the
                // same reason the navigation bar above is told this.
                .environment(\.colorScheme, .dark)
                .accessibilityIdentifier("photo-credit")
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(
        _ current: HikePhoto?,
        position: Int?
    ) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let current, let coordinate = current.coordinate {
                ShowPhotoSpotButton(
                    coordinate: coordinate,
                    mapController: mapController,
                    identifier: "photo-show-on-map-button",
                    leavesTheGallery: false,
                    beforeFraming: { highlight.move(to: coordinate) },
                    thenSelecting: {
                        photoPins?.select(current.id)
                        presentation?.revealMapUnderFullHeightScreen()
                    }
                )
            }
        }
        // Beside *show me where this was* rather than beyond the spacer below,
        // because the two belong together: both take the photograph somewhere
        // and neither destroys it. The capsule around the pair is what says so.
        // Absent rather than disabled on a page with no file behind it. A
        // disabled button is still an offer — it says *not now* about
        // something that is never going to be available here — and the page
        // underneath is already saying the whole of it. See
        // ``shareablePhotos``, and note that it arrives with the picture: the
        // button is not there for the moment a page is still loading, which is
        // the same moment there is nothing on screen to share.
        ToolbarItem(placement: .topBarTrailing) {
            if let current, let position, shareablePhotos.contains(current.id) {
                SharePhotoButton(
                    photo: current,
                    hikeTitle: hike.displayTitle,
                    position: position,
                    store: store
                )
            }
        }
        // Two items, split rather than one group: *show me where this was* and
        // *delete this* share a placement and nothing else, and a single glass
        // capsule around both puts the destructive one a fingertip from the
        // harmless one with no edge between them. See ``GlassToolbarSpacer``.
        GlassToolbarSpacer(placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            if current != nil {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
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

    /// Moves the map's open pin and the route's dot to the page now on
    /// screen, while the map is in view to show them.
    ///
    /// The zoom stays where it is. *Show on map* is the button that frames a
    /// spot; a swipe is the hiker reading on through the walk at the zoom
    /// they chose, so a pin under the sheet or past the edge of the map is
    /// slid into view rather than framed — see
    /// ``PhotoMapPinController/select(_:slidingIntoView:)``.
    /// A photograph with no place on the trail closes the callout, which would
    /// otherwise be previewing a picture that is no longer the one on screen.
    private func followOnMap(_ id: UUID) {
        guard let presentation, !presentation.isShowingFullHeightScreen,
              let photo = hike.photos.first(where: { $0.id == id }) else { return }
        let place = photo.coordinate.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
        highlight.move(to: place)
        if place != nil {
            photoPins?.select(id, slidingIntoView: true)
        } else {
            photoPins?.deselect()
        }
    }

    /// A pin tapped on the map beside the gallery: its photograph, on the
    /// whole screen. The pin's photo is the first of its spot — see
    /// ``PhotoMapPin/photo``.
    private func showFromPin(_ photo: HikePhoto) {
        withAnimation { currentID = photo.id }
        presentation?.coverMapWithFullHeightScreen()
    }

    /// Remembers what a page's load found out about its file.
    ///
    /// By identifier rather than by index, because pages are recycled and the
    /// answer belongs to the photograph rather than to the position it was
    /// read at.
    private func noteFile(for id: UUID, found: Bool) {
        if found {
            shareablePhotos.insert(id)
        } else {
            shareablePhotos.remove(id)
        }
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

/// Hands the photograph itself to the share sheet.
///
/// The stored file rather than a re-encode, and named after the hike and the
/// page rather than after the store's own file — see ``HikePhotoFile``, which
/// argues both.
///
/// Built here rather than inside ``HikePhotoFile`` because the two facts it
/// needs are on this side of the main actor: the photograph is a `@Model` and
/// the position is the viewer's own, and what crosses into the exporter is a
/// path and a string.
private struct SharePhotoButton: View {
    let photo: HikePhoto
    let hikeTitle: String
    let position: Int
    let store: HikePhotoStore

    var body: some View {
        ShareLink(
            item: HikePhotoFile(
                source: store.url(for: photo),
                suggestedName: GPXExport.photoFileName(
                    hikeTitle: hikeTitle,
                    position: position,
                    pathExtension: store.url(for: photo).pathExtension
                )
            ),
            preview: SharePreview(
                // What the viewer's own title says, so the sheet's header and
                // the screen behind it agree about which picture is going.
                String(localized: "Photo \(position)"),
                icon: Image(systemName: "photo")
            )
        ) {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share photo")
        .accessibilityIdentifier("photo-share-button")
    }
}
