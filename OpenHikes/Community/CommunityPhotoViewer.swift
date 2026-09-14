//
//  CommunityPhotoViewer.swift
//  OpenHikes
//
//  A shared hike's photographs, one at a time and as large as the sheet will
//  allow.
//
//  The strip on ``CommunityHikeView`` is a row of 96-point squares, which is
//  enough to count photographs and not enough to look at one. Somebody
//  deciding whether to walk a stranger's trail is deciding on the pictures as
//  much as on the numbers, so the strip opens the same way the hiker's own
//  gallery does — see ``HikePhotoViewer``, whose shape this follows
//  deliberately: pushed onto the sheet's navigation stack rather than
//  presented as a cover, because a cover over a detented sheet tears the sheet
//  down when it dismisses; paged through a horizontally paged `ScrollView`
//  rather than a `TabView`, so a swipe and the two buttons drive one
//  `scrollPosition` and cannot disagree; and asking for the whole sheet
//  through ``SheetRoute/prefersFullHeight``, because a picture in the medium
//  detent is a stamp.
//
//  ## What it does not inherit
//
//  Three of that screen's affordances are about owning the photograph and have
//  no meaning here. There is no *Delete*: these files are somebody else's, and
//  the copy on this device is a download the preview below deletes on its way
//  out. There is no *Try Again* and no missing-file state either — the two
//  cases ``PhotoDisplay`` exists to tell apart are about
//  ``HikePhotoStore``'s directory and a hike walked on another phone, and
//  neither is reachable for a file this process wrote minutes ago. A decode
//  that fails here says so once and offers nothing, which is all there is to
//  offer.
//
//  What it does inherit is *where was this taken*, and that one earns its
//  place twice over: a shared photograph carries a coordinate in the
//  submission's pins, and the map behind this sheet is already drawing it —
//  see ``MapCommunityPhotoAnnotations``. So the button frames the camera on
//  the pin rather than dropping a marker of its own, which is the one real
//  difference from ``HikePhotoViewer``'s: the hiker's own gallery has to put
//  a dot somewhere, and this one is being asked to go and look at a pin that
//  is already standing there.
//
//  ## Why the pictures arrive in the route
//
//  Because there is nowhere else to get them. They are files in a directory
//  ``CommunityHikeView`` owns per visit, the detail holding them never leaves
//  that screen, and the sheet that builds this destination has no transport
//  and no download of its own. Carrying them is also what keeps the preview
//  underneath on the stack, which is what stops those files being collected
//  while this screen is drawing them — see ``SheetRoute/communityPhoto(_:_:_:)``.
//

import CoreLocation
import MapKit
import SwiftUI

/// The page a shared hike's gallery is resting on, retained while its route is
/// on the sheet's stack.
///
/// The job ``PhotoViewerSelection`` does for the hiker's own gallery, and a
/// separate type rather than a second field on it because the two identify a
/// page differently: a ``HikePhoto`` has a `UUID`, and one of somebody else's
/// photographs has nothing but its position in the submission — which is the
/// same thing its pin is paired by. See ``SheetPresentation``, which holds
/// both and releases each with its route.
final class CommunityPhotoSelection {
    var currentIndex: Int?
}

struct CommunityPhotoViewer: View {
    /// Every downloaded photograph of the hike, in strip order.
    let photos: [CommunityGalleryPhoto]
    /// The one the strip was tapped on. Only the opening position — paging
    /// afterwards is remembered by ``selection``.
    let startIndex: Int
    var mapController: MapController
    /// Told just before this screen dismisses itself to show a photograph's
    /// place on the map, so the sheet gets out of the way rather than snapping
    /// back over the pin it was asked to reveal.
    var onShowOnMap: () -> Void = { /* no-op default */ }
    var selection = CommunityPhotoSelection()

    /// No bigger than the file: ``CommunityPublisher/photoMaxPixelSize``
    /// re-encodes every published photograph to 1600 points on its long edge,
    /// so asking for more would be asking `ImageIO` to upscale.
    private static let pageMaxPixelSize = 1600

    @State private var currentIndex: Int?
    @State private var didRestoreStart = false

    var body: some View {
        let current = currentIndex.flatMap { index in
            photos.indices.contains(index) ? photos[index] : nil
        }
        // A photograph is shown against black everywhere in iOS, and the pages
        // letterbox rather than crop, so the backdrop is doing real work: it is
        // what the un-filled edges of a portrait shot on a landscape screen
        // become.
        return ZStack {
            Color.black.ignoresSafeArea()
            pages
        }
        .overlay(alignment: .bottom) { controls }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The backdrop is black whatever the device is set to, so the bar has
        // to be told that: without this the title renders in the light
        // scheme's label colour and is black on black.
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar { toolbarContent(current) }
        .accessibilityIdentifier("community-photo-viewer")
        .onAppear {
            // Assigning the scroll position before the scroll view exists is
            // ignored, so the opening page is set on the first appearance and
            // never again — a rotation that replaces the host comes back to
            // whatever the hiker was last looking at.
            guard !didRestoreStart else { return }
            didRestoreStart = true
            let restored = selection.currentIndex ?? startIndex
            currentIndex = photos.indices.contains(restored) ? restored : photos.first?.index
        }
        .onChange(of: currentIndex) { _, index in
            // A scroll view may report nil while its host is being removed.
            // Only an actual page replaces the remembered selection.
            if let index { selection.currentIndex = index }
        }
    }

