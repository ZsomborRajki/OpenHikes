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
        // The vector extras' own layers.
        "barriers", VectorTileArrows.layerName, parksLayer, protectedAreasLayer, powerLayer, damsLayer, ridgesLayer,
    ]

    /// The vector extras' layers of their own that the rasterizer fills or
    /// strokes: the parks, the protected areas whose borders are drawn, the
    /// power lines, the dams and weirs mapped as lines, and the ridges.
    static let parksLayer = "parks"
    static let protectedAreasLayer = "protected_areas"
    static let powerLayer = "power"
    static let damsLayer = "dams"
    static let ridgesLayer = "ridges"

    /// The properties read, the names in `language` among them.
    static func propertyKeys(language: String) -> Set<String> {
        VectorTileLabels.propertyKeys(language: language).union([
            "kind", "kind_detail", "is_tunnel", "is_bridge", "disputed", "access", "oneway", "addr_housenumber",
            "service", VectorTileShields.refKey, VectorTilePoints.sizeKey,
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
        paintWaterStructures()
        paintBarriers()
        paintBuildings()
        paintRoads()
        paintBoundaries()
        paintPowerLines()
        paintProtectedAreas()
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
        // The parks are the extras' own: the basemap's kind for one takes in
        // most national parks, whose rock and ice are no park's green.
        let landuse = features(in: "landuse", type: .polygon).compactMap { feature, geometry -> FilledArea? in
            guard let color = feature.string("kind").flatMap({ VectorTileStyle.landuseFills[$0] }) else { return nil }
            return FilledArea(feature: feature, geometry: geometry, color: color)
        }
        let parks = z >= VectorTileStyle.parkZ
            ? features(in: VectorTileRasterizer.parksLayer, type: .polygon).map { feature, geometry in
                FilledArea(feature: feature, geometry: geometry, color: VectorTileStyle.park)
            }
            : []
        for area in largestFirst(landuse + parks) {
            fill(area.geometry.path(of: area.feature), area.color)
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
        for (feature, geometry) in features(in: VectorTileRasterizer.ridgesLayer, type: .line) {
            stroke(geometry.path(of: feature), VectorTileStyle.ridge(kind: feature.string("kind")), cap: .butt)
        }
    }

    /// What stands in the water, as Carto draws it after the water and
    /// before the buildings and roads: piers, and the dams, weirs and lock
    /// gates that hold it back.
    private func paintWaterStructures() {
        guard z >= VectorTileStyle.pierZ else { return }
        for (feature, geometry) in features(in: "landuse", type: .polygon) {
            switch feature.string("kind") {
            case VectorTileStyle.pierKind: fill(geometry.path(of: feature), VectorTileStyle.land)
            case "dam" where z >= VectorTileStyle.damZ: fill(geometry.path(of: feature), VectorTileStyle.dam)
            default: break
            }
        }
        for (feature, geometry) in features(in: "roads", type: .line)
        where VectorTileStyle.isPier(kind: feature.string("kind"), detail: feature.string("kind_detail")) {
            stroke(geometry.path(of: feature), VectorTileStyle.pier, cap: .square)
        }
        for (feature, geometry) in features(in: VectorTileRasterizer.damsLayer, type: .line) {
            strokeWithCenter(
                geometry.path(of: feature),
                VectorTileStyle.waterBarrier(kind: feature.string("kind")),
                cap: .butt
            )
        }
    }

    /// Fences, walls and hedges, from the vector extras: over the ground and
    /// under the buildings and roads, where Carto draws them.
    private func paintBarriers() {
        for (feature, geometry) in features(in: "barriers", type: .line) {
            strokeWithCenter(
                geometry.path(of: feature),
                VectorTileStyle.barrier(kind: feature.string("kind")),
                cap: .butt
            )
        }
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
                      access: feature.string("access"),
                      service: feature.string("service")
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
                strokeWithCenter(road.geometry.path(of: road.feature), line)
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

    /// Power lines over the roads they cross, where Carto draws them.
    private func paintPowerLines() {
        for (feature, geometry) in features(in: VectorTileRasterizer.powerLayer, type: .line) {
            stroke(geometry.path(of: feature), VectorTileStyle.powerLine(kind: feature.string("kind")), cap: .butt)
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

    private func fill(_ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath(using: .evenOdd)
    }

    /// - Parameters:
    ///   - cap: how an unbroken line ends.
    ///   - dashCap: how each dash of a broken one ends.
    private func stroke(
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
    private func strokeWithCenter(_ path: CGPath, _ line: VectorTileStyle.Line, cap: CGLineCap = .round) {
        stroke(path, line, cap: cap)
        guard let center = line.center else { return }
        stroke(
            path,
            VectorTileStyle.Line(color: center.color, width: center.width, dash: center.dash, alpha: line.alpha),
            cap: cap,
            dashCap: center.cap
        )
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
    private func largestFirst(_ areas: [FilledArea]) -> [FilledArea] {
        let measured = areas.enumerated().map { index, area in
            (filled: area, area: area.geometry.area(of: area.feature), index: index)
        }
        // Equal areas keep the tile's order, so every tile cut from one
        // archive tile settles a tie the same way, and the extras' area is
        // drawn over the basemap's of the same ground: an orchard over the
        // farmland the basemap files it as.
        return measured
            .sorted { lhs, rhs in lhs.area == rhs.area ? lhs.index < rhs.index : lhs.area > rhs.area }
            .map(\.filled)
    }
}

/// An area and the color it is filled in.
nonisolated private struct FilledArea {
    let feature: MapboxVectorTile.Feature
    let geometry: VectorTileGeometry
    let color: CGColor
}

// MARK: - Names, points and arrows

nonisolated private extension Painter {
    var bounds: CGRect {
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        return CGRect(x: 0, y: 0, width: side, height: side)
    }

    /// Names, the points' icons, the roads' numbers and the one-way arrows
    /// last, over everything they name, each claiming room in the order
    /// OpenStreetMap Carto's layers claim it: places, the stations' icons and
    /// names, the points' icons, the roads' numbers, the names along streets
    /// and paths and then their arrows, the points' names and the
    /// localities', the house numbers, the names along water and ridges, and
    /// last the low-priority icons and names — benches, bins, wayside
    /// crosses.
    func paintLabels() {
        let placeCandidates = VectorTileLabels.candidates(
            in: tile,
            source: source,
            target: target,
            bounds: bounds,
            language: language
        )
        let places = placeNames(placeCandidates.filter { !$0.category.isPlacedAfterPoints }, clearOf: [])
        let candidates = pointCandidates()
        let main = candidates.filter { !$0.look.lowPriority && !$0.look.isStation }
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
        let shields = VectorTileShields.Layout(
            VectorTileShields.lines(in: tile, source: source, target: target),
            target: target,
            unit: unit,
            room: &room,
            fonts: &fonts
        )
        let named = VectorTileLineLabels.lines(in: tile, source: source, target: target, language: language)
        let streets = lineNames(named.filter { !$0.category.isPlacedAfterPoints }, clearOf: room.taken)
        room = VectorTilePoints.Room(bounds: bounds, taken: streets.taken)
        let oneWay = VectorTileArrows.lines(in: tile, source: source, target: target)
        let arrows = VectorTileArrows.Layout(oneWay, unit: unit, room: &room)
        let names = VectorTilePoints.Names(main, unit: unit, room: &room, fonts: &fonts)
        let localities = placeNames(placeCandidates.filter(\.category.isPlacedAfterPoints), clearOf: room.taken)
        for placement in localities.placements { room.take(placement.frame) }
        stations.icons.draw(into: context, icons: points.icons)
        icons.draw(into: context, icons: points.icons)
        arrows.draw(into: context, unit: unit)
        shields.draw(into: context, unit: unit)
        streets.draw(into: context)
        paintLateLabels(
            low: candidates.filter(\.look.lowPriority),
            lines: named.filter(\.category.isPlacedAfterPoints),
            room: &room,
            fonts: &fonts
        )
        places.draw(into: context)
        localities.draw(into: context)
        stations.names.draw(into: context)
        names.draw(into: context)
    }

    /// What claims its room after the points' names, and is drawn under
    /// them: the house numbers, the names along water and ridges, and the
    /// low-priority icons and names.
    func paintLateLabels(
        low: [VectorTilePoints.Candidate],
        lines: [VectorTileLineLabels.NamedLine],
        room: inout VectorTilePoints.Room,
        fonts: inout LabelFonts
    ) {
        let numbers = VectorTilePoints.Names(
            VectorTileHouseNumbers.candidates(in: tile, source: source, target: target),
            unit: unit,
            room: &room,
            fonts: &fonts,
            margin: VectorTileHouseNumbers.margin * unit
        )
        let water = lineNames(lines, clearOf: room.taken)
        room = VectorTilePoints.Room(bounds: bounds, taken: water.taken)
        let lowIcons = VectorTilePoints.Icons(low, unit: unit, room: &room)
        let lowNames = VectorTilePoints.Names(low, unit: unit, room: &room, fonts: &fonts)
        lowIcons.draw(into: context, icons: points.icons)
        water.draw(into: context)
        numbers.draw(into: context)
        lowNames.draw(into: context)
    }

    /// `candidates` set and placed clear of `occupied`: the names of places,
    /// lakes and glaciers, which claim room first, and the localities',
    /// which wait for the points.
    func placeNames(_ candidates: [VectorTileLabels.Candidate], clearOf occupied: [CGRect]) -> VectorTileLabels.Layout {
        VectorTileLabels.Layout(
            candidates,
            z: z,
            unit: unit,
            bounds: bounds,
            language: language,
            occupied: occupied
        )
    }

    func lineNames(
        _ lines: [VectorTileLineLabels.NamedLine],
        clearOf occupied: [CGRect]
    ) -> VectorTileLineLabels.Layout {
        VectorTileLineLabels.Layout(lines, z: z, unit: unit, bounds: bounds, occupied: occupied, language: language)
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
