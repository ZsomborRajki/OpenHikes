//
//  VectorTileBuildingNames.swift
//  OpenHikesVectorTiles
//
//  The names of buildings, as OpenStreetMap Carto writes them
//  (`addressing.mss`): small and dark gray, at a point inside the building,
//  from zoom 14 once the building covers 3,000 square pixels and for every
//  building from zoom 17. A castle, a station hall, a barn with a name.
//
//  The basemap names a building only as what is in it, a shop or a church,
//  so the names come from the vector extras' `building_names` layer: a point
//  inside each named building, with the building's size (`area`, as an
//  area's point has it in ``VectorTilePoints``).
//
//  They claim room after the points' names, where Carto's layer comes, and
//  are placed as those are (``VectorTilePoints/Names``). Most named
//  buildings are named for what is in them, and the point for that carries
//  the same name: where one stands by, the building's is left out, as
//  Carto's would mostly find its room taken.
//

import CoreGraphics
import Foundation

enum VectorTileBuildingNames {
    static let layerName = "building_names"

    /// Carto names a building from this zoom, once it covers ``minimumPixels``
    /// square pixels, and every one from ``everyZ``.
    static let minimumZ = 14
    static let everyZ = 17
    static let minimumPixels: Double = 3000

    /// The buildings' names `tile` offers at `target`'s zoom whose points lie
    /// on the picture of it, the larger building first. A point beyond is
    /// the neighbouring tile's to name.
    /// - Parameter points: the tile's points, a building of whose name and
    ///   place is left out.
    static func candidates(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress,
        language: String,
        besides points: [VectorTilePoints.Candidate]
    ) -> [VectorTilePoints.Candidate] {
        guard target.z >= minimumZ, let layer = tile.layers[layerName] else { return [] }
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        let unit = side / VectorTileRasterizer.styleTileSize
        var named: [String: [CGPoint]] = [:]
        for point in points where point.look.text != nil {
            guard let name = point.lines.first else { continue }
            named[name, default: []].append(point.anchor)
        }
        var found: [VectorTilePoints.Candidate] = []
        for feature in layer.features where feature.type == .point {
            guard let name = VectorTileLabels.name(of: feature, language: language) else { continue }
            let pixels = (feature.number(VectorTilePoints.sizeKey) ?? 0) * pow(4, Double(target.z))
            guard target.z >= everyZ || pixels > minimumPixels else { continue }
            for point in geometry.points(of: feature) where bounds.contains(point) {
                let taken = named[name]?.contains { hypot($0.x - point.x, $0.y - point.y) <= reach * unit } ?? false
                guard !taken else { continue }
                found.append(VectorTilePoints.Candidate(
                    anchor: point,
                    lines: [name],
                    look: look,
                    rank: VectorTilePoints.Rank(
                        order: 0,
                        height: -.infinity,
                        pixels: pixels,
                        minimumZoom: .infinity,
                        name: name,
                        x: point.x,
                        y: point.y
                    )
                ))
            }
        }
        return found.sorted { $0.rank < $1.rank }
    }

    /// How a building's name is written: Carto's figures.
    static let look = VectorTilePointStyle.Look(
        lowPriority: false,
        stationOrder: nil,
        showsElevation: false,
        icons: [],
        text: VectorTilePointStyle.Text(
            size: size,
            color: VectorTileStyle.color("#444444"),
            halo: VectorTileStyle.color("#FFFFFF99"),
            haloRadius: 1,
            offset: 0,
            wrapWidth: wrapWidth,
            lineSpacing: lineSpacing,
            face: .regular,
            opacity: 1
        )
    )

    /// How near a point of the same name leaves a building's unwritten, in
    /// the pixels of a 256-pixel tile: about as far as the two names would
    /// stand apart.
    static let reach: CGFloat = 48

    private static let size: CGFloat = 11
    private static let wrapWidth: CGFloat = 22
    private static let lineSpacing: CGFloat = -1.65
}
