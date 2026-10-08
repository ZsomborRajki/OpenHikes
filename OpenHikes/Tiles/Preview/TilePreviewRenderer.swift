//
//  TilePreviewRenderer.swift
//  OpenHikes
//
//  Draws the map cards in Settings: four of a provider's own tiles, through
//  the same cache the map reads, or a MapKit snapshot of the same ground for
//  the entry that draws Apple's map.
//

import MapKit
import UIKit

/// Live previews rather than pictures shipped in the bundle, so a card shows
/// what the source draws today, where the hiker is, and a new catalog entry
/// needs no artwork to get one.
///
/// Tiles go through ``TileCache`` under the provider's own namespace, which is
/// what keeps this cheap: a card reuses whatever the map already drew there,
/// and what a card fetches is a tile the map will not ask for again. It is
/// still a request for each of a commercial source's four tiles on a first
/// visit somewhere new, made whether or not the hiker subscribes — the price
/// of showing what the subscription buys. Nothing here is offered to
/// auto-save: a card is not a map anybody browsed.
@MainActor
enum TilePreviewRenderer {
    /// Finished cards, so reopening Settings, or scrolling a card away and
    /// back, costs nothing. A handful of cards at a few hundred pixels each;
    /// emptied outright past ``finishedLimit``, which a hiker only reaches by
    /// opening Settings in many places, where the old cards are no use anyway.
    private static var finished: [String: UIImage] = [:]
    private static let finishedLimit = 24

    /// The card for `source` over `frame`, or `nil` when it cannot be drawn —
    /// offline with nothing cached, a refused request, or a source that draws
    /// nothing. A partly loaded block is `nil` too: a card with a hole in it
    /// reads as a broken map, where the placeholder reads as "not loaded".
    ///
    /// - Parameters:
    ///   - style: only the system map has one; raster tiles are the same
    ///     bytes in both appearances, as they are on the map.
    ///   - side: the card's edge in points, for the snapshotter. A tile block
    ///     is composed at its native pixels and scaled down by the view.
    ///   - cache: injectable for tests, like ``TileOverlay``'s.
    static func image(
        for source: TilePreviewSource,
        in frame: TilePreviewFrame,
        style: UIUserInterfaceStyle,
        side: CGFloat,
        cache: TileCache = .shared
    ) async -> UIImage? {
        let key = finishedKey(for: source, in: frame, style: style)
        if let key, let image = finished[key] { return image }

        let image: UIImage? = switch source {
        case .unavailable: nil
        case .systemMap: await snapshot(frame, style: style, side: side)
        case .tiles: await composite(source, in: frame, cache: cache)
        }
        if let key, let image {
            if finished.count >= finishedLimit { finished.removeAll() }
            finished[key] = image
        }
        return image
    }

    private static func finishedKey(
        for source: TilePreviewSource,
        in frame: TilePreviewFrame,
        style: UIUserInterfaceStyle
    ) -> String? {
        let block = "\(frame.z)/\(frame.x)/\(frame.y)"
        return switch source {
        case .unavailable: nil
        case .systemMap: "system/\(style.rawValue)/\(block)"
        case let .tiles(providerID, _): "\(providerID)/\(block)"
        }
    }

    /// Four tiles drawn into one square at their own pixel size.
    static func composite(
        _ source: TilePreviewSource,
        in frame: TilePreviewFrame,
        cache: TileCache
    ) async -> UIImage? {
        let requests = frame.tiles.compactMap { tile -> (TilePreviewFrame.Tile, String, URL)? in
            guard let key = source.cacheKey(for: tile), let url = source.url(for: tile) else { return nil }
            return (tile, key, url)
        }
        guard requests.count == frame.tiles.count else { return nil }

        let loaded = await withTaskGroup(of: (TilePreviewFrame.Tile, TileImage?).self) { group in
            for (tile, key, url) in requests {
                group.addTask { (tile, await cache.loadTile(forKey: key, url: url)) }
            }
            var images: [(TilePreviewFrame.Tile, TileImage)] = []
            for await (tile, image) in group {
                if let image { images.append((tile, image)) }
            }
            return images
        }
        guard loaded.count == requests.count, let first = loaded.first?.1 else { return nil }

        // Every tile is drawn at the first one's size: a provider serves one
        // size, and a block that mixed two would still come out square.
        let tileSide = first.size.width * first.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = tileSide * CGFloat(TilePreviewFrame.tilesPerSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            for (tile, image) in loaded {
                image.draw(in: CGRect(
                    x: CGFloat(tile.column) * tileSide,
                    y: CGFloat(tile.row) * tileSide,
                    width: tileSide,
                    height: tileSide
                ))
            }
        }
    }

    /// Apple's map over the same block, in the appearance the card is shown
    /// in — the map itself follows the system appearance for this entry.
    private static func snapshot(
        _ frame: TilePreviewFrame,
        style: UIUserInterfaceStyle,
        side: CGFloat
    ) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        let world = MKMapSize.world.width
        let rect = frame.unitRect
        options.mapRect = MKMapRect(
            x: rect.originX * world,
            y: rect.originY * world,
            width: rect.side * world,
            height: rect.side * world
        )
        options.size = CGSize(width: side, height: side)
        options.traitCollection = UITraitCollection(userInterfaceStyle: style)
        return try? await MKMapSnapshotter(options: options).start().image
    }
}
