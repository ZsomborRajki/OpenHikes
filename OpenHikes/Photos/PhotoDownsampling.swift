//
//  PhotoDownsampling.swift
//  OpenHikes
//
//  Reading a photograph file at the size it is going to be drawn.
//
//  Three readers did this for themselves: the hiker's own photo store, the
//  copy it exports for publication, and the tile and page a community photo
//  is drawn in — each with its own `CGImageSourceCreateThumbnailAtIndex` and
//  its own list of options. The options are decisions about files like these
//  rather than about any one screen, and a reader that dropped
//  `WithTransform` would draw a portrait photograph on its side while the
//  other two drew it upright.
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum PhotoDownsampling {
    /// The image in `url`, at most `maxPixelSize` on its longest edge and with
    /// the file's orientation applied, or `nil` for a file ImageIO cannot read.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than decoding and scaling:
    /// it never materialises the full-size bitmap, which for a capture is the
    /// difference between tens of megabytes and one. `FromImageAlways` makes
    /// it decode the image itself rather than hand back whatever thumbnail the
    /// file happens to embed. `WithTransform` is what makes a portrait photo
    /// come back portrait, so nothing above this has to carry an orientation.
    /// `ShouldCacheImmediately` decodes here rather than at first draw.
    ///
    /// Synchronous, and it does the whole decode: what makes it safe to call
    /// is the caller being off the main actor, which is a promise the caller
    /// makes rather than something this can enforce.
    static func image(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
        )
    }
}
