//
//  CachingTileOverlayRenderer.swift
//  OpenTrails
//
//  Draws OSM tiles from the cache, falling back to cropped lower-zoom tiles
//  while higher-zoom tiles load. This avoids the blank/flickering tiles seen
//  with MKTileOverlayRenderer when zooming hard.
//
//  Adapted from stadiamaps/mapkit-caching-tile-overlay, modernized to use
//  async tile loading and a lock-protected in-flight set.
//

import MapKit
import os

nonisolated final class CachingTileOverlayRenderer: MKOverlayRenderer {
    /// How many zoom levels to walk up looking for a tile to crop for overzoom.
    private let maxFallbackDepth = 8

    /// Keys of tiles currently being fetched, to avoid duplicate requests.
    private let inFlight = OSAllocatedUnfairLock(initialState: Set<String>())

    private var tileOverlay: OSMTileOverlay { overlay as! OSMTileOverlay }

    init(overlay: OSMTileOverlay) {
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let overlay = tileOverlay
        let overlayRect = overlay.boundingMapRect
        let tileMapSize = Double(overlay.tileSize.width) / Double(zoomScale)
        let zoom = zoomLevel(for: zoomScale, tileWidth: overlay.tileSize.width)

        let firstCol = Int(floor((mapRect.minX - overlayRect.origin.x) / tileMapSize))
        let lastCol = Int(floor((mapRect.maxX - overlayRect.origin.x) / tileMapSize))
        let firstRow = Int(floor((mapRect.minY - overlayRect.origin.y) / tileMapSize))
        let lastRow = Int(floor((mapRect.maxY - overlayRect.origin.y) / tileMapSize))

        for x in firstCol...lastCol {
            for y in firstRow...lastRow {
                let tileRect = MKMapRect(
                    x: Double(x) * tileMapSize,
                    y: Double(y) * tileMapSize,
                    width: tileMapSize,
                    height: tileMapSize
                )
                let path = MKTileOverlayPath(x: x, y: y, z: zoom, contentScaleFactor: contentScaleFactor)
                let drawRect = rect(for: tileRect)

                if let image = overlay.cachedImage(at: path) {
                    drawImage(image, in: drawRect, context: context)
                } else {
                    if let fallback = fallbackImage(for: path, in: overlay) {
                        drawImage(fallback, in: drawRect, context: context)
                    }
                    loadTileIfNeeded(for: path, in: tileRect, overlay: overlay)
                }
            }
        }
    }

    // MARK: - Loading

    private func loadTileIfNeeded(for path: MKTileOverlayPath, in tileRect: MKMapRect, overlay: OSMTileOverlay) {
        // Beyond the source's max zoom no real tile exists, so fetch the deepest
        // real ancestor instead — the fallback step will crop it for overzoom.
        let fetchPath = path.z > overlay.maximumZ ? path.ancestor(atZoom: overlay.maximumZ) : path
        let key = fetchPath.cacheKey

        let isNew = inFlight.withLock { $0.insert(key).inserted }
        guard isNew else { return }

        Task { [weak self] in
            await overlay.cacheTile(at: fetchPath)
            self?.inFlight.withLock { _ = $0.remove(key) }
            self?.setNeedsDisplay(tileRect)
        }
    }

    /// Finds the nearest cached lower-zoom tile and crops the relevant quadrant.
    private func fallbackImage(for path: MKTileOverlayPath, in overlay: OSMTileOverlay) -> TileImage? {
        var ancestor = path
        for depth in 1...maxFallbackDepth where ancestor.z > 0 {
            ancestor = ancestor.parent
            if let image = overlay.cachedImage(at: ancestor) {
                return image.cropped(to: cropRect(depth: depth, path: path, imageSize: image.size))
            }
        }
        return nil
    }

    // MARK: - Drawing

    private func drawImage(_ image: TileImage, in rect: CGRect, context: CGContext) {
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        UIGraphicsPopContext()
        #elseif canImport(AppKit)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }

    /// Approximates a tile zoom level from a zoomScale (no public API for this).
    private func zoomLevel(for zoomScale: MKZoomScale, tileWidth: CGFloat) -> Int {
        let tilesAcrossWorld = MKMapSize.world.width / Double(tileWidth)
        return max(0, Int(log2(tilesAcrossWorld) + floor(log2(Double(zoomScale)) + 0.5)))
    }
}

/// The sub-rectangle of a `depth`-levels-up ancestor that corresponds to `path`.
private nonisolated func cropRect(depth: Int, path: MKTileOverlayPath, imageSize: CGSize) -> CGRect {
    let factor = 1 << depth
    let subWidth = imageSize.width / CGFloat(factor)
    let subHeight = imageSize.height / CGFloat(factor)
    return CGRect(
        x: CGFloat(path.x % factor) * subWidth,
        y: CGFloat(path.y % factor) * subHeight,
        width: subWidth,
        height: subHeight
    )
}

nonisolated extension TileImage {
    /// Returns a new image cropped to `rect`, expressed in the image's point space.
    func cropped(to rect: CGRect) -> TileImage? {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
        #elseif canImport(AppKit)
        return NSImage(size: rect.size, flipped: true) { _ in
            self.draw(
                in: NSRect(x: -rect.origin.x, y: -rect.origin.y, width: self.size.width, height: self.size.height),
                from: NSRect(origin: .zero, size: self.size),
                operation: .copy,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
            return true
        }
        #endif
    }
}
