//
//  TilePreviewFrame.swift
//  OpenHikes
//
//  The patch of ground a map card in Settings is drawn from, and what each
//  catalog entry draws it with. Pure, so both halves are tested without a
//  tile server or a snapshotter; `TilePreviewRenderer` is what spends them.
//

import CoreLocation
import Foundation
import OpenHikesShared

/// A square block of tiles at one zoom: the ground every map card shows, so
/// the cards differ only in how they draw it.
///
/// Snapped to the tile grid rather than centred on the hiker exactly. A card
/// is a sample of a map's style, not a locator, and a block that only moves
/// when the hiker crosses a tile boundary is one the cache already holds the
/// next time Settings opens — which, for the two commercial sources, is the
/// difference between a billed request per visit and one per neighbourhood.
nonisolated struct TilePreviewFrame: Hashable, Sendable {
    /// Trail level: paths, contours and hillshading all draw, and the block
    /// covers a few kilometres — enough ground for the styles to look
    /// different from one another.
    static let defaultZoom = 14
    /// Two by two, so a 256-pixel tile is never stretched across a card, and
    /// at most four requests per source.
    static let tilesPerSide = 2

    /// Where the cards are drawn when the hiker's position is unknown — no
    /// permission yet, or no fix since launch. The Königssee valley, which the
    /// App Store frames and the UI fixtures already walk, and which has a lake,
    /// a forest, a summit and a marked path inside one block.
    static let fallbackCoordinate = CLLocationCoordinate2D(
        latitude: fallbackLatitude,
        longitude: fallbackLongitude
    )
    private static let fallbackLatitude = 47.5536
    private static let fallbackLongitude = 12.9752

    let z: Int
    /// West column, already wrapped into the zoom's range.
    let x: Int
    /// North row, kept inside the zoom's range so the block never runs off
    /// the top or bottom of the projection.
    let y: Int

    /// The block that holds `coordinate`, chosen so `coordinate` lies in its
    /// middle half: the column and row pair on whichever side of the tile it
    /// falls in is the one nearer it.
    init(around coordinate: CLLocationCoordinate2D, z: Int = Self.defaultZoom) {
        let count = 1 << z
        let unitX = Mercator.wrappedUnitX(Mercator.unitX(longitude: coordinate.longitude))
        let unitY = Mercator.unitY(latitude: coordinate.latitude)
        let column = unitX * Double(count)
        let row = unitY * Double(count)
        let westward = column - floor(column) < 0.5
        let northward = row - floor(row) < 0.5
        self.z = z
        x = SlippyTileMath.wrap(Int(floor(column)) - (westward ? 1 : 0), to: count)
        y = min(
            max(Int(floor(row)) - (northward ? 1 : 0), 0),
            count - Self.tilesPerSide
        )
    }

    /// One tile of the block, and where it is drawn in it.
    struct Tile: Hashable, Sendable {
        let z: Int
        let x: Int
        let y: Int
        /// Position in the block, from its north-west corner.
        let column: Int
        let row: Int
    }

    /// Row by row from the north-west corner. Columns wrap at the
    /// antimeridian, so a block straddling it asks for real tiles on both
    /// sides rather than for a column past the edge of the world.
    var tiles: [Tile] {
        let count = 1 << z
        return (0 ..< Self.tilesPerSide).flatMap { row in
            (0 ..< Self.tilesPerSide).map { column in
                Tile(
                    z: z,
                    x: SlippyTileMath.wrap(x + column, to: count),
                    y: y + row,
                    column: column,
                    row: row
                )
            }
        }
    }

    /// The block as a fraction of the world, for a snapshotter that draws by
    /// map rect rather than by tile. Its width may run past 1 at the
    /// antimeridian, which `MKMapRect` reads as a rect spanning it.
    var unitRect: (originX: Double, originY: Double, side: Double) {
        let count = Double(1 << z)
        return (Double(x) / count, Double(y) / count, Double(Self.tilesPerSide) / count)
    }
}

/// What a catalog entry's card is drawn from.
nonisolated enum TilePreviewSource: Equatable, Sendable {
    /// MapKit's own map, snapshotted over the same block.
    case systemMap
    /// The provider's raster tiles, through the tile cache under its own id.
    case tiles(providerID: String, urlTemplate: String)
    /// Nothing can be drawn: a key-gated source whose key did not resolve in
    /// this build. Asking would only collect 401s.
    case unavailable

    /// Takes the key rather than looking it up, as
    /// ``TileProvider/isUsable(withKey:)`` does, so the rule is testable
    /// without a bundle to read it from.
    init(_ provider: TileProvider, apiKey: String?) {
        if provider.usesSystemBaseMap {
            self = .systemMap
        } else if provider.isUsable(withKey: apiKey) {
            self = .tiles(
                providerID: provider.id,
                urlTemplate: provider.resolvedTemplate(apiKey: apiKey ?? "")
            )
        } else {
            self = .unavailable
        }
    }

    /// The URL for one tile of the block, or `nil` when this source draws no
    /// tiles or its template does not form one.
    func url(for tile: TilePreviewFrame.Tile) -> URL? {
        guard case let .tiles(_, template) = self else { return nil }
        let filled = template
            .replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y))
        return URL(string: filled)
    }

    /// The tile's key in ``TileCache``: the same spelling the map's overlay
    /// files it under, so a card reuses what the map already drew and the map
    /// reuses what a card fetched.
    func cacheKey(for tile: TilePreviewFrame.Tile) -> String? {
        guard case let .tiles(providerID, _) = self else { return nil }
        return TileCacheKey.namespaced(providerID: providerID, z: tile.z, x: tile.x, y: tile.y)
    }
}
