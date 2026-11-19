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

    /// The layers drawn.
    static let layerNames: Set<String> = [
        "earth", "landcover", "landuse", "water", "buildings", "roads", "boundaries", "pois", "places",
        // The vector extras' own layer.
        "barriers",
    ]

    /// The properties read, the names in `language` among them.
    static func propertyKeys(language: String) -> Set<String> {
        VectorTileLabels.propertyKeys(language: language).union([
            "kind", "kind_detail", "is_tunnel", "is_bridge", "disputed", "access", "oneway", "addr_housenumber",
        ])
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
        Painter(
            context: context,
            tile: tile,
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
nonisolated private struct Painter {
    let context: CGContext
    let tile: MapboxVectorTile
    let source: VectorTileAddress
    let target: VectorTileAddress
    let language: String
    let height: (Double) -> String
    let points: VectorTilePointSet
    /// Pixels per pixel of a 256-pixel tile, the unit the style's widths are in.
    let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize

    var z: Int { target.z }

    func paint() {
        let side = VectorTileRasterizer.pixelSize
        context.setFillColor(VectorTileStyle.ocean)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        paintGround()
        paintWater()
        paintPiers()
        paintBarriers()
        paintBuildings()
        paintRoads()
        paintBoundaries()
        paintLabels()
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
        let landuse = largestFirst(features(in: "landuse", type: .polygon))
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

    /// Piers over the water they stand in, as Carto draws them after the
    /// water and before the buildings and roads.
    private func paintPiers() {
        guard z >= VectorTileStyle.pierZ else { return }
        for (feature, geometry) in features(in: "landuse", type: .polygon)
        where feature.string("kind") == VectorTileStyle.pierKind {
            fill(geometry.path(of: feature), VectorTileStyle.land)
        }
        for (feature, geometry) in features(in: "roads", type: .line)
        where VectorTileStyle.isPier(kind: feature.string("kind"), detail: feature.string("kind_detail")) {
            stroke(geometry.path(of: feature), VectorTileStyle.pier, cap: .square)
        }
    }

    /// Fences, walls and hedges, from the vector extras: over the ground and
    /// under the buildings and roads, where Carto draws them.
    private func paintBarriers() {
        for (feature, geometry) in features(in: "barriers", type: .line) {
            let line = VectorTileStyle.barrier(kind: feature.string("kind"))
            let path = geometry.path(of: feature)
            stroke(path, line, cap: .butt)
            if let center = line.center {
                stroke(path, VectorTileStyle.Line(color: center.color, width: center.width), cap: .butt)
            }
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
    /// important road over the less, in ``VectorTileStyle/road(kind:detail:access:)``'s
    /// order. Every casing of a level is drawn before any fill of it, so a
    /// junction reads as one road surface rather than two outlined strips.
    private func paintRoads() {
        let styled = features(in: "roads", type: .line).compactMap { pair -> StyledLine? in
            let (feature, geometry) = pair
            guard let kind = feature.string("kind"),
                  let road = VectorTileStyle.road(
                      kind: kind,
                      detail: feature.string("kind_detail"),
                      access: feature.string("access")
                  )
            else { return nil }
            return StyledLine(feature: feature, geometry: geometry, road: road)
        }
        let levels = [
            styled.filter { $0.feature.flag("is_tunnel") },
            styled.filter { !$0.feature.flag("is_tunnel") && !$0.feature.flag("is_bridge") },
            styled.filter { $0.feature.flag("is_bridge") },
        ]
        for (index, level) in levels.enumerated() {
            let ordered = level.sorted { $0.road.order < $1.road.order }
            let isTunnel = index == 0
            // A bridge's casing ends square where the bridge does, rather than
            // ringing a short bridge with a round cap.
            let casingCap: CGLineCap = index == levels.count - 1 ? .butt : .round
            for road in ordered where !isTunnel {
                strokeCasing(road.geometry.path(of: road.feature), road.road.line, cap: casingCap)
            }
            for road in ordered {
                var line = road.road.line
                if isTunnel { line.alpha *= VectorTileRasterizer.tunnelAlpha }
                let path = road.geometry.path(of: road.feature)
                stroke(path, line)
                if let center = line.center {
                    stroke(path, VectorTileStyle.Line(
                        color: center.color,
                        width: center.width,
                        dash: center.dash,
                        alpha: line.alpha
                    ))
                }
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

    /// No casing for a road not drawn at this zoom: the casing starts at
    /// zoom 12, a service road or a pedestrian street at 13, and a casing
    /// with no road inside it would draw as a gray line of its own.
    private func strokeCasing(_ path: CGPath, _ line: VectorTileStyle.Line, cap: CGLineCap) {
        let edge = VectorTileStyle.casingWidth.value(at: z)
        let fill = line.width.value(at: z)
        guard let casing = line.casing, edge > 0, fill > 0 else { return }
        let width = ZoomCurve([(z, fill + 2 * edge)])
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

    /// The largest area first, so a smaller one lying in it is drawn over it:
    /// a park over the residential area around it, a playground over the
    /// park. OpenStreetMap Carto orders its areas by size; the archive cannot,
    /// because it gives every area the same `sort_rank`. An area is measured
    /// as the archive tile holds it, cut at its edge, which keeps the order
    /// of one area lying inside another.
    private func largestFirst(
        _ features: [(MapboxVectorTile.Feature, VectorTileGeometry)]
    ) -> [(MapboxVectorTile.Feature, VectorTileGeometry)] {
        let measured = features.enumerated().map { index, pair in
            (pair: pair, area: pair.1.area(of: pair.0), index: index)
        }
        // Equal areas keep the tile's order, so every tile cut from one
        // archive tile settles a tie the same way.
        return measured
            .sorted { lhs, rhs in lhs.area == rhs.area ? lhs.index < rhs.index : lhs.area > rhs.area }
            .map(\.pair)
    }
}

// MARK: - Names, points and arrows

nonisolated private extension Painter {
    var bounds: CGRect {
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        return CGRect(x: 0, y: 0, width: side, height: side)
    }

    /// Names, the points' icons and the one-way arrows last, over everything
    /// they name, each claiming room in the order OpenStreetMap Carto's
    /// layers claim it: places, the stations' icons and names, the points'
    /// icons, the names along streets and paths and then their arrows, the
    /// points' names, the house numbers, the names along water, and last the
    /// low-priority icons and names — benches, bins, wayside crosses.
    func paintLabels() {
        let places = placeNames()
        let candidates = pointCandidates()
        let main = candidates.filter { !$0.look.lowPriority && !$0.look.isStation }
        let low = candidates.filter(\.look.lowPriority)
        // Mapnik keeps no room between a point and a name; the names along
        // lines keep theirs from everything, `occupied` included.
        var room = VectorTilePoints.Room(bounds: bounds, taken: places.placements.map(\.frame))
        var fonts = LabelFonts(language: language)
        let stations = VectorTilePoints.Stations(
            candidates.filter(\.look.isStation),
            unit: unit,
            room: &room,
            fonts: &fonts
        )
        let icons = VectorTilePoints.Icons(main, unit: unit, room: &room)
        let named = VectorTileLineLabels.lines(in: tile, source: source, target: target, language: language)
        let streets = VectorTileLineLabels.Layout(
            named.filter { !$0.category.isWater },
            z: z,
            unit: unit,
            bounds: bounds,
            occupied: room.taken,
            language: language
        )
        room = VectorTilePoints.Room(bounds: bounds, taken: streets.taken)
        let oneWay = VectorTileArrows.lines(in: tile, source: source, target: target)
        let arrows = VectorTileArrows.Layout(oneWay, unit: unit, room: &room)
        let names = VectorTilePoints.Names(main, unit: unit, room: &room, fonts: &fonts)
        let numbers = VectorTilePoints.Names(
            VectorTileHouseNumbers.candidates(in: tile, source: source, target: target),
            unit: unit,
            room: &room,
            fonts: &fonts,
            margin: VectorTileHouseNumbers.margin * unit
        )
        let water = VectorTileLineLabels.Layout(
            named.filter(\.category.isWater),
            z: z,
            unit: unit,
            bounds: bounds,
            occupied: room.taken,
            language: language
        )
        room = VectorTilePoints.Room(bounds: bounds, taken: water.taken)
        let lowIcons = VectorTilePoints.Icons(low, unit: unit, room: &room)
        let lowNames = VectorTilePoints.Names(low, unit: unit, room: &room, fonts: &fonts)
        stations.icons.draw(into: context, icons: points.icons)
        icons.draw(into: context, icons: points.icons)
        lowIcons.draw(into: context, icons: points.icons)
        arrows.draw(into: context, unit: unit)
        streets.draw(into: context)
        water.draw(into: context)
        places.draw(into: context)
        stations.names.draw(into: context)
        names.draw(into: context)
        numbers.draw(into: context)
        lowNames.draw(into: context)
    }

    /// The names of places, lakes and glaciers, which claim room first.
    func placeNames() -> VectorTileLabels.Layout {
        VectorTileLabels.Layout(
            VectorTileLabels.candidates(in: tile, source: source, target: target, bounds: bounds, language: language),
            z: z,
            unit: unit,
            bounds: bounds,
            language: language
        )
    }

    func pointCandidates() -> [VectorTilePoints.Candidate] {
        VectorTilePoints.candidates(
            in: tile,
            source: source,
            target: target,
            language: language,
            height: height,
            style: points.style
        )
    }
}

nonisolated private struct StyledLine {
    let feature: MapboxVectorTile.Feature
    let geometry: VectorTileGeometry
    let road: VectorTileStyle.Road
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

    /// A line feature's parts, each the points of one run between moves. A
    /// line drawn before any move, which the spec forbids and a tile off the
    /// network may still hold, belongs to no part and is left out.
    func lines(of feature: MapboxVectorTile.Feature) -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        walk(feature.geometry) { command, point in
            switch command {
            case .moveTo: lines.append([point])
            case .lineTo: if !lines.isEmpty { lines[lines.count - 1].append(point) }
            case .closePath: break
            }
        }
        return lines
    }

    /// A polygon feature's area in the picture's square pixels: its outer
    /// rings' less its holes', which the spec winds the other way round.
    func area(of feature: MapboxVectorTile.Feature) -> CGFloat {
        var twice: CGFloat = 0
        var ringStart: CGPoint?
        var previous: CGPoint?
        walk(feature.geometry) { command, point in
            switch command {
            case .moveTo:
                ringStart = point
                previous = point
            case .lineTo:
                if let last = previous { twice += last.x * point.y - point.x * last.y }
                previous = point
            case .closePath:
                if let last = previous, let start = ringStart { twice += last.x * start.y - start.x * last.y }
                ringStart = nil
                previous = nil
            }
        }
        return abs(twice) / 2
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
