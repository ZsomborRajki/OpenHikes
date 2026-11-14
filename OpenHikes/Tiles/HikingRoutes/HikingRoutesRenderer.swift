//
//  HikingRoutesRenderer.swift
//  OpenHikes
//
//  The hiking-routes layer on the map: one overlay the size of the world, and
//  a renderer that strokes into each of MapKit's tiles the lines of the
//  squares that tile overlaps, at the level of detail its zoom calls for.
//
//  Drawn here rather than fetched as pictures, so the lines are sharp at
//  every zoom and every scale of screen, take the app's own colours, and come
//  from squares that are on the phone once they have been seen — see
//  ``HikingRouteSquares``. MapKit keeps what was drawn, so a tile is stroked
//  once for as long as it stays on screen.
//
//  **A tile waits for every square it overlaps.** ``canDraw(_:zoomScale:)``
//  answers no until they are all in memory and asks for the missing ones,
//  which redraw the tile when they arrive. Drawing with some of them would
//  stop a line at the edge of a square that has not come yet.
//
//  The look is the one Waymarked Trails taught hikers to read: red for
//  international routes, blue for national, orange for regional, purple for
//  local, each a little wider than the one below it and none of them cased,
//  so a dense valley stays a map with routes on it. Where routes of two
//  networks share a way the more important one's line is drawn, with dots of
//  the other's colour along it. From zoom 12 each route's sign stands along
//  it every few kilometres — its waymark, or its number — see
//  ``WaymarkSign``.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The one overlay the layer is drawn in, the size of the world.
nonisolated final class HikingRoutesOverlay: NSObject, MKOverlay, Sendable {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    /// Where its squares come from. On the overlay rather than handed to the
    /// map separately, so the renderer MapKit asks for is built with them.
    let squares: HikingRouteSquares

    init(squares: HikingRouteSquares) {
        self.squares = squares
    }
}

/// Draws a ``HikingRoutesOverlay``.
///
/// `@unchecked Sendable` for the reason ``CachingTileOverlayRenderer`` is:
/// MapKit draws on threads of its own, the superclass is not declared
/// `Sendable`, and nothing here is stored but `let`s — the squares' state is
/// behind their own lock.
nonisolated final class HikingRoutesRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let squares: HikingRouteSquares

    init(overlay: HikingRoutesOverlay) {
        squares = overlay.squares
        super.init(overlay: overlay)
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        let needed = neededSquares(for: mapRect, zoomScale: zoomScale)
        guard !needed.isEmpty else { return false }
        if squares.holdsAll(needed) { return true }
        squares.request(needed) { [weak self] in
            self?.setNeedsDisplay(mapRect, zoomScale: zoomScale)
        }
        return false
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let drawn = squares.drawable(neededSquares(for: mapRect, zoomScale: zoomScale))
        guard !drawn.isEmpty, let level = Self.level(for: zoomScale) else { return }
        // Map units in a point on screen, the way every renderer here
        // measures a line.
        let unit = contentScaleFactor / zoomScale
        let reach = Double(Self.widestLine(at: level) * unit)
        let near = mapRect.insetBy(dx: -reach, dy: -reach)
        let step = Double(Self.minimumStep / zoomScale)

        var paths: [RouteNetwork: CGMutablePath] = [:]
        var dotted: [RouteNetwork: [RouteNetwork: CGMutablePath]] = [:]
        for square in drawn {
            for line in square.lines where line.bounds.intersects(near) {
                add(line.points, to: Self.path(for: line.network, in: &paths), skippingCloserThan: step)
                if let secondary = line.secondary {
                    var dots = dotted[line.network] ?? [:]
                    add(line.points, to: Self.path(for: secondary, in: &dots), skippingCloserThan: step)
                    dotted[line.network] = dots
                }
            }
        }
        guard !paths.isEmpty else { return }

        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for network in RouteNetwork.leastImportantFirst {
            let width = Self.lineWidth(of: network, at: level) * unit
            if let path = paths[network] {
                // MapKit can leave a dash on the context, which a solid
                // stroke would otherwise inherit.
                context.setLineDash(phase: 0, lengths: [])
                context.addPath(path)
                context.setLineWidth(width)
                context.setStrokeColor(Self.color(of: network).copy(alpha: Self.alpha(of: network))
                    ?? Self.color(of: network))
                context.strokePath()
            }
            for secondary in RouteNetwork.leastImportantFirst {
                guard let path = dotted[network]?[secondary] else { continue }
                context.setLineDash(phase: 0, lengths: [0, width * Self.dotSpacing])
                context.addPath(path)
                context.setLineWidth(width * Self.dotWidth)
                context.setStrokeColor(Self.color(of: secondary))
                context.strokePath()
            }
        }
        context.restoreGState()
        drawWaymarks(of: drawn, in: mapRect, level: level, unit: unit, context: context)
    }
}

