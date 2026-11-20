//
//  VectorTileIcons.swift
//  OpenHikes
//
//  The icons a drawn tile's points carry, made into pictures the rasterizer
//  can draw. Each of Carto's icons is vector art in `CartoIcons.xcassets`,
//  set once at the size and in the color a point asks for and kept for every
//  tile after: a tile draws a few dozen icons, a session of panning a few
//  hundred different ones. Tinted the way Mapnik tints an SVG with
//  `marker-fill`, every part of it in the one color, unless the point keeps
//  the icon's own colors.
//
//  The pictures Carto fills an area with (``VectorTilePatterns``) are in the
//  same catalog, and are made the same way, each at its own size. One is a
//  megabyte or four where an icon is a kilobyte, so they are kept apart, in
//  a cache that lets go of the ones not drawn lately once it holds more than
//  a couple of dozen megabytes, or when memory runs short.
//

import CoreGraphics
import Foundation
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// Turns an icon's name into a picture, for ``VectorTileRasterizer``.
nonisolated protocol VectorTileIconDrawing: Sendable {
    /// The icon `asset`, `size` pixels, in `fill` or, where that is `nil`, in
    /// its own colors; `nil` where there is no such icon.
    func image(asset: String, fill: CGColor?, size: CGSize) -> CGImage?

    /// The pattern `asset` in its own colors, `unit` pixels for each of the
    /// 256-pixel tile's it is drawn for; `nil` where there is no such
    /// pattern.
    func pattern(asset: String, unit: CGFloat) -> CGImage?
}

/// The icons the app ships, from its asset catalog.
nonisolated final class CatalogIcons: VectorTileIconDrawing, @unchecked Sendable {
    static let shared = CatalogIcons()

    /// Draws an icon that is not kept yet: the catalog's, or a suite's stand-in.
    private let render: @Sendable (_ asset: String, _ fill: CGColor?, _ size: CGSize) -> CGImage?
    private let made = Mutex<[Key: CGImage]>([:])
    // swiftlint:disable:next legacy_objc_type
    private let patterns: NSCache<NSString, CGImage> = {
        // swiftlint:disable:next legacy_objc_type
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = patternByteLimit
        return cache
    }()

    /// The most the patterns kept may take, in bytes: half a dozen of the
    /// largest, or every one a mountain tile draws.
    static let patternByteLimit = 24 * 1024 * 1024

    /// Held while an icon or a pattern is drawn, so one tile at a time reads
    /// the asset catalog off the main thread.
    ///
    /// CoreUI, which keeps the catalog's SVG renditions, is not safe to read
    /// from two threads at once: tiles drawn side by side released one of its
    /// objects twice, and the app crashed later, when a job's autorelease
    /// pool was drained, with nothing of the app's on the stack. Reproduced on
    /// a Mac and in the iOS simulator by drawing cold tiles with points six at
    /// a time. An icon is drawn once for each size and color and kept, so
    /// the wait is a tile's first few icons.
    private let drawing = Mutex(())

    convenience init() {
        self.init(render: Self.render)
    }

    init(render: @escaping @Sendable (_ asset: String, _ fill: CGColor?, _ size: CGSize) -> CGImage?) {
        self.render = render
    }

    private struct Key: Hashable {
        let asset: String
        /// Empty for the icon's own colors.
        let fill: [CGFloat]
        let width: CGFloat
        let height: CGFloat
    }

    func image(asset: String, fill: CGColor?, size: CGSize) -> CGImage? {
        let key = Key(asset: asset, fill: fill?.components ?? [], width: size.width, height: size.height)
        if let image = made.withLock({ $0[key] }) { return image }
        return drawing.withLock { _ in
            // Drawn by the tile this one waited on.
            if let image = made.withLock({ $0[key] }) { return image }
            // What CoreUI hands back is let go here, under the lock, rather
            // than when the job's pool drains with other tiles drawing.
            let image = autoreleasepool { render(asset, fill, size) }
            guard let image else { return nil }
            made.withLock { $0[key] = image }
            return image
        }
    }

    func pattern(asset: String, unit: CGFloat) -> CGImage? {
        #if canImport(UIKit)
        // swiftlint:disable:next legacy_objc_type
        let key = "\(asset)@\(unit)" as NSString
        if let kept = patterns.object(forKey: key) { return kept }
        // Under the icons' lock: a pattern is read out of the same catalog.
        return drawing.withLock { _ in
            if let kept = patterns.object(forKey: key) { return kept }
            let pattern = autoreleasepool { () -> CGImage? in
                guard let size = UIImage(named: asset, in: .main, with: nil)?.size else { return nil }
                return render(asset, nil, CGSize(width: size.width * unit, height: size.height * unit))
            }
            guard let pattern else { return nil }
            patterns.setObject(pattern, forKey: key, cost: pattern.bytesPerRow * pattern.height)
            return pattern
        }
        #else
        return nil
        #endif
    }

    /// Draws through UIKit into a context of its own, rather than through
    /// `UIGraphicsImageRenderer`, whose default format asks the screen for its
    /// scale, which is not to be asked off the main thread.
    private static func render(asset: String, fill: CGColor?, size: CGSize) -> CGImage? {
        #if canImport(UIKit)
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let icon = UIImage(named: asset, in: .main, with: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // UIKit draws with y running down, Core Graphics' context up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let tinted = fill.map { icon.withTintColor(UIColor(cgColor: $0), renderingMode: .alwaysOriginal) }
        (tinted ?? icon.withRenderingMode(.alwaysOriginal)).draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        return context.makeImage()
        #else
        return nil
        #endif
    }
}
