//
//  VectorTileRasterizer.swift
//  OpenHikes
//
//  Draws a Mapbox Vector Tile into a picture the raster pipeline can cache
//  and MapKit can show, in the order a map is read: water under land, land
//  under what grows and is built on it, roads over that, borders over all.
//  ``VectorTileStyle`` says what each kind looks like.
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

nonisolated enum VectorTileRasterizer {
    /// Pixels on a side of a drawn tile: twice the 256 points MapKit lays a
    /// tile out at, so lines are sharp on a 2× screen and nearly so on a 3×
    /// one. Four times the memory of a 256-pixel tile, which
    /// ``TileCache/decodedByteCost(of:)`` charges.
    static let pixelSize = 512
    /// The tile size the style's widths are given for.
    static let styleTileSize: CGFloat = 256
    /// How much a tunnel is faded under the ground above it.
    static let tunnelAlpha: CGFloat = 0.45
    /// A peak's triangle: its base as a share of its side below the point,
    /// the apex as a share above it.
    static let peakBaseDrop: CGFloat = 0.4

    /// The layers drawn. Places and points of interest other than peaks wait
    /// for labels.
    static let layerNames: Set<String> = [
        "earth", "landcover", "landuse", "water", "buildings", "roads", "boundaries", "pois",
    ]
    /// The properties read.
    static let propertyKeys: Set<String> = [
        "kind", "kind_detail", "sort_rank", "is_tunnel", "is_bridge", "disputed",
    ]

    /// `tile`, the archive tile at `source`, drawn as the tile at `target`
    /// and encoded as a PNG, or `nil` if a picture could not be made.
    /// `target` is `source` or a tile inside it.
    static func png(
        of tile: MapboxVectorTile,
        from source: VectorTileAddress,
        drawing target: VectorTileAddress
    ) -> Data? {
        guard let image = image(of: tile, from: source, drawing: target) else { return nil }
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
        drawing target: VectorTileAddress
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
        Painter(context: context, tile: tile, source: source, target: target).paint()
        return context.makeImage()
    }
}

