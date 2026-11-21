//
//  VectorTilePainter+Ground.swift
//  OpenHikesVectorTiles
//
//  The ground and the water of a drawn tile, and what OpenStreetMap Carto
//  draws on them before the roads: each area's fill with the pattern Carto
//  lays straight over it, the lines cut through a forest, the waterways and
//  the lakes with the ones that are not always there drawn broken, the
//  symbols of the woods and wetlands, piers and dams, fences, the red hatch
//  over military land, cliffs and ridges, and, over the roads, the trees.
//

import CoreGraphics

extension VectorTilePainter {
    func paintGround() {
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
        let landuse = features(in: "landuse", type: .polygon).compactMap { feature, geometry -> FilledArea? in
            // A protected area's boundary is no ground: its border is the
            // extras' to draw (``VectorTileAreaDetails/isBoundary(_:)``).
            guard let kind = feature.string("kind"), !details.isBoundary(feature) else { return nil }
            let detail = details.detail(of: feature)
            let color = kind == VectorTileStyle.wetlandKind
                ? VectorTileStyle.wetlandFill(detail: detail)
                : VectorTileStyle.landuseFills[kind]
            let pattern = VectorTilePatterns.ground(kind: kind, detail: detail, z: z)
            guard color != nil || pattern != nil else { return nil }
            return FilledArea(feature: feature, geometry: geometry, color: color, pattern: pattern)
        }
        // The parks are the extras' own: the basemap's kind for one takes in
        // most national parks, whose rock and ice are no park's green.
        let parks = z >= VectorTileStyle.parkZ
            ? features(in: VectorTileRasterizer.parksLayer, type: .polygon).map { feature, geometry in
                FilledArea(feature: feature, geometry: geometry, color: VectorTileStyle.park, pattern: nil)
            }
            : []
        for area in largestFirst(landuse + parks) {
            let path = area.geometry.path(of: area.feature)
            if let color = area.color { fill(path, color) }
            if let pattern = area.pattern { fill(path, with: pattern) }
        }
        paintGlacierEdges()
    }

    /// The edge Carto draws round a glacier, over whatever ground it lies
    /// on.
    private func paintGlacierEdges() {
        guard z >= VectorTileStyle.glacierEdgeZ else { return }
        let isBroken = z >= VectorTileStyle.brokenGlacierEdgeZ
        for (feature, geometry) in features(in: "landuse", type: .polygon)
        where feature.string("kind") == VectorTileStyle.glacierKind {
            strokePixels(
                geometry.path(of: feature),
                VectorTileStyle.glacierEdge,
                width: isBroken ? VectorTileStyle.brokenGlacierEdgeWidth : 1,
                dash: isBroken ? VectorTileStyle.glacierEdgeDash : []
            )
        }
    }

    /// The lines cut through a forest, over the ground and under the water.
    func paintCutlines() {
        for (feature, geometry) in features(in: VectorTileRasterizer.cutlinesLayer, type: .line) {
            stroke(geometry.path(of: feature), VectorTileStyle.cutline, cap: .square)
        }
    }

