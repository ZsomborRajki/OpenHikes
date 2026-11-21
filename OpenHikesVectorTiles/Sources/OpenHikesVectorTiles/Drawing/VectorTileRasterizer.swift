//
//  VectorTileRasterizer.swift
//  OpenHikesVectorTiles
//
//  Draws a Mapbox Vector Tile into a picture the raster pipeline can cache
//  and MapKit can show, in the order a map is read: water under land, land
//  under what grows and is built on it, roads over that, borders over all.
//  ``VectorTileStyle`` says what each kind looks like. ``VectorTilePainter``
//  is one drawing: the ground and the water are in
//  `VectorTilePainter+Ground.swift`, and the names, icons and arrows in
//  `VectorTilePainter+Labels.swift`.
//
//  A tile deeper than the archive goes is drawn from the archive tile that
//  contains it, scaled so the part it covers fills the picture. The archive's
//  deepest tile carries every vertex OpenStreetMap has, so the deeper picture
//  is as sharp as a tile of its own would be, with no request of its own.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VectorTileRasterizer {
    /// Pixels on a side of a drawn tile: twice the 256 points MapKit lays a
    /// tile out at, so lines are sharp on a 2× screen and nearly so on a 3×
    /// one. Four times the memory of a 256-pixel tile, which a cache that
    /// keeps the pictures decoded has to charge for, as OpenHikes' does
    /// (`TileCache.decodedByteCost(of:)`).
    static let pixelSize = 512
    /// The tile size the style's widths are given for.
    static let styleTileSize: CGFloat = 256
    /// How much a tunnel is faded under the ground above it.
    static let tunnelAlpha: CGFloat = 0.45

    /// The layers drawn.
    static let layerNames: Set<String> = [
        "earth", "landcover", "landuse", "water", "buildings", "roads", "boundaries", "pois", "places",
        // The vector extras' own layers.
        "barriers", VectorTileArrows.layerName, parksLayer, protectedAreasLayer, powerLayer, damsLayer, ridgesLayer,
        VectorTileAreaDetails.layerName, cliffsLayer, cutlinesLayer, treesLayer, intermittentLayer,
        VectorTileBuildingNames.layerName, breakwatersLayer, pathsLayer, serviceRoadsLayer, constructionLayer,
        powerPointsLayer, culvertsLayer,
    ]

    /// The vector extras' layers of their own that the rasterizer fills or
    /// strokes: the parks, the protected areas whose borders are drawn, the
    /// power lines, the dams and weirs mapped as lines, the breakwaters and
    /// groynes, the ridges, the cliffs and embankments, the lines cut
    /// through a forest, the trees and their rows, and the water that is
    /// not always there.
    static let parksLayer = "parks"
    static let protectedAreasLayer = "protected_areas"
    static let powerLayer = "power"
    static let damsLayer = "dams"
    static let breakwatersLayer = "breakwaters"
    static let ridgesLayer = "ridges"
    static let cliffsLayer = "cliffs"
    static let cutlinesLayer = "cutlines"
    static let treesLayer = "trees"
    static let intermittentLayer = "intermittent"
    /// And the ways the extras give again, with what Carto draws each by:
    /// the paths and tracks, the service roads and the roads being built
    /// (`VectorTilePainter+Roads.swift`), and the towers and poles of the
    /// power lines.
    static let pathsLayer = "paths"
    static let serviceRoadsLayer = "service_roads"
    static let constructionLayer = "construction"
    static let powerPointsLayer = "power_points"
    /// And the stretches of waterways through a tunnel or a culvert, which
    /// the basemap draws as open water (`VectorTilePainter+Ground.swift`).
    static let culvertsLayer = "culverts"

    /// The properties read, the names in `language` among them.
    static func propertyKeys(language: String) -> Set<String> {
        VectorTileLabels.propertyKeys(language: language).union([
            "kind", "kind_detail", "is_tunnel", "is_bridge", "disputed", "access", "oneway", "addr_housenumber",
            "service", "surface", "tracktype", VectorTileShields.refKey, VectorTilePoints.sizeKey,
        ])
    }

    /// An archive tile's bytes, drawn as the tile at `target` and encoded
    /// as a PNG: for a host that has the bytes out of an archive of its own,
    /// as OpenHikes has a downloaded country's. `nil` if `basemap` cannot be
    /// read or a picture could not be made.
    /// - Parameters:
    ///   - basemap: the basemap's tile at `source`, as an archive holds it.
    ///   - extras: the extras' tile at `source`, drawn into the basemap's
    ///     where there is one and it can be read.
    ///   - target: `source` or a tile inside it.
    ///   - language: the language whose names the map prefers.
    ///   - height: a summit's height in meters as the reader reads one.
    public static func png(
        ofArchiveTile basemap: Data,
        extras: Data?,
        from source: VectorTileAddress,
        drawing target: VectorTileAddress,
        language: String,
        height: @escaping (Double) -> String
    ) -> Data? {
        let keys = propertyKeys(language: language)
        guard var tile = try? MapboxVectorTile(data: basemap, layerNames: layerNames, propertyKeys: keys) else {
            return nil
        }
        if let extras, let added = try? MapboxVectorTile(data: extras, layerNames: layerNames, propertyKeys: keys) {
            tile = tile.merging(added)
        }
        return png(of: tile, from: source, drawing: target, language: language, height: height)
    }

    /// `tile`, the archive tile at `source`, drawn as the tile at `target`
    /// and encoded as a PNG, or `nil` if a picture could not be made.
    /// `target` is `source` or a tile inside it.
    /// - Parameters:
    ///   - language: the language whose names the map prefers.
    ///   - height: a summit's height in meters as the reader reads one.
    ///   - points: what the points are drawn with.
    static func png(
        of tile: MapboxVectorTile,
        from source: VectorTileAddress,
        drawing target: VectorTileAddress,
        language: String,
        height: @escaping (Double) -> String,
        points: VectorTilePointSet = .standard
    ) -> Data? {
        let image = image(of: tile, from: source, drawing: target, language: language, height: height, points: points)
        guard let image else { return nil }
        let data = CFDataCreateMutable(nil, 0)
        guard let data,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func image(
        of tile: MapboxVectorTile,
        from source: VectorTileAddress,
        drawing target: VectorTileAddress,
        language: String,
        height: @escaping (Double) -> String,
        points: VectorTilePointSet = .standard
    ) -> CGImage? {
        guard target.z >= source.z,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        // The tile's grid runs down the page, and Core Graphics' up it.
        context.translateBy(x: 0, y: CGFloat(pixelSize))
        context.scaleBy(x: 1, y: -1)
        VectorTilePainter(
            context: context,
            tile: tile,
            details: VectorTileAreaDetails(tile),
            source: source,
            target: target,
            language: language,
            height: height,
            points: points
        )
        .paint()
        return context.makeImage()
    }
}