nonisolated private extension HikingRoutesRenderer {
    /// The path lines of `network` are added to, made the first time.
    static func path(for network: RouteNetwork, in paths: inout [RouteNetwork: CGMutablePath]) -> CGMutablePath {
        if let path = paths[network] { return path }
        let made = CGMutablePath()
        paths[network] = made
        return made
    }

    /// The signs whose place is in or beside `mapRect`, each where it does
    /// not cover one already placed — or a sign's width to either side, so
    /// routes that share a way show their signs side by side — or not at all.
    /// A sign the same as one already placed close by is left out: a long
    /// route mapped as a relation for each stage would otherwise put the
    /// same waymark at the start of every stage.
    ///
    /// Every tile weighs the same signs in the same order (see
    /// ``DrawnRouteSquare/waymarks``), so the two tiles a sign straddles
    /// mostly agree about it; where they do not, the prototype shows half a
    /// sign.
    func drawWaymarks(
        of drawn: [DrawnRouteSquare],
        in mapRect: MKMapRect,
        level: RouteSquareLevel,
        unit: CGFloat,
        context: CGContext
    ) {
        guard DrawnRouteSquare.signSpacingMeters(at: level) != nil else { return }
        let margin = Double(Self.signReach * unit)
        let area = mapRect.insetBy(dx: -margin, dy: -margin)
        let marks = drawn.flatMap(\.waymarks)
            .filter { area.contains($0.point) }
            .sorted { lhs, rhs in
                lhs.network != rhs.network ? lhs.network > rhs.network : lhs.routeID < rhs.routeID
            }
        var placed: [MKMapRect] = []
        var shown: [(sign: WaymarkSign, point: MKMapPoint)] = []
        let repeatDistance = Double(Self.signRepeatDistance * unit)
        for mark in marks {
            guard !shown.contains(where: { shown in
                shown.sign == mark.sign
                    && abs(shown.point.x - mark.point.x) < repeatDistance
                    && abs(shown.point.y - mark.point.y) < repeatDistance
            }) else { continue }
            let size = mark.size
            let width = Double(size.width * unit), height = Double(size.height * unit)
            for shift in [0.0, 1, -1] {
                let frame = MKMapRect(
                    x: mark.point.x - width / 2 + shift * width,
                    y: mark.point.y - height / 2,
                    width: width,
                    height: height
                )
                guard !placed.contains(where: { $0.intersects(frame) }) else { continue }
                placed.append(frame)
                shown.append((sign: mark.sign, point: mark.point))
                guard frame.intersects(mapRect) else { break }
                context.saveGState()
                let center = point(for: MKMapPoint(x: frame.midX, y: frame.midY))
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: unit, y: unit)
                mark.sign.draw(in: context)
                context.restoreGState()
                break
            }
        }
    }

    /// `points` as a subpath, leaving out each vertex closer than `step` to
    /// the last one kept — on either axis, which is cheaper than a distance
    /// and as good at telling a pixel's worth — and always keeping the last,
    /// so joined lines still meet. Zoomed out, most of a line's vertices are
    /// inside one pixel, and stroking them is the cost of a tile.
    func add(_ points: [MKMapPoint], to path: CGMutablePath, skippingCloserThan step: Double) {
        guard let first = points.first, let last = points.last else { return }
        path.move(to: point(for: first))
        var kept = first
        for vertex in points.dropFirst().dropLast()
        where abs(vertex.x - kept.x) >= step || abs(vertex.y - kept.y) >= step {
            path.addLine(to: point(for: vertex))
            kept = vertex
        }
        path.addLine(to: point(for: last))
    }
}

// MARK: - Which squares, and how they are drawn