    /// The waterways and then the lakes, as Carto orders them, each with
    /// the ones that are not always there drawn broken and the ones under
    /// the ground drawn as tunnels. The basemap draws both as any water,
    /// and joins a stream's pieces whether or not each runs all year or
    /// through a culvert, so the vector extras say which stretches are
    /// which (``VectorTileWaterwayStretches``). Along the `culverts` layer's
    /// lines a waterway is drawn as Carto draws a tunnel. The `intermittent`
    /// layer's lines' gaps are rubbed out of the stretches of the waterways
    /// that run along them, and its areas out of the lakes, each in a layer
    /// of its own so that nothing under the water goes with them, nor a
    /// river a seasonal stream crosses.
    func paintWater() {
        let seasonal = features(in: VectorTileRasterizer.intermittentLayer, type: .line)
        let seasonalStretches = stretches(
            along: seasonal,
            piece: VectorTileStyle.intermittentPeriod(z: z),
            band: gapBand(of:)
        )
        let culverts = stretches(
            along: features(in: VectorTileRasterizer.culvertsLayer, type: .line),
            piece: VectorTileStyle.waterTunnelPiece,
            band: tunnelBand(of:)
        )
        var perennial: [(kind: String, path: CGPath)] = []
        var broken: [(kind: String, path: CGPath)] = []
        var tunnels: [(path: CGPath, outer: CGFloat, inner: CGFloat)] = []
        for (feature, geometry) in features(in: "water", type: .line) {
            guard let kind = feature.string("kind") else { continue }
            guard seasonalStretches != nil || culverts != nil else {
                perennial.append((kind, geometry.path(of: feature)))
                continue
            }
            var open = geometry.lines(of: feature)
            if let tunnel = VectorTileStyle.waterTunnel(kind: kind, z: z), let split = culverts?.split(open) {
                tunnels.append((Self.path(split.along), tunnel.outer, tunnel.inner))
                open = split.rest
            }
            guard let split = seasonalStretches?.split(open) else {
                if !open.isEmpty { perennial.append((kind, Self.path(open))) }
                continue
            }
            broken.append((kind, Self.path(split.along)))
            if !split.rest.isEmpty { perennial.append((kind, Self.path(split.rest))) }
        }
        // Every waterway's glow before any waterway, so a stream is not
        // drawn over by the glow of the one it joins.
        strokeWaterways(perennial, glow: true)
        if !broken.isEmpty {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            strokeWaterways(broken, glow: true)
            strokeWaterways(broken, glow: false)
            rubOutGaps(of: seasonal)
            context.endTransparencyLayer()
        }
        strokeWaterways(perennial, glow: false)
        // The tunnels after the open water, as Carto orders them, so the
        // pale line covers where the open stretch beside one ends.
        for tunnel in tunnels {
            strokePixels(tunnel.path, VectorTileStyle.waterTunnelFill, width: tunnel.outer)
            strokePixels(
                tunnel.path,
                VectorTileStyle.water,
                width: tunnel.outer,
                dash: VectorTileStyle.waterTunnelDash
            )
            strokePixels(tunnel.path, VectorTileStyle.waterTunnelFill, width: tunnel.inner)
        }
        paintLakes()
    }

    /// The stretches of the basemap's waterways along `lines`, judged in
    /// pieces of `piece` pixels of a 256-pixel tile, each line's band as
    /// `band` gives it; `nil` where the tile has none of those lines.
    private func stretches(
        along lines: [(MapboxVectorTile.Feature, VectorTileGeometry)],
        piece: CGFloat,
        band: (MapboxVectorTile.Feature) -> CGFloat?
    ) -> VectorTileWaterwayStretches? {
        lines.first.map { _, geometry in
            VectorTileWaterwayStretches(
                lines.compactMap { feature, geometry in
                    band(feature).map { (parts: geometry.lines(of: feature), reach: $0 / 2) }
                },
                frame: geometry.frame,
                piece: piece * unit,
                bounds: bounds
            )
        }
    }

    private static func path(_ parts: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for part in parts {
            path.addLines(between: part)
        }
        return path
    }

    /// Each waterway's glow, or each waterway itself.
    private func strokeWaterways(_ waterways: [(kind: String, path: CGPath)], glow: Bool) {
        for (kind, path) in waterways {
            if glow {
                if let line = VectorTileStyle.waterGlow(kind: kind, z: z) { stroke(path, line) }
            } else if let width = VectorTileStyle.waterLineWidths[kind] {
                stroke(path, VectorTileStyle.Line(color: VectorTileStyle.water, width: width))
            }
        }
    }