    // MARK: - Pages

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos) { photo in
                    CommunityPhotoPage(
                        photo: photo,
                        maxPixelSize: Self.pageMaxPixelSize,
                        label: Self.label(for: photo, of: photos.count)
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(photo.index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentIndex)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Controls

    /// Previous and next, merged into one pill.
    ///
    /// Disabled rather than hidden at the two ends, for the reason the hiker's
    /// own gallery gives: a control that disappears moves the one beside it,
    /// and at the end of a gallery that would shift the button about to be
    /// pressed.
    ///
    /// **Automation reaches these two by label, not by identifier**, and the
    /// identifiers below are there for symmetry with ``HikePhotoViewer``
    /// rather than because anything can use them: this screen carries
    /// `community-photo-viewer` on the `ZStack`, and SwiftUI pushes a
    /// container's identifier down onto every descendant — so the leaf names
    /// inside it are smothered. The toolbar escapes that, which is why the
    /// map button's identifier does work. The same shape one screen over is
    /// why ``PhotoUITests`` asks for `app.buttons["Next photo"]`.
    private var controls: some View {
        GlassStack(spacing: 6) {
            HStack(spacing: 6) {
                stepButton(
                    systemImage: "chevron.left",
                    label: "Previous photo",
                    identifier: "community-previous-photo-button",
                    offset: -1
                )
                stepButton(
                    systemImage: "chevron.right",
                    label: "Next photo",
                    identifier: "community-next-photo-button",
                    offset: 1
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
        offset: Int
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
        .disabled(destination(by: offset) == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ current: CommunityGalleryPhoto?) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let coordinate = current?.coordinate {
                CommunityPhotoMapButton(
                    coordinate: coordinate,
                    mapController: mapController,
                    onShowOnMap: onShowOnMap
                )
            }
        }
    }

    // MARK: - Titles

    private var title: String {
        guard let index = currentIndex, photos.indices.contains(index) else {
            return String(localized: "Photo")
        }
        return String(localized: "\(index + 1) of \(photos.count)")
    }

    /// What a page is called, which is its place in the walk and when it was
    /// taken.
    ///
    /// The capture time is the one fact about somebody else's photograph this
    /// app actually knows, and it is what the share sheet promised travelled
    /// with the picture — so saying it here is the app showing what it said it
    /// would carry, exactly as a map pin's subtitle does.
    private static func label(for photo: CommunityGalleryPhoto, of count: Int) -> String {
        let place = String(localized: "Photo \(photo.index + 1) of \(count)")
        guard let takenAt = photo.pin?.capturedAt else { return place }
        return String(localized: "\(place), taken \(HikeFormat.timestamp(takenAt))")
    }

    // MARK: - Actions

    /// The page `offset` steps away, or `nil` at either end.
    private func destination(by offset: Int) -> Int? {
        guard let index = currentIndex else { return nil }
        let target = index + offset
        return photos.indices.contains(target) ? target : nil
    }

    private func step(by offset: Int) {
        guard let target = destination(by: offset) else { return }
        withAnimation { currentIndex = target }
    }
}

/// Frames the map on where a shared photograph was taken, and gets out of the
/// way so it can be seen.
///
/// A view rather than a button in the viewer's toolbar closure, because
/// `@Environment(\.dismiss)` invalidates the view that declares it whether or
/// not its body reads it — see ``DismissButton`` for what that costs a screen
/// which re-decodes a photograph on every pass.
///
/// It moves the camera and nothing else, which is the one real difference from
/// ``HikePhotoViewer``'s version. That one has to put a marker on the map
/// because nothing else is standing for the photograph; here the preview
/// already drew a pin for every anchored picture, and a second marker on top
/// of it would be two things standing for one photograph.
///
/// "Out of the way" is the whole sheet rather than just this screen. Popping
/// alone restores the height the preview was being read at, which on a screen
/// that had been at `.large` is a sheet closing straight back over the pin —
/// so the sheet is asked to collapse first and the pop finds that decision
/// already made.
private struct CommunityPhotoMapButton: View {
    let coordinate: CLLocationCoordinate2D
    var mapController: MapController
    let onShowOnMap: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    /// Close enough to see the bend in the trail the photograph was taken
    /// from. The same span the hiker's own gallery frames.
    private static let regionMeters: CLLocationDistance = 500

    var body: some View {
        Button {
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
        .accessibilityIdentifier("community-photo-show-on-map-button")
    }
}

/// One full-bleed page.
///
/// Separate from the viewer so paging redraws a page rather than the toolbar,
/// the title and the button pill with it — and so the `.task(id:)` that
/// decodes belongs to the page that needs it and is cancelled when that page
/// is recycled.
private struct CommunityPhotoPage: View {
    let photo: CommunityGalleryPhoto
    let maxPixelSize: Int
    /// What this page is called. Composed by the viewer, which is the only
    /// thing that knows how many there are.
    let label: String

    @State private var image: Image?
    @State private var didFinishDecoding = false

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
            } else if didFinishDecoding {
                unreadable
            }
            // Before the decode lands: nothing at all, on the black the viewer
            // already drew. A spinner that appears and vanishes within a frame
            // or two reads as a glitch, which is the argument
            // ``CommunityPhotoTile`` makes about the same files one size down.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .task(id: photo.fileURL) {
            image = await CommunityPhotoTile.decode(photo.fileURL, maxPixelSize: maxPixelSize)
            didFinishDecoding = true
        }
    }

    /// Said once, with nothing offered.
    ///
    /// Retry is what the hiker's own viewer offers, and it is worth offering
    /// there because an unreadable file is often temporary — bytes still
    /// coming down from a restore, a volume that was not mounted. Neither is
    /// reachable for a file this process downloaded minutes ago into a
    /// directory it owns, so a button here could only re-run a decode that has
    /// already answered.
    private var unreadable: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("This photograph couldn\u{2019}t be opened.")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        guard didFinishDecoding, image == nil else { return label }
        return String(localized: "\(label), unavailable")
    }
}