/// One drawing of one tile.
struct VectorTilePainter {
    let context: CGContext
    let tile: MapboxVectorTile
    /// What the vector extras say of the basemap's areas.
    let details: VectorTileAreaDetails
    let source: VectorTileAddress
    let target: VectorTileAddress
    let language: String
    let height: (Double) -> String
    let points: VectorTilePointSet
    /// Pixels per pixel of a 256-pixel tile, the unit the style's widths are in.
    let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize

    var z: Int { target.z }

    var bounds: CGRect {
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        return CGRect(x: 0, y: 0, width: side, height: side)
    }

    /// Everything, in the order OpenStreetMap Carto's layers draw it.
    func paint() {
        context.setFillColor(VectorTileStyle.ocean)
        context.fill(bounds)
        paintGround()
        paintCutlines()
        paintWater()
        paintAreaSymbols()
        paintWaterStructures()
        paintBarriers()
        paintBuildings()
        paintRestrictedAreas()
        paintCliffs()
        paintRoads()
        paintBoundaries()
        paintPowerLines()
        paintProtectedAreas()
        paintTrees()
        paintLabels()
    }

    private func paintBuildings() {
        guard z >= VectorTileStyle.buildingZ else { return }
        let outlined = z >= VectorTileStyle.outlinedBuildingZ
        for (feature, geometry) in features(in: "buildings", type: .polygon)
        where feature.string("kind") != VectorTileStyle.buildingPartKind {
            let path = geometry.path(of: feature)
            fill(path, VectorTileStyle.building)
            if outlined {
                context.addPath(path)
                context.setStrokeColor(VectorTileStyle.buildingOutline)
                context.setLineWidth(0.5 * unit)
                context.strokePath()
            }
        }
    }

    private func paintBoundaries() {
        for (feature, geometry) in features(in: "boundaries", type: .line) {
            guard let kind = feature.string("kind"),
                  let line = VectorTileStyle.boundary(kind: kind, disputed: feature.flag("disputed"))
            else { continue }
            strokeWithCenter(geometry.path(of: feature), line, cap: .butt)
        }
    }