    private func paintLakes() {
        let dry = features(in: VectorTileRasterizer.intermittentLayer, type: .polygon)
            .map { feature, geometry in geometry.path(of: feature) }
        if !dry.isEmpty { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        for (feature, geometry) in features(in: "water", type: .polygon) {
            fill(geometry.path(of: feature), VectorTileStyle.water)
        }
        guard !dry.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setFillColor(VectorTileStyle.water)
        context.setStrokeColor(VectorTileStyle.water)
        context.setLineWidth(unit)
        for path in dry {
            // The fill and a thin line round it: the basemap's edge is not
            // to the pixel where the extras' is.
            context.addPath(path)
            context.drawPath(using: .eoFillStroke)
        }
        context.restoreGState()
        context.endTransparencyLayer()
        for path in dry {
            fill(path, with: VectorTilePatterns.intermittentWater)
        }
    }

    /// Rubs the gaps Carto leaves in a waterway that is not always there
    /// out of what has been drawn: along each line a gap after every dash,
    /// a little wider than the waterway, and none at the line's end, where
    /// it would bite into the stream it runs into.
    private func rubOutGaps(of lines: [(MapboxVectorTile.Feature, VectorTileGeometry)]) {
        let (dash, gap) = VectorTileStyle.intermittentDash(z: z)
        let period = VectorTileStyle.intermittentPeriod(z: z) * unit
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setStrokeColor(VectorTileStyle.water)
        context.setLineCap(.butt)
        context.setLineJoin(.round)
        context.setLineDash(phase: gap * unit, lengths: [gap * unit, dash * unit])
        for (feature, geometry) in lines {
            guard let band = gapBand(of: feature) else { continue }
            context.setLineWidth(band)
            for line in geometry.lines(of: feature) {
                let path = MeasuredPath(line)
                // As many whole dashes and gaps as the line holds, and the
                // dash after them.
                let whole = ((path.length - dash * unit) / period).rounded(.down) * period + dash * unit
                let kept = path.prefix(whole)
                guard kept.count > 1 else { continue }
                context.addLines(between: kept)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    /// How wide a band the gaps in a seasonal line are rubbed out over, in
    /// the picture's pixels: a little wider than the waterway, or `nil` for
    /// one not drawn at this zoom.
    private func gapBand(of feature: MapboxVectorTile.Feature) -> CGFloat? {
        guard let width = feature.string("kind").flatMap({ VectorTileStyle.waterLineWidths[$0] })?.value(at: z),
              width > 0
        else { return nil }
        return (width + VectorTileStyle.intermittentMargin) * unit
    }

    /// How wide a band a waterway runs along a culvert within, in the
    /// picture's pixels: a little wider than the tunnel Carto draws, or
    /// `nil` for one it draws none for at this zoom.
    private func tunnelBand(of feature: MapboxVectorTile.Feature) -> CGFloat? {
        guard let tunnel = feature.string("kind").flatMap({ VectorTileStyle.waterTunnel(kind: $0, z: z) })
        else { return nil }
        return (tunnel.outer + VectorTileStyle.intermittentMargin) * unit
    }

    /// What Carto draws after all the ground and the water, over whatever
    /// lies in the area: the tint of mud and tidal flats, then a wetland's
    /// marks, a beach's dots, scrub, a reef, and last the woods' trees by
    /// their leaves. The trees are drawn as one layer, so two woods mapped
    /// over each other show them once.
    func paintAreaSymbols() {
        guard z >= VectorTileStyle.mudZ else { return }
        var trees: [(CGPath, VectorTilePatterns.Pattern)] = []
        let reefs = features(in: "water", type: .polygon).filter { $0.0.string("kind") == VectorTileStyle.reefKind }
        let ground = features(in: "landuse", type: .polygon).filter { !details.isBoundary($0.0) }
        let areas = (ground + reefs).compactMap { feature, geometry in
            feature.string("kind").map { (kind: $0, detail: details.detail(of: feature), feature, geometry) }
        }
        for (kind, detail, feature, geometry) in areas where VectorTileStyle.isMud(kind: kind, detail: detail) {
            fill(geometry.path(of: feature), VectorTileStyle.mud)
        }
        for (kind, detail, feature, geometry) in areas {
            guard let pattern = VectorTilePatterns.symbols(kind: kind, detail: detail, z: z) else { continue }
            let path = geometry.path(of: feature)
            if pattern.opacity < 1 {
                trees.append((path, pattern.solid))
            } else {
                fill(path, with: pattern)
            }
        }
        guard !trees.isEmpty else { return }
        context.saveGState()
        context.setAlpha(VectorTilePatterns.woodOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for (path, pattern) in trees {
            fill(path, with: pattern)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// What stands in the water, as Carto draws it after the water and
    /// before the buildings and roads: breakwaters and groynes, piers, the
    /// dams, weirs and lock gates that hold it back, and the bridges
    /// mapped as areas over it.
    func paintWaterStructures() {
        guard z >= VectorTileStyle.pierZ else { return }
        for (feature, geometry) in features(in: VectorTileRasterizer.breakwatersLayer, type: .polygon) {
            fill(geometry.path(of: feature), VectorTileStyle.breakwater.color)
        }
        for (feature, geometry) in features(in: VectorTileRasterizer.breakwatersLayer, type: .line) {
            stroke(geometry.path(of: feature), VectorTileStyle.breakwater, cap: .butt)
        }
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
        for (feature, geometry) in features(in: "landuse", type: .polygon)
        where feature.string("kind") == VectorTileStyle.bridgeKind {
            fill(geometry.path(of: feature), VectorTileStyle.bridgeArea)
        }
    }

    /// Fences, walls and hedges, from the vector extras: over the ground and
    /// under the buildings and roads, where Carto draws them.
    func paintBarriers() {
        for (feature, geometry) in features(in: "barriers", type: .line) {
            strokeWithCenter(
                geometry.path(of: feature),
                VectorTileStyle.barrier(kind: feature.string("kind")),
                cap: .butt
            )
        }
    }

    /// Military land and danger areas, over the ground and the buildings on
    /// it: a red tint, a red hatch, and a line just inside the edge, which
    /// is the edge stroked twice as wide and cut to the area's inside.
    func paintRestrictedAreas() {
        for (feature, geometry) in features(in: "landuse", type: .polygon) {
            guard let kind = feature.string("kind"),
                  let look = VectorTileStyle.restricted(kind: kind, z: z)
            else { continue }
            let path = geometry.path(of: feature)
            fill(path, look.tint)
            fill(path, with: VectorTilePatterns.hatch(kind: kind))
            context.saveGState()
            context.addPath(path)
            context.clip(using: .evenOdd)
            let width = ZoomCurve([(z, 2 * look.line.width.value(at: z))])
            stroke(path, VectorTileStyle.Line(color: look.line.color, width: width, alpha: look.line.alpha))
            context.restoreGState()
        }
    }

    /// Cliffs and embankments with their teeth, and ridges and arêtes in
    /// Carto's dots, under the roads. The teeth go down the side that falls
    /// away, which only the vector extras' lines can say: the basemap's
    /// cliffs are drawn, as plain lines, on a tile the extras gave none for.
    func paintCliffs() {
        let cliffs = features(in: VectorTileRasterizer.cliffsLayer, type: .line)
        for (feature, geometry) in cliffs {
            guard let teeth = VectorTilePatterns.teeth(kind: feature.string("kind"), z: z) else { continue }
            for line in geometry.lines(of: feature) {
                VectorTilePatterns.draw(teeth, along: line, in: context, unit: unit)
            }
        }
        if cliffs.isEmpty, z >= VectorTilePatterns.cliffZ {
            for (feature, geometry) in features(in: "earth", type: .line) where feature.string("kind") == "cliff" {
                stroke(
                    geometry.path(of: feature),
                    VectorTileStyle.Line(color: VectorTileStyle.cliff, width: VectorTileStyle.cliffWidth)
                )
            }
        }
        guard z >= VectorTileStyle.ridgeZ else { return }
        for (feature, geometry) in features(in: VectorTileRasterizer.ridgesLayer, type: .line) {
            let kind = feature.string("kind")
            let dots = points.icons.pattern(asset: VectorTilePatterns.ridge(kind: kind, z: z).asset, unit: unit)
            guard let dots else {
                stroke(geometry.path(of: feature), VectorTileStyle.ridge(kind: kind), cap: .butt)
                continue
            }
            for line in geometry.lines(of: feature) {
                VectorTilePatterns.lay(dots, along: line, in: context)
            }
        }
    }

    /// Rows of trees and single trees, over the roads they line, from zoom
    /// 16: the crowns as one layer, so those that touch read as one, and
    /// from zoom 18 each tree's trunk.
    func paintTrees() {
        guard z >= VectorTileStyle.treeZ else { return }
        let rows = features(in: VectorTileRasterizer.treesLayer, type: .line)
        let trees = features(in: VectorTileRasterizer.treesLayer, type: .point)
            .flatMap { feature, geometry in geometry.points(of: feature) }
            .filter { bounds.insetBy(dx: -crown, dy: -crown).contains($0) }
        guard !rows.isEmpty || !trees.isEmpty else { return }
        context.saveGState()
        context.setAlpha(VectorTileStyle.treeOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for (feature, geometry) in rows {
            stroke(
                geometry.path(of: feature),
                VectorTileStyle.Line(color: VectorTileStyle.treeCanopy, width: VectorTileStyle.treeWidth)
            )
        }
        context.setFillColor(VectorTileStyle.treeCanopy)
        for tree in trees {
            context.fillEllipse(in: CGRect(x: tree.x - crown / 2, y: tree.y - crown / 2, width: crown, height: crown))
        }
        context.endTransparencyLayer()
        context.restoreGState()
        let trunk = VectorTileStyle.treeTrunkWidth.value(at: z) * unit
        guard trunk > 0 else { return }
        context.setFillColor(VectorTileStyle.treeTrunk)
        for tree in trees {
            context.fillEllipse(in: CGRect(x: tree.x - trunk / 2, y: tree.y - trunk / 2, width: trunk, height: trunk))
        }
    }

    /// How wide a tree's crown is on the picture.
    private var crown: CGFloat { VectorTileStyle.treeWidth.value(at: z) * unit }

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

/// An area, the color it is filled in and the pattern laid over that:
/// either may be missing, never both.
private struct FilledArea {
    let feature: MapboxVectorTile.Feature
    let geometry: VectorTileGeometry
    let color: CGColor?
    let pattern: VectorTilePatterns.Pattern?
}