nonisolated extension HikingRoutesRenderer {
    /// A map point's width in screen points at zoom 0 is 2⁻²⁰: the world is
    /// 2²⁸ map points across and 256 screen points at that zoom.
    private static let zoomOfUnitScale: Double = 20
    /// How far apart two vertices have to be, in points, for both to be
    /// stroked.
    private static let minimumStep: CGFloat = 0.5
    /// How far beside a tile a sign that reaches into it can stand, in
    /// points: half the widest sign, and its width again for a sign moved
    /// aside.
    private static let signReach: CGFloat = 36
    /// How close, in points, the same sign is not drawn twice.
    private static let signRepeatDistance: CGFloat = 80
    /// The gap between dots of a second network, in widths of the line.
    private static let dotSpacing: CGFloat = 2.5
    /// A dot's diameter, as a share of the line's width.
    private static let dotWidth: CGFloat = 0.6
    /// How opaque a local or unlabelled route's line is: the most numerous,
    /// so the lightest, leaving the longer routes to stand out.
    private static let minorAlpha: CGFloat = 0.85

    /// A local route's width at each level, in points; the other networks'
    /// are this times their weight.
    private static let overviewLineWidth: CGFloat = 1
    private static let regionLineWidth: CGFloat = 1
    private static let areaLineWidth: CGFloat = 1.25
    private static let detailLineWidth: CGFloat = 1.5
    private static let otherWeight: CGFloat = 0.8
    private static let regionalWeight: CGFloat = 1.25
    private static let nationalWeight: CGFloat = 1.5
    private static let internationalWeight: CGFloat = 1.75

    /// The level a tile at `zoomScale` is drawn from, or `nil` above the
    /// shallowest zoom the layer draws at.
    static func level(for zoomScale: MKZoomScale) -> RouteSquareLevel? {
        let zoom = Int((log2(Double(zoomScale)) + zoomOfUnitScale).rounded())
        return RouteSquareLevel.level(forZoom: zoom)
    }

    /// The squares a tile needs: every square of its level that the tile, and
    /// a line's width or a sign's reach around it, overlaps. None where the
    /// layer draws nothing.
    func neededSquares(for mapRect: MKMapRect, zoomScale: MKZoomScale) -> [RouteSquare] {
        guard let level = Self.level(for: zoomScale) else { return [] }
        let signs = DrawnRouteSquare.signSpacingMeters(at: level) == nil ? 0 : Self.signReach
        let reach = Double(max(Self.widestLine(at: level), signs) * contentScaleFactor / zoomScale)
        let rect = mapRect.insetBy(dx: -reach, dy: -reach).intersection(.world)
        guard !rect.isNull, !rect.isEmpty else { return [] }
        let northWest = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let southEast = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let box = RouteSquareBounds(
            south: southEast.latitude,
            west: northWest.longitude,
            north: northWest.latitude,
            east: southEast.longitude
        )
        return RouteSquareGrid.squares(at: level, covering: box)
    }

    /// A line's width in points: wider for a more important network, and
    /// for a closer zoom.
    static func lineWidth(of network: RouteNetwork, at level: RouteSquareLevel) -> CGFloat {
        let base: CGFloat = switch level {
        case .overview: overviewLineWidth
        case .region: regionLineWidth
        case .area: areaLineWidth
        case .detail: detailLineWidth
        }
        let weight: CGFloat = switch network {
        case .other: otherWeight
        case .local: 1
        case .regional: regionalWeight
        case .national: nationalWeight
        case .international: internationalWeight
        }
        return base * weight
    }

    static func widestLine(at level: RouteSquareLevel) -> CGFloat {
        lineWidth(of: .international, at: level)
    }

    static func alpha(of network: RouteNetwork) -> CGFloat {
        network <= .local ? minorAlpha : 1
    }

    /// Waymarked Trails' colours, read off its own tiles: see this file's
    /// header.
    static func color(of network: RouteNetwork) -> CGColor {
        switch network {
        case .international: internationalColor
        case .national: nationalColor
        case .regional: regionalColor
        case .local: localColor
        case .other: otherColor
        }
    }

    private static let internationalColor = cgColor(Color(hex: "#E0260D") ?? .red)
    private static let nationalColor = cgColor(Color(hex: "#2B43F8") ?? .blue)
    private static let regionalColor = cgColor(Color(hex: "#FCA305") ?? .orange)
    private static let localColor = cgColor(Color(hex: "#7D31C6") ?? .purple)
    private static let otherColor = cgColor(Color(hex: "#8E8E93") ?? .gray)

    private static func cgColor(_ color: Color) -> CGColor {
        #if canImport(UIKit)
        UIColor(color).cgColor
        #else
        NSColor(color).cgColor
        #endif
    }
}