/// One drawing of one tile.
nonisolated private struct Painter {
    let context: CGContext
    let tile: MapboxVectorTile
    let source: VectorTileAddress
    let target: VectorTileAddress
    /// Pixels per pixel of a 256-pixel tile, the unit the style's widths are in.
    let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize

    var z: Int { target.z }

    func paint() {
        let side = VectorTileRasterizer.pixelSize
        context.setFillColor(VectorTileStyle.ocean)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        paintGround()
        paintWater()
        paintBuildings()
        paintRoads()
        paintBoundaries()
        paintPeaks()
    }

    private func paintGround() {
        for (feature, geometry) in features(in: "earth", type: .polygon) where feature.string("kind") == "earth" {
            fill(geometry.path(of: feature), VectorTileStyle.land)
        }
        if z <= VectorTileStyle.deepestLandcoverZ {
            for (feature, geometry) in features(in: "landcover", type: .polygon) {
                guard let kind = feature.string("kind"),
                      let color = VectorTileStyle.landcoverFills[kind]
                else { continue }
                fill(geometry.path(of: feature), color)
            }
        }
        let landuse = features(in: "landuse", type: .polygon).sorted { rank($0.0) < rank($1.0) }
        for (feature, geometry) in landuse {
            guard let kind = feature.string("kind"), let color = VectorTileStyle.landuseFills[kind] else { continue }
            fill(geometry.path(of: feature), color)
        }
        for (feature, geometry) in landuse {
            guard let kind = feature.string("kind"), VectorTileStyle.protectedAreaKinds.contains(kind) else { continue }
            stroke(
                geometry.path(of: feature),
                VectorTileStyle.Line(color: VectorTileStyle.protectedArea, width: VectorTileStyle.protectedAreaWidth)
            )
        }
    }

    private func paintWater() {
        for (feature, geometry) in features(in: "water", type: .polygon) {
            fill(geometry.path(of: feature), VectorTileStyle.water)
        }
        for (feature, geometry) in features(in: "water", type: .line) {
            guard let width = feature.string("kind").flatMap({ VectorTileStyle.waterLineWidths[$0] }) else { continue }
            stroke(geometry.path(of: feature), VectorTileStyle.Line(color: VectorTileStyle.water, width: width))
        }
        guard z >= VectorTileStyle.cliffZ else { return }
        for (feature, geometry) in features(in: "earth", type: .line) where feature.string("kind") == "cliff" {
            stroke(
                geometry.path(of: feature),
                VectorTileStyle.Line(color: VectorTileStyle.cliff, width: VectorTileStyle.cliffWidth)
            )
        }
    }

    private func paintBuildings() {
        guard z >= VectorTileStyle.buildingZ else { return }
        let outlined = z >= VectorTileStyle.outlinedBuildingZ
        for (feature, geometry) in features(in: "buildings", type: .polygon) {
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

    /// Tunnels under the ground, bridges over it, and within each the more
    /// important road over the less, by the archive's own `sort_rank`. Every
    /// casing of a level is drawn before any fill of it, so a junction reads
    /// as one road surface rather than two outlined strips.
    private func paintRoads() {
        let styled = features(in: "roads", type: .line).compactMap { pair -> StyledLine? in
            let (feature, geometry) = pair
            guard let kind = feature.string("kind"),
                  let line = VectorTileStyle.road(kind: kind, detail: feature.string("kind_detail"))
            else { return nil }
            return StyledLine(feature: feature, geometry: geometry, line: line)
        }
        let levels = [
            styled.filter { $0.feature.flag("is_tunnel") },
            styled.filter { !$0.feature.flag("is_tunnel") && !$0.feature.flag("is_bridge") },
            styled.filter { $0.feature.flag("is_bridge") },
        ]
        for (index, level) in levels.enumerated() {
            let ordered = level.sorted { rank($0.feature) < rank($1.feature) }
            let isTunnel = index == 0
            // A bridge's casing ends square where the bridge does, rather than
            // ringing a short bridge with a round cap.
            let casingCap: CGLineCap = index == levels.count - 1 ? .butt : .round
            for road in ordered where !isTunnel {
                strokeCasing(road.geometry.path(of: road.feature), road.line, cap: casingCap)
            }
            for road in ordered {
                var line = road.line
                if isTunnel { line.alpha *= VectorTileRasterizer.tunnelAlpha }
                stroke(road.geometry.path(of: road.feature), line)
            }
        }
    }

    private func paintBoundaries() {
        for (feature, geometry) in features(in: "boundaries", type: .line) {
            guard let kind = feature.string("kind"),
                  let line = VectorTileStyle.boundary(kind: kind, disputed: feature.flag("disputed"))
            else { continue }
            stroke(geometry.path(of: feature), line)
        }
    }

    /// Summits, the one point a hiker reads a map by before any name.
    private func paintPeaks() {
        guard z >= VectorTileStyle.peakZ else { return }
        let side = VectorTileStyle.peakSize.value(at: z) * unit
        let half = side * 0.5
        let drop = side * VectorTileRasterizer.peakBaseDrop
        context.setFillColor(VectorTileStyle.peak)
        for (feature, geometry) in features(in: "pois", type: .point) {
            guard let kind = feature.string("kind"), kind == "peak" || kind == "volcano" else { continue }
            for point in geometry.points(of: feature) {
                context.move(to: CGPoint(x: point.x, y: point.y - half))
                context.addLine(to: CGPoint(x: point.x + half, y: point.y + drop))
                context.addLine(to: CGPoint(x: point.x - half, y: point.y + drop))
                context.closePath()
            }
        }
        context.fillPath()
    }

    // MARK: Drawing

    private func fill(_ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath(using: .evenOdd)
    }

    private func stroke(_ path: CGPath, _ line: VectorTileStyle.Line, cap: CGLineCap = .round) {
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
            context.setLineCap(.butt)
            context.setLineDash(phase: 0, lengths: line.dash.map { $0 * width * unit })
        }
        context.strokePath()
        context.restoreGState()
    }

    private func strokeCasing(_ path: CGPath, _ line: VectorTileStyle.Line, cap: CGLineCap) {
        let edge = VectorTileStyle.casingWidth.value(at: z)
        guard let casing = line.casing, edge > 0 else { return }
        let width = ZoomCurve([(z, line.width.value(at: z) + 2 * edge)])
        stroke(path, VectorTileStyle.Line(color: casing, width: width), cap: cap)
    }

    // MARK: Reading

    private func features(
        in layerName: String,
        type: MapboxVectorTile.GeometryType
    ) -> [(MapboxVectorTile.Feature, VectorTileGeometry)] {
        guard let layer = tile.layers[layerName] else { return [] }
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        return layer.features.filter { $0.type == type }.map { ($0, geometry) }
    }

    private func rank(_ feature: MapboxVectorTile.Feature) -> Double {
        feature.number("sort_rank") ?? 0
    }
}

nonisolated private struct StyledLine {
    let feature: MapboxVectorTile.Feature
    let geometry: VectorTileGeometry
    let line: VectorTileStyle.Line
}

/// A layer's grid placed on the picture: pixel = grid × scale − offset.
nonisolated struct VectorTileGeometry {
    let scale: CGFloat
    let offset: CGPoint

    /// The grid of `source`, whose side is `extent`, placed so that the part
    /// of it `target` covers fills a ``VectorTileRasterizer/pixelSize`` picture.
    init(extent: Int, source: VectorTileAddress, target: VectorTileAddress) {
        let factor = CGFloat(1 << max(target.z - source.z, 0))
        let size = CGFloat(VectorTileRasterizer.pixelSize)
        scale = size * factor / CGFloat(extent)
        offset = CGPoint(
            x: (CGFloat(target.x) - CGFloat(source.x) * factor) * size,
            y: (CGFloat(target.y) - CGFloat(source.y) * factor) * size
        )
    }

    /// A line or polygon feature's path. Each ring of a polygon is its own
    /// subpath, so an even-odd fill leaves its holes empty.
    func path(of feature: MapboxVectorTile.Feature) -> CGPath {
        let path = CGMutablePath()
        walk(feature.geometry) { command, point in
            switch command {
            case .moveTo: path.move(to: point)
            case .lineTo: path.addLine(to: point)
            case .closePath: path.closeSubpath()
            }
        }
        return path
    }

    /// A point feature's points.
    func points(of feature: MapboxVectorTile.Feature) -> [CGPoint] {
        var points: [CGPoint] = []
        walk(feature.geometry) { command, point in
            if command == .moveTo { points.append(point) }
        }
        return points
    }

    private enum Command: UInt32 {
        case moveTo = 1
        case lineTo = 2
        case closePath = 7
    }

    /// Commands as the spec encodes them: an id and a count in one integer,
    /// then for a move or a line that many zigzag-encoded steps from the
    /// cursor, which carries on across a feature's parts. Stops at the first
    /// command it cannot read, keeping what came before.
    private func walk(_ geometry: [UInt32], _ visit: (Command, CGPoint) -> Void) {
        var index = 0
        var cursorX = 0
        var cursorY = 0
        while index < geometry.count {
            guard let command = Command(rawValue: geometry[index] & 0x7) else { return }
            let count = Int(geometry[index] >> 3)
            index += 1
            if command == .closePath {
                visit(.closePath, .zero)
                continue
            }
            guard geometry.count - index >= count * 2 else { return }
            for _ in 0..<count {
                cursorX += Self.zigZag(geometry[index])
                cursorY += Self.zigZag(geometry[index + 1])
                index += 2
                visit(command, CGPoint(
                    x: CGFloat(cursorX) * scale - offset.x,
                    y: CGFloat(cursorY) * scale - offset.y
                ))
            }
        }
    }

    private static func zigZag(_ value: UInt32) -> Int {
        Int(value >> 1) ^ -Int(value & 1)
    }
}
