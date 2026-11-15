//
//  HikingRoutesRenderer.swift
//  OpenHikes
//
//  The hiking-routes layer on the map: one overlay the size of the world, and
//  a renderer that draws into each of MapKit's tiles the lines and signs of
//  the squares that tile overlaps, at the level of detail its zoom calls for.
//
//  Drawn here rather than fetched as pictures, so the lines are sharp at
//  every zoom and every scale of screen, and come from squares that are on
//  the phone once they have been seen — see ``HikingRouteSquares``. MapKit
//  keeps what was drawn, so a tile is drawn once for as long as it stays on
//  screen. What a tile looks like is ``HikingRoutesDrawing``'s, to
//  ``HikingRoutesStyle``'s figures.
//
//  **A tile waits for every square it overlaps.** ``canDraw(_:zoomScale:)``
//  answers no until they are all in memory and asks for the missing ones,
//  which redraw the tile when they arrive. Drawing with some of them would
//  stop a line at the edge of a square that has not come yet.
//
//  **A redraw is asked for on the main thread.** The squares arrive on a
//  thread of their own, and `setNeedsDisplay` belongs to the main one, as
//  ``CachingTileOverlayRenderer`` found for its tiles.
//

import CoreLocation
import MapKit

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
        let needed = HikingRoutesDrawing.neededSquares(for: mapRect, zoomScale: zoomScale)
        guard !needed.isEmpty else { return false }
        if squares.holdsAll(needed) { return true }
        // The squares can come in between the two questions. Nothing is
        // kept for a tile that has them all, so it is drawn now rather than
        // left for a redraw nobody would ask for.
        return !request(needed, for: mapRect, zoomScale: zoomScale) && squares.holdsAll(needed)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let needed = HikingRoutesDrawing.neededSquares(for: mapRect, zoomScale: zoomScale)
        guard !needed.isEmpty else { return }
        let drawn = squares.drawable(needed)
        guard !drawn.isEmpty else {
            // A square was let go between `canDraw` saying yes and this.
            // MapKit would keep the empty tile as drawn, so it is asked for
            // again — or simply drawn again, when the square is back already.
            if !request(needed, for: mapRect, zoomScale: zoomScale) {
                redraw(mapRect, zoomScale: zoomScale)
            }
            return
        }
        HikingRoutesDrawing.draw(drawn, in: mapRect, zoomScale: zoomScale, context: context) { self.point(for: $0) }
    }

    /// Asks for `needed`, and draws the tile again when any of it arrives.
    @discardableResult private func request(
        _ needed: [RouteSquare],
        for mapRect: MKMapRect,
        zoomScale: MKZoomScale
    ) -> Bool {
        let tile = HikingRouteSquares.Tile(x: mapRect.minX, y: mapRect.minY, zoomScale: Double(zoomScale))
        return squares.request(needed, for: tile) { [weak self] in
            self?.redraw(mapRect, zoomScale: zoomScale)
        }
    }

    private func redraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) {
        Task { @MainActor [weak self] in self?.setNeedsDisplay(mapRect, zoomScale: zoomScale) }
    }
}
