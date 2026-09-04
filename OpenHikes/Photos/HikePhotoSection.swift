//
//  HikePhotoSection.swift
//  OpenHikes
//
//  The photo section of a hike's detail screen, above the surface breakdown
//  and below the numbers: a row of small squares when there are photos, and
//  the offer to go and find some whether there are or not.
//
//  The section is unconditional. It used to render nothing at all on a hike
//  nobody had photographed, and then nothing but a button — each gated on a
//  property of the route the user cannot see. A control that appears on some
//  hikes and not others is a feature people conclude does not exist, which is
//  exactly what happened. It is always here now, and the one case it cannot
//  be honoured on is explained by the sheet it opens rather than by its
//  absence.
//
//  Its own view, for the reason every other section on that screen is its own
//  view — taking a photo writes `hike.photos`, and that write should redraw a
//  row of thumbnails rather than the elevation chart, the stats grid and the
//  whole action bar with it.
//
//  Each tile decodes on the concurrent executor and only then hands back an
//  image; nothing here touches a file on the main thread. A tile that hasn't
//  finished is a placeholder rather than a spinner, because a thumbnail that
//  is already on disk arrives within a frame or two and a spinner that appears
//  and vanishes reads as a glitch.
//
//  A tile that never will finish is a different placeholder. Photo files stay
//  on the device the photo was added on — see *Settled decisions* in the
//  repository instructions — so on a second device the whole strip is photos
//  whose pixels are elsewhere, and a tile that says so is the difference
//  between an explanation and a row of broken pictures.
//

import SwiftUI

struct HikePhotoSection: View {
    let hike: Hike
    var store: HikePhotoStore = .shared
    /// Draws these photos on the map for as long as this strip is on screen.
    /// `nil` in a preview, and in a test that has no map.
    var mapPins: PhotoMapPinController?
    /// Opens the viewer at a photo.
    var onOpen: (HikePhoto) -> Void

    @State private var isDiscovering = false
    /// Created once per screen rather than per presentation, so the sheet can
    /// be reopened without losing what a scan already found. Its reader is
    /// resolved by ``PhotoLibrarySource``, which is what lets UI automation
    /// drive this without a photo library or a permission prompt.
    @State private var discovery = PhotoDiscoveryController(
        reader: PhotoLibrarySource.reader()
    )

    private static let tileSize: CGFloat = 76
    private static let tileSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        // Taking a photo writes `hike.photos`, and this is the body that
        // should absorb that write. The mark is how a regression that pushes
        // it up into `HikeDetailBody` — or a strip that re-renders once per
        // tile decode — becomes visible in the report rather than being
        // argued about.
        RenderSignpost.mark("HikePhotoSectionBody", "\(hike.photos.count) photos")
        // Ordered once and handed down. `orderedPhotos` sorts, and reading it
        // from both the strip and the caption below would sort twice for one
        // pass.
        let photos = hike.orderedPhotos
        return VStack(alignment: .leading, spacing: 12) {
            Text("Photos")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if !photos.isEmpty {
                gallery(photos)
            }

            discoverButton

            Text(caption(for: photos))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        // Inside the sheet, like every other modal this app presents: the
        // bottom sheet is never taken down, and a view can only have one
        // presentation at a time, so a `.sheet` attached beside it would never
        // appear at all. This view is already inside it.
        .sheet(isPresented: $isDiscovering) {
            PhotoDiscoverySheet(hike: hike, controller: discovery)
        }
    }

