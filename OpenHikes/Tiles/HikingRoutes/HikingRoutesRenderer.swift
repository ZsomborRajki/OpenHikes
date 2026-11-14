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
//  The colours are the ones Waymarked Trails taught hikers to read — red for
//  international routes, blue for national, orange for regional, purple for
//  local — and where routes share a way the most important one's is drawn,
//  last and on top. A thin light casing keeps a line legible over satellite
//  imagery and a busy map alike.
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
        let width = Self.lineWidth(at: level) * contentScaleFactor / zoomScale
        let casing = width + Self.casingWidth * contentScaleFactor / zoomScale
        let near = mapRect.insetBy(dx: -Double(casing), dy: -Double(casing))
        let step = Double(Self.minimumStep / zoomScale)

        var paths: [RouteNetwork: CGMutablePath] = [:]
        for square in drawn {
            for line in square.lines where line.bounds.intersects(near) {
                let path = paths[line.network] ?? {
                    let made = CGMutablePath()
                    paths[line.network] = made
                    return made
                }()
                add(line.points, to: path, skippingCloserThan: step)
            }
        }
        guard !paths.isEmpty else { return }

        context.saveGState()
        // MapKit can leave a dash on the context, which a solid stroke would
        // otherwise inherit.
        context.setLineDash(phase: 0, lengths: [])
        context.setLineJoin(.round)
        context.setLineCap(.round)
        let ordered = RouteNetwork.leastImportantFirst.compactMap { network in
            paths[network].map { (network, $0) }
        }
        for (_, path) in ordered {
            context.addPath(path)
            context.setLineWidth(casing)
            context.setStrokeColor(Self.casingColor)
            context.strokePath()
        }
        for (network, path) in ordered {
            context.addPath(path)
            context.setLineWidth(width)
            context.setStrokeColor(Self.color(of: network))
            context.strokePath()
        }
        context.restoreGState()
    }
}

nonisolated private extension HikingRoutesRenderer {
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
    /// The colour under every line.
    private static let casingColor = CGColor(gray: 1, alpha: casingAlpha)
    private static let casingAlpha: CGFloat = 0.7
    /// How much wider the casing is than its line, in points.
    private static let casingWidth: CGFloat = 1.5
    /// How far apart two vertices have to be, in points, for both to be
    /// stroked.
    private static let minimumStep: CGFloat = 0.5

    private static let overviewLineWidth: CGFloat = 1.5
    private static let regionLineWidth: CGFloat = 2
    private static let areaLineWidth: CGFloat = 2.5
    private static let detailLineWidth: CGFloat = 3.5

    /// The level a tile at `zoomScale` is drawn from, or `nil` above the
    /// shallowest zoom the layer draws at.
    static func level(for zoomScale: MKZoomScale) -> RouteSquareLevel? {
        let zoom = Int((log2(Double(zoomScale)) + zoomOfUnitScale).rounded())
        return RouteSquareLevel.level(forZoom: zoom)
    }

    /// The squares a tile needs: every square of its level that the tile, and
    /// a casing's width around it, overlaps. None where the layer draws
    /// nothing.
    func neededSquares(for mapRect: MKMapRect, zoomScale: MKZoomScale) -> [RouteSquare] {
        guard let level = Self.level(for: zoomScale) else { return [] }
        let reach = Double((Self.lineWidth(at: level) + Self.casingWidth) * contentScaleFactor / zoomScale)
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

    static func lineWidth(at level: RouteSquareLevel) -> CGFloat {
        switch level {
        case .overview: overviewLineWidth
        case .region: regionLineWidth
        case .area: areaLineWidth
        case .detail: detailLineWidth
        }
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
