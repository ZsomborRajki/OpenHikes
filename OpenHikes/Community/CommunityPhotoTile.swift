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
//  the walker's own photo directory for a hike they have not imported — which
//  is exactly the state ``HikePhotoStore/reclaimOrphans(claimedBy:)`` sweeps
//  away at the next launch, so the cache would be both wrong and temporary.
//
//  The decode is bounded and off the main actor, for the same reason every
//  other decode in this app is: a full-size frame on the main thread is a
//  dropped frame per picture, and the strip draws several at once.
//

import SwiftUI

struct CommunityPhotoTile: View {
    let url: URL
    let size: CGFloat

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
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
        // The tile carries no information a screen reader can use — the
        // photographs are unlabelled and the count is already spoken by the
        // stats above — so it is decoration here rather than content.
        .accessibilityHidden(true)
    }

    private func load() async {
        guard image == nil else { return }
        image = await Self.decode(url, maxPixelSize: Int(size * 3))
    }

    /// `@concurrent` rather than a bare `nonisolated async`: the latter runs
    /// on its caller's executor under `SWIFT_APPROACHABLE_CONCURRENCY`, and
    /// the caller is a SwiftUI `.task` on the main actor.
    @concurrent
    private static func decode(_ url: URL, maxPixelSize: Int) async -> Image? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  ] as CFDictionary
              )
        else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
