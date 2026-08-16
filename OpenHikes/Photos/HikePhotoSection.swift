//
//  HikePhotoSection.swift
//  OpenHikes
//
//  The gallery strip on a hike's detail screen: a row of small squares, above
//  the surface breakdown and below the numbers.
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

import SwiftUI

struct HikePhotoSection: View {
    let hike: Hike
    var store: HikePhotoStore = .shared
    /// Opens the viewer at a photo.
    var onOpen: (HikePhoto) -> Void

    private static let tileSize: CGFloat = 76
    private static let tileSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        if hike.hasPhotos {
            let photos = hike.orderedPhotos
            VStack(alignment: .leading, spacing: 12) {
                Text("Photos")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

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
                                    cornerRadius: Self.cornerRadius
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.label(for: photo, among: photos))
                            .accessibilityIdentifier("hike-photo-\(photo.id.uuidString)")
                        }
                    }
                    // Room for the tiles' shadows and for a finger to start a
                    // scroll from the very edge of the row.
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("hike-photo-strip")

                Text(footnote(count: photos.count, anchored: photos.count(where: \.isAnchored)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("photos-section")
        }
    }

    /// A tile draws a picture and nothing else, so its position in the walk is
    /// the only thing there is to say about it.
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
struct HikePhotoThumbnail: View {
    let photo: HikePhoto
    let store: HikePhotoStore
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var image: PhotoImage?

    var body: some View {
        ZStack {
            if let image {
                Image(photoImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        // The picture is the content; the button above carries the name.
        .accessibilityHidden(true)
        .task(id: photo.id) {
            image = await HikePhotoLoader.thumbnail(for: photo, in: store)?.image
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
