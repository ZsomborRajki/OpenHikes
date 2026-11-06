//
//  CommunityPhotoTile.swift
//  OpenHikes
//
//  One downloaded photograph in the preview strip.
//
//  Its own small view, and its own small decode, because these pictures are
//  not in ``HikePhotoStore`` and must not be: they belong to somebody else's
//  hike and exist only for as long as the screen previewing it. Routing them
//  through the store to get its thumbnail cache would mean writing files into
//  the hiker's own photo directory for a hike they have not imported — which
//  is exactly the state ``HikePhotoStore/reclaimOrphans(claimedBy:)`` sweeps
//  away at the next launch, so the cache would be both wrong and temporary.
//
//  The decode is bounded and off the main actor, for the same reason every
//  other decode in this app is: a full-size frame on the main thread is a
//  dropped frame per picture, and the strip draws several at once.
//
//  A tile keeps the file its picture came from beside the picture, because
//  both strips that draw one key their tiles by position. On the preview a
//  contributor blocked in the gallery takes their set out of the strip, and
//  a set landing late moves every Commons picture after it along, so the
//  tile at a position is handed another file and keeps its state. It used to
//  keep its picture too: it decoded only while it had none, so it went on
//  drawing the last file's — a blocked contributor's photograph, under the
//  next set's name.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CommunityPhotoTile: View {
    let url: URL
    let size: CGFloat
    /// What a screen reader calls this picture, or `nil` where the tile is
    /// decoration.
    ///
    /// Both are real cases and the difference is what the tile is *inside*. On
    /// the review screen it sits under its own remove button and says nothing
    /// a reviewer has not already heard from the section header, so it is
    /// hidden. In the preview's strip it is the label of a button that opens
    /// the picture, and a button whose entire content is hidden is a button
    /// with no accessibility element at all — not a silent one, an absent one.
    /// So the name lives here rather than on the button around it, which is
    /// the shape ``HikePhotoThumbnail`` already has for the same reason.
    var label: String?

    @State private var picture: Picture?

    /// A decoded picture, and the file it was decoded from.
    struct Picture {
        let url: URL
        let image: Image

        /// The picture, if it is `url`'s, and otherwise `nil`: a tile handed
        /// another file draws the placeholder while the new one decodes,
        /// never the last one's picture.
        func image(of url: URL) -> Image? {
            self.url == url ? image : nil
        }
    }

    var body: some View {
        Group {
            if let image = picture?.image(of: url) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                // Not a spinner: a strip of eight spinners is noise, and the
                // decode is short. A plain placeholder holds the layout so the
                // row does not jump as each one lands.
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 8))
        .task(id: url) { await load() }
        // One element either way, so a decode that lands does not turn one
        // tile into two stops. Which of the two it is comes from ``label``.
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }

    private func load() async {
        await Self.load(url, over: picture, maxPixelSize: Int(size * 3)) { picture = $0 }
    }

    /// `url`'s picture, handed to `show` — unless `current` is already its
    /// picture, which a tile scrolled back into view keeps rather than
    /// decoding again.
    ///
    /// Asked of the file rather than of whether there is a picture at all,
    /// for the reason the top of this file gives: a tile handed another file
    /// decodes that one, and a file that cannot be read leaves it on the
    /// placeholder rather than on the last file's picture.
    static func load(
        _ url: URL,
        over current: Picture?,
        maxPixelSize: Int,
        show: (Picture?) -> Void
    ) async {
        guard current?.url != url else { return }
        await decode(url, maxPixelSize: maxPixelSize) { image in
            show(image.map { Picture(url: url, image: $0) })
        }
    }

    /// The decode behind both SwiftUI readers of these files: this tile, and
    /// the full page ``CommunityPhotoViewer`` opens one at.
    ///
    /// Internal rather than private for the reason ``decodeUIImage(_:maxPixelSize:)``
    /// below is shared with the map: the bound, the orientation transform and
    /// the off-main hop are decisions about *these* files, and a second copy
    /// of them is how one reader ends up handling a rotated photograph
    /// differently from another.
    ///
    /// `@concurrent` rather than a bare `nonisolated async`: the latter runs
    /// on its caller's executor under `SWIFT_APPROACHABLE_CONCURRENCY`, and
    /// the caller is a SwiftUI `.task` on the main actor.
    @concurrent
    static func decode(_ url: URL, maxPixelSize: Int) async -> Image? {
        guard let cgImage = PhotoDownsampling.image(at: url, maxPixelSize: maxPixelSize) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }

    /// The same picture, handed to `show` only while the task that asked
    /// still owns what it draws: the form every `.task(id:)` over these files
    /// reads through.
    ///
    /// SwiftUI cancels the task it replaces and starts the next without
    /// waiting, and a decode cannot be cut short, so the last file's picture
    /// can come back after the new one's has been drawn — and stay, because
    /// the newer task has finished. Asked on the main actor, where SwiftUI
    /// cancels, so nothing can come between the check and the write. See
    /// ``HikePhotoLoader/thumbnail(for:in:show:)``.
    static func decode(_ url: URL, maxPixelSize: Int, show: (Image?) -> Void) async {
        let image = await decode(url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        show(image)
    }

    #if canImport(UIKit)
    /// The same decode, for the one place these files are drawn outside
    /// SwiftUI: the picture in a map pin's callout, which is a `UIImageView`
    /// inside MapKit's own view. See ``CommunityPhotoMapAnnotation``.
    ///
    /// Shared rather than written twice so that a picture which draws in the
    /// strip draws on the map — the bound, the orientation transform and the
    /// off-main hop are decisions about *these* files, and two copies of them
    /// is how one copy ends up handling a rotated photograph differently.
    @concurrent
    static func decodeUIImage(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        guard let cgImage = PhotoDownsampling.image(at: url, maxPixelSize: maxPixelSize) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}