    /// The offer to go and find photographs of this walk, on every hike and in
    /// every state.
    ///
    /// It used to be hidden on a route without timestamps, on the argument
    /// that a button which could only report failure is worse than no button.
    /// That argument was wrong in practice: a control that comes and goes
    /// depending on a property of the route the user cannot see is a feature
    /// they cannot find, and "why is there no button here" is a worse question
    /// than "why did it find nothing". The sheet now has a state that answers
    /// the second one — see ``PhotoDiscoveryController/Phase/unsupported`` —
    /// and asking it costs no photo-library permission, because the timeline
    /// is built before access is requested.
    private var discoverButton: some View {
        Button {
            isDiscovering = true
        } label: {
            Label("Find Photos of This Hike", systemImage: "sparkle.magnifyingglass")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        // Deliberately not prefixed `hike-photo-`: the performance suite
        // counts the gallery's tiles by that prefix, and a button that is not
        // a photo answering to it would be counted as one.
        .accessibilityIdentifier("photo-discovery-button")
    }

    /// The horizontal strip of thumbnails, drawn only when there is at least
    /// one.
    ///
    /// The pins go up from here rather than from the section around it,
    /// deliberately: deleting the last photo takes this subtree down, and its
    /// `onDisappear` is what clears the pins that were standing for it. Moving
    /// the modifier up to the always-present container would leave a deleted
    /// photo's marker on the map.
    private func gallery(_ photos: [HikePhoto]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.tileSpacing) {
                ForEach(photos) { photo in
                    Button {
                        onOpen(photo)
                    } label: {
                        HikePhotoThumbnail(
                            photo: photo,
                            store: store,
                            size: Self.tileSize,
                            cornerRadius: Self.cornerRadius,
                            label: Self.label(for: photo, among: photos)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hike-photo-\(photo.id.uuidString)")
                }
            }
            // Room for the tiles' shadows and for a finger to start a
            // scroll from the very edge of the row.
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        // On the strip and deliberately not on the `VStack` around it.
        // SwiftUI pushes a container's identifier down onto every
        // descendant, so an identifier here *and* one on the stack leaves
        // the heading, the strip and the footnote all answering to the
        // stack's name — and the strip unreachable under its own. That is
        // what it did until a performance scenario went looking for it.
        .accessibilityIdentifier("hike-photo-strip")
        // Published from here rather than from `HikeDetailView`, because this
        // is already the body that reads `hike.photos` — the whole reason this
        // section is its own view. Attaching it a level up would put a photo
        // capture through the elevation chart, the stats grid and the action
        // bar to reach the map.
        .photoMapPins(mapPins, photos: photos) { photoID in
            guard let photo = hike.photos.first(where: { $0.id == photoID }) else { return }
            onOpen(photo)
        }
    }

    /// The line under the strip and the button.
    ///
    /// Four things to say, and which one is true is the fastest way for
    /// somebody to tell whether the button in front of them is going to be
    /// able to do anything.
    private func caption(for photos: [HikePhoto]) -> String {
        guard hike.canMatchLibraryPhotos else {
            return String(
                localized: """
                    This hike\u{2019}s route doesn\u{2019}t record when each point was \
                    reached, so photos can\u{2019}t be matched to it by time.
                    """
            )
        }
        guard !photos.isEmpty else {
            return String(
                localized: """
                    OpenHikes can look through your photo library for pictures \
                    taken while you walked this hike, and pin each one to the \
                    point of the trail you were on.
                    """
            )
        }
        return footnote(
            count: photos.count,
            anchored: photos.count(where: \.isAnchored)
        )
    }

    /// A tile draws a picture and nothing else, so its position in the walk is
    /// the only thing there is to say about it here.
    ///
    /// The *rest* of what there is to say — that this device has no file for
    /// it — is added by the tile, which is the only thing that knows: the
    /// answer costs a disk read and arrives after this body has run. Composed
    /// there rather than reported back up, because a tile telling its parent
    /// what it found would redraw the whole strip once per tile.
    private static func label(for photo: HikePhoto, among photos: [HikePhoto]) -> String {
        let index = (photos.firstIndex(of: photo) ?? 0) + 1
        let place = photo.isAnchored
            ? String(localized: "pinned to the trail")
            : String(localized: "not pinned to the trail")
        return String(
            localized: "Photo \(index) of \(photos.count), \(place)"
        )
    }

    private func footnote(count: Int, anchored: Int) -> String {
        guard anchored < count else {
            return String(
                localized: "Tap a photo to see it, and where on the trail it was taken."
            )
        }
        guard anchored > 0 else {
            return String(
                localized: "None of these has a place on the trail yet — pick a point on the graph first."
            )
        }
        return String(
            localized: "\(anchored) of \(count) have a place on the trail."
        )
    }
}

/// One square of the strip.
///
/// `.task(id:)` rather than `onAppear`: scrolling the strip reuses tiles, and
/// keying the load on the photo is what stops a recycled tile from showing the
/// previous photo's image until its own decode lands. It is also what cancels
/// a decode for a tile that scrolled away before it finished.
///
/// It draws three things rather than two, because there are three: the
/// picture, a placeholder for a decode that hasn't landed, and a photo this
/// device has no file for — the ordinary state of every photo on a hike that
/// was walked with another phone. That last one used to be the placeholder,
/// permanently, which is a broken tile rather than an answer.
struct HikePhotoThumbnail: View {
    let photo: HikePhoto
    let store: HikePhotoStore
    let size: CGFloat
    let cornerRadius: CGFloat
    /// What the button around this tile is called, before the tile has any
    /// idea whether it can draw the photo. See
    /// ``HikePhotoSection/label(for:among:)``.
    let label: String

    @State private var display = PhotoDisplay.loading

    var body: some View {
        ZStack {
            if case .ready(let loaded) = display {
                Image(photoImage: loaded.image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        // The picture is the content and the button around it has no label of
        // its own, so this is where the whole name is spoken.
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .task(id: photo.id) {
            display = await HikePhotoLoader.thumbnail(for: photo, in: store)
        }
    }

    /// A glyph on a flat fill, never a spinner: a thumbnail that is already on
    /// disk arrives within a frame or two, and a spinner that appears and
    /// vanishes reads as a glitch. Which glyph is the whole message — the
    /// generic one means "in a moment", and the other two mean this tile is
    /// never going to become a picture.
    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: Self.symbol(for: display))
                    .foregroundStyle(.tertiary)
                    // The glyph is the tile's whole content and the tile is
                    // one element with one label, spoken below.
                    .accessibilityHidden(true)
            }
    }

    private static func symbol(for display: PhotoDisplay) -> String {
        switch display {
        case .loading, .ready:
            return "photo"
        case .unavailable(.notOnThisDevice):
            return "icloud.slash"
        case .unavailable(.unreadable):
            return "exclamationmark.triangle"
        }
    }

    private var accessibilityLabel: String {
        switch display {
        case .loading, .ready:
            return label
        case .unavailable(.notOnThisDevice):
            return String(localized: "\(label), not on this device")
        case .unavailable(.unreadable):
            return String(localized: "\(label), unavailable")
        }
    }
}

extension Image {
    /// Bridges the platform image type the store decodes into, so a view never
    /// has to name `UIImage` and the two platforms stay one code path.
    init(photoImage: PhotoImage) {
        #if canImport(UIKit)
        self.init(uiImage: photoImage)
        #elseif canImport(AppKit)
        self.init(nsImage: photoImage)
        #endif
    }
}
