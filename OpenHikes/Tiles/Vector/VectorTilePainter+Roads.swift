//
//  VectorTilePainter+Roads.swift
//  OpenHikes
//
//  The roads of a drawn tile and the paths among them, in the order
//  OpenStreetMap Carto draws them: tunnels under the ground, bridges over
//  it, and at each level every casing before any surface, so a junction
//  reads as one road. The paths come first of the surfaces, under every
//  road they meet, each on Carto's pale band where it has one.
//
//  Three kinds of way are drawn from the vector extras where a tile has
//  them, in place of the basemap's own, because the basemap drops what
//  Carto draws each by and joins a road's ways into one line, so nothing
//  can be said of them by their ids: the paths and tracks
//  (``VectorTileRasterizer/pathsLayer``), the service roads
//  (``VectorTileRasterizer/serviceRoadsLayer``), which is what tells a
//  driveway from the road that serves a place, and the roads being built,
//  which the basemap leaves out. A tile whose extras did not arrive draws
//  the basemap's, as far as it describes them.
//

import CoreGraphics

nonisolated extension VectorTilePainter {
    /// Where a way runs: under the ground, on it, or over it.
    private enum Level: CaseIterable {
        case tunnel
        case ground
        case bridge

        init(_ feature: MapboxVectorTile.Feature) {
            self = feature.flag("is_tunnel") ? .tunnel : feature.flag("is_bridge") ? .bridge : .ground
        }
    }

    private struct StyledRoad {
        let outline: CGPath
        let road: VectorTileStyle.Road
        let level: Level
    }

    private struct StyledPath {
        let outline: CGPath
        let look: VectorTileStyle.PathLook
        let level: Level
    }

    func paintRoads() {
        let roads = styledRoads().sorted { $0.road.order < $1.road.order }
        let paths = styledPaths()
        for level in Level.allCases {
            let surfaces = roads.filter { $0.level == level }
            // A bridge's casing ends square where the bridge does, rather than
            // ringing a short bridge with a round cap.
            let casingCap: CGLineCap = level == .bridge ? .butt : .round
            for road in surfaces where level != .tunnel {
                strokeCasing(road.outline, road.road.line(at: z), cap: casingCap)
            }
            paint(paths.filter { $0.level == level }, on: level)
            if level == .ground { paintConstruction() }
            for road in surfaces {
                var line = road.road.line(at: z)
                if level == .tunnel { line.alpha *= VectorTileRasterizer.tunnelAlpha }
                strokeWithCenter(road.outline, line)
            }
        }
    }

    // MARK: Roads

    /// The basemap's roads, with the extras' service roads in place of its
    /// own where the tile has them.
    private func styledRoads() -> [StyledRoad] {
        let service = features(in: VectorTileRasterizer.serviceRoadsLayer, type: .line)
        let basemap = features(in: "roads", type: .line).compactMap { feature, geometry -> StyledRoad? in
            guard let kind = feature.string("kind") else { return nil }
            let detail = feature.string("kind_detail")
            if !service.isEmpty, VectorTileStyle.isServiceRoad(kind: kind, detail: detail) { return nil }
            guard let road = VectorTileStyle.road(kind: kind, detail: detail, service: feature.string("service"))
            else { return nil }
            return StyledRoad(outline: geometry.path(of: feature), road: road, level: Level(feature))
        }
        let own = service.compactMap { feature, geometry in
            VectorTileStyle.serviceRoad(service: feature.string("service")).map { road in
                StyledRoad(outline: geometry.path(of: feature), road: road, level: Level(feature))
            }
        }
        return basemap + own
    }

    /// No casing for a road not drawn at this zoom: the casing starts at
    /// zoom 12, a service road at 14 and a pedestrian street at 13, and a
    /// casing with no road inside it would draw as a gray line of its own.
    private func strokeCasing(_ path: CGPath, _ line: VectorTileStyle.Line, cap: CGLineCap) {
        let edge = VectorTileStyle.casingWidth.value(at: z)
        let fill = line.width.value(at: z)
        guard let casing = line.casing, edge > 0, fill > 0 else { return }
        let width = ZoomCurve([(z, fill + 2 * edge)])
        stroke(path, VectorTileStyle.Line(color: casing, width: width), cap: cap)
    }

    /// Roads being built: the color of the road each is to be, with dashes
    /// down it in the color of its surface.
    private func paintConstruction() {
        for (feature, geometry) in features(in: VectorTileRasterizer.constructionLayer, type: .line) {
            guard let line = VectorTileStyle.construction(
                kind: feature.string("kind"),
                z: z,
                service: feature.string("service")
            )
            else { continue }
            strokeWithCenter(geometry.path(of: feature), line, cap: .butt)
        }
    }

    // MARK: Paths

    /// The tile's paths as they are drawn at this zoom: the extras' where
    /// it has them, and the basemap's where it does not.
    private func styledPaths() -> [StyledPath] {
        let own = features(in: VectorTileRasterizer.pathsLayer, type: .line)
        let basemap = features(in: "roads", type: .line).filter { $0.0.string("kind") == VectorTileStyle.pathKind }
        return (own.isEmpty ? basemap : own).compactMap { feature, geometry in
            let traits = own.isEmpty
                ? VectorTileStyle.pathTraits(detail: feature.string("kind_detail"), access: feature.string("access"))
                : VectorTileStyle.pathTraits(
                    kind: feature.string("kind"),
                    surface: feature.string("surface"),
                    tracktype: feature.string("tracktype"),
                    access: feature.string("access")
                )
            guard let look = traits.flatMap({ VectorTileStyle.path($0, z: z) }) else { return nil }
            return StyledPath(outline: geometry.path(of: feature), look: look, level: Level(feature))
        }
    }

    /// One level's paths: the casings of the bridges and the tunnels, then
    /// the band under each path, then the paths. On the ground the band
    /// lets the ground through and begins at zoom 15; on a bridge and in a
    /// tunnel it is solid, and is what the casing is the edge of.
    private func paint(_ paths: [StyledPath], on level: Level) {
        let isCased = level == .tunnel || (level == .bridge && z >= VectorTileStyle.pathBridgeZ)
        for path in paths where isCased {
            if level == .tunnel {
                strokePixels(
                    path.outline,
                    VectorTileStyle.pathTunnelCasingColor,
                    width: path.look.tunnelCasingWidth,
                    dash: VectorTileStyle.pathTunnelCasingDash
                )
            } else {
                strokePixels(path.outline, VectorTileStyle.pathBridgeCasingColor, width: path.look.bridgeCasingWidth)
            }
        }
        if isCased || z >= VectorTileStyle.pathBandZ {
            for path in paths {
                strokePixels(
                    path.outline,
                    VectorTileStyle.pathBand,
                    width: path.look.bandWidth,
                    cap: level == .bridge ? .butt : .round,
                    alpha: isCased ? 1 : VectorTileStyle.pathBandAlpha
                )
            }
        }
        for path in paths {
            strokePixels(
                path.outline,
                path.look.color,
                width: path.look.width,
                dash: path.look.dash,
                cap: path.look.cap,
                alpha: path.look.alpha
            )
        }
    }

    /// A line of `width` pixels of a 256-pixel tile, its dashes in the same
    /// pixels: Carto's own units for a path, whose dashes do not widen with
    /// it as a ``VectorTileStyle/Line``'s do.
    func strokePixels(
        _ path: CGPath,
        _ color: CGColor,
        width: CGFloat,
        dash: [CGFloat] = [],
        cap: CGLineCap = .butt,
        alpha: CGFloat = 1
    ) {
        guard width > 0 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width * unit)
        context.setLineJoin(.round)
        context.setLineCap(cap)
        if !dash.isEmpty {
            context.setLineDash(phase: 0, lengths: dash.map { $0 * unit })
        }
        context.strokePath()
        context.restoreGState()
    }
}
