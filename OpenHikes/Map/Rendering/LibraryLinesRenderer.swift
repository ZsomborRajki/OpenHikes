//
//  LibraryLinesRenderer.swift
//  OpenHikes
//
//  Every line in the library, in one overlay with one renderer.
//
//  The shared hikes' lines are an overlay and a renderer each, which suits a
//  page of twenty-five. A library is not a page: a hiker who has walked for
//  years has hundreds of hikes, and many of them over the same ground — the
//  loop behind the house, walked forty times. Drawn the *Community* tab's way
//  that loop is forty overlays, forty renderers and forty transparency layers
//  in every tile it crosses, and forty faded lines laid on one another are not
//  faded: their strengths add up until the line is solid.
//
//  So the library is one overlay covering the world, ``LibraryLinesOverlay``,
//  and one renderer that draws into each tile the lines that cross it: every
//  outline first, then every line over them, inside one transparency layer
//  laid over the map at ``layerAlpha``. Each line reads as a shared hike's does —
//  its colour, outlined in the default black, both faded together — and forty
//  of them over one trail still read as one, the newest on top.
//
//  The world rather than the lines' extent, so a hike added far away changes
//  what is drawn and not the overlay, which MapKit would otherwise have to
//  drop and draw again. A tile no line crosses costs a pass over the lines'
//  bounding rectangles and nothing else.
//
//  The strokes are MapKit's own polyline renderers, never added to a map and
//  drawn from inside this one's draw, the way ``RouteBorderLine`` draws a
//  border: MapKit thins a line's points to what the zoom can show before it
//  strokes them, and nothing outside it can. Each measures from its own
//  polyline's corner, so the context is moved there first; this overlay's
//  corner is the world's. They are built at the first draw, for the
//  `contentScaleFactor` MapKit gives this renderer once it is on a map — see
//  ``RouteBorderLine`` — and kept for as long as their line is drawn.
//

import MapKit
import OpenHikesData
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The one overlay the library's lines are drawn in. See the file header for
/// why it is the size of the world.
nonisolated final class LibraryLinesOverlay: NSObject, MKOverlay, Sendable {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// Draws the library's lines into a ``LibraryLinesOverlay``.
nonisolated final class LibraryLinesRenderer: MKOverlayRenderer {
    /// One hike's line, as this renderer draws it.
    struct Line {
        /// The line's runs: one polyline for each stretch walked between
        /// pauses.
        let polylines: [MKPolyline]
        /// All of the runs' bounding rectangles in one.
        let boundingMapRect: MKMapRect
        /// The hike's own colour, opaque: the layer fades it.
        let color: CGColor
    }

    /// How strongly the layer is laid over the map. Not `MKOverlayRenderer`'s
    /// own `alpha`, which is left at one: MapKit applies that to every stroke
    /// as it is drawn, so an outline would show through the line over it.
    let layerAlpha: CGFloat
    /// Every line's width, in points, without its outline.
    let lineWidth: CGFloat
    /// The outline's colour, opaque, or `nil` for none.
    let borderColor: CGColor?

    private struct Strokes {
        let border: MKPolylineRenderer?
        let line: MKPolylineRenderer
    }

    private struct State {
        var lines: [Line] = []
        /// Each drawn polyline's strokes, by the polyline, and the scale they
        /// were built for.
        var strokes: [ObjectIdentifier: Strokes] = [:]
        var scale: CGFloat = 0
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(overlay: LibraryLinesOverlay, layerAlpha: CGFloat, lineWidth: CGFloat, borderColor: CGColor?) {
        self.layerAlpha = layerAlpha
        self.lineWidth = lineWidth
        self.borderColor = borderColor
        super.init(overlay: overlay)
    }

    /// The lines to draw from now on, oldest first so the newest is drawn on
    /// top, and a redraw of every tile on screen.
    ///
    /// The strokes of a polyline still drawn are kept, so a publication that
    /// adds one hike builds that hike's and no other.
    func setLines(_ lines: [Line]) {
        state.withLockUnchecked { state in
            let kept = Set(lines.flatMap { $0.polylines.map(ObjectIdentifier.init) })
            state.strokes = state.strokes.filter { kept.contains($0.key) }
            state.lines = lines
        }
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let scale = contentScaleFactor
        // How far a stroke reaches past its line's bounding rectangle, in map
        // points: the whole width of line and outline, which is more than
        // half of it, so a line just outside a tile still draws its edge in.
        let width = Double(lineWidth)
        let reach = (width + RouteBorder.width(forLineWidth: width) * 2) * Double(scale / zoomScale)
        let crossing = state.withLockUnchecked { state in
            state.lines.filter { $0.boundingMapRect.insetBy(dx: -reach, dy: -reach).intersects(mapRect) }
        }
        guard !crossing.isEmpty else { return }
        let drawn = crossing.flatMap { line in
            line.polylines.map { ($0, line.color) }
        }
        let strokes = strokes(for: drawn, scale: scale)
        let covered = crossing.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
            .insetBy(dx: -reach, dy: -reach)
            .intersection(mapRect)
        guard !covered.isNull, !covered.isEmpty else { return }

        context.saveGState()
        // MapKit can leave a dash on the context, which a solid stroke would
        // otherwise inherit.
        context.setLineDash(phase: 0, lengths: [])
        context.setAlpha(layerAlpha)
        context.beginTransparencyLayer(in: rect(for: covered), auxiliaryInfo: nil)
        for (polyline, stroke) in zip(drawn.map(\.0), strokes) {
            guard let border = stroke.border else { continue }
            drawInPlace(of: polyline, context: context) {
                border.draw(mapRect, zoomScale: zoomScale, in: context)
            }
        }
        for (polyline, stroke) in zip(drawn.map(\.0), strokes) {
            drawInPlace(of: polyline, context: context) {
                stroke.line.draw(mapRect, zoomScale: zoomScale, in: context)
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Runs `draw` with the context moved from the world's corner to
    /// `polyline`'s, which is where a renderer of `polyline` measures from.
    private func drawInPlace(of polyline: MKPolyline, context: CGContext, _ draw: () -> Void) {
        let origin = overlay.boundingMapRect.origin
        let own = polyline.boundingMapRect.origin
        context.saveGState()
        context.translateBy(x: own.x - origin.x, y: own.y - origin.y)
        draw()
        context.restoreGState()
    }

    /// The strokes for each of `drawn`, built for a renderer at `scale` the
    /// first time they are asked for.
    private func strokes(for drawn: [(MKPolyline, CGColor)], scale: CGFloat) -> [Strokes] {
        state.withLockUnchecked { state in
            if state.scale != scale {
                state.strokes = [:]
                state.scale = scale
            }
            return drawn.map { polyline, color in
                let key = ObjectIdentifier(polyline)
                if let built = state.strokes[key] { return built }
                let built = makeStrokes(for: polyline, color: color, scale: scale)
                state.strokes[key] = built
                return built
            }
        }
    }

    private func makeStrokes(for polyline: MKPolyline, color: CGColor, scale: CGFloat) -> Strokes {
        let line = MKPolylineRenderer(polyline: polyline)
        line.lineWidth = lineWidth * scale
        line.lineJoin = .round
        line.lineCap = .round
        #if canImport(UIKit)
        line.strokeColor = UIColor(cgColor: color)
        #else
        line.strokeColor = NSColor(cgColor: color)
        #endif
        let border = borderColor.map { color in
            RouteBorderLine.make(
                for: polyline,
                lineWidth: Double(lineWidth),
                dashes: [],
                cap: .round,
                color: color,
                scale: scale
            )
        }
        return Strokes(border: border, line: line)
    }
}