    /// Power lines over the roads they cross, where Carto draws them, and
    /// then the towers and poles they hang from: a gray square each, a
    /// tower's with Carto's white eye.
    private func paintPowerLines() {
        for (feature, geometry) in features(in: VectorTileRasterizer.powerLayer, type: .line) {
            stroke(geometry.path(of: feature), VectorTileStyle.powerLine(kind: feature.string("kind")), cap: .butt)
        }
        for (feature, geometry) in features(in: VectorTileRasterizer.powerPointsLayer, type: .point) {
            guard let mark = VectorTileStyle.powerPoint(kind: feature.string("kind"), z: z) else { continue }
            for point in geometry.points(of: feature) {
                let side = mark.side * unit
                context.setFillColor(mark.color)
                context.fill(CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
                guard mark.eye > 0 else { continue }
                let eye = mark.eye * unit
                context.setFillColor(VectorTileStyle.powerPointEye)
                context.fillEllipse(in: CGRect(x: point.x - eye / 2, y: point.y - eye / 2, width: eye, height: eye))
                guard mark.hasCross else { continue }
                context.setStrokeColor(mark.color)
                context.setLineWidth(side / VectorTileStyle.powerPointCrossShare)
                for corner in [side / 2, -side / 2] {
                    context.move(to: CGPoint(x: point.x - side / 2, y: point.y - corner))
                    context.addLine(to: CGPoint(x: point.x + side / 2, y: point.y + corner))
                }
                context.strokePath()
            }
        }
    }

    /// The borders of national parks, nature reserves and protected areas,
    /// from the vector extras: a line along each and, from zoom 10, Carto's
    /// pale band just inside it. The band is the border stroked twice as
    /// wide and cut to the area's inside. An area that runs past the tile is
    /// cut beyond its edge, further out than the band is wide.
    private func paintProtectedAreas() {
        guard z >= VectorTileStyle.protectedAreaZ else { return }
        for (feature, geometry) in features(in: VectorTileRasterizer.protectedAreasLayer, type: .polygon) {
            let border = VectorTileStyle.protectedBorder(kind: feature.string("kind"))
            let path = geometry.path(of: feature)
            let alpha = border.alpha.value(at: z)
            let band = border.band.value(at: z)
            if band > 0 {
                context.saveGState()
                context.addPath(path)
                context.clip(using: .evenOdd)
                stroke(path, VectorTileStyle.Line(color: border.color, width: ZoomCurve([(z, 2 * band)]), alpha: alpha))
                context.restoreGState()
            }
            stroke(path, VectorTileStyle.Line(color: border.color, width: border.line, alpha: alpha))
        }
    }

    // MARK: Drawing

    func fill(_ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath(using: .evenOdd)
    }

    /// `pattern` over the inside of `path`, laid from the corner of the
    /// world so that the tile beside this one carries it on
    /// (``VectorTilePatterns/lay(_:in:target:)``). Nothing where the picture
    /// is not to be had.
    func fill(_ path: CGPath, with pattern: VectorTilePatterns.Pattern) {
        guard let image = points.icons.pattern(asset: pattern.asset, unit: unit) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setAlpha(pattern.opacity)
        VectorTilePatterns.lay(image, in: context, target: target)
        context.restoreGState()
    }

    /// - Parameters:
    ///   - cap: how an unbroken line ends.
    ///   - dashCap: how each dash of a broken one ends.
    func stroke(
        _ path: CGPath,
        _ line: VectorTileStyle.Line,
        cap: CGLineCap = .round,
        dashCap: CGLineCap = .butt
    ) {
        let width = line.width.value(at: z)
        guard width > 0 else { return }
        context.saveGState()
        context.setAlpha(line.alpha)
        context.addPath(path)
        context.setStrokeColor(line.color)
        context.setLineWidth(width * unit)
        context.setLineJoin(.round)
        if line.dash.isEmpty {
            context.setLineCap(cap)
        } else {
            context.setLineCap(dashCap)
            context.setLineDash(phase: 0, lengths: line.dash.map { $0 * width * unit })
        }
        context.strokePath()
        context.restoreGState()
    }

    /// A line, and then what it carries down its middle: a railway's white
    /// dashes, a lift's cabins, a city wall's dark line.
    func strokeWithCenter(_ path: CGPath, _ line: VectorTileStyle.Line, cap: CGLineCap = .round) {
        stroke(path, line, cap: cap)
        guard let center = line.center else { return }
        stroke(
            path,
            VectorTileStyle.Line(color: center.color, width: center.width, dash: center.dash, alpha: line.alpha),
            cap: cap,
            dashCap: center.cap
        )
    }

    // MARK: Reading

    func features(
        in layerName: String,
        type: MapboxVectorTile.GeometryType
    ) -> [(MapboxVectorTile.Feature, VectorTileGeometry)] {
        guard let layer = tile.layers[layerName] else { return [] }
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        return layer.features.filter { $0.type == type }.map { ($0, geometry) }
    }
}
