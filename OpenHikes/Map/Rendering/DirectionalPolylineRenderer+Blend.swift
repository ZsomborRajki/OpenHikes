//
//  DirectionalPolylineRenderer+Blend.swift
//  OpenHikes
//
//  The gradient drawn over each place two coloured stretches meet — see
//  ``RouteShadeBlend`` for where the pieces come from and why they are drawn
//  by hand rather than by MapKit's gradient renderer.
//
//  Split from `DirectionalPolylineRenderer.swift`, which is at its length.
//

import CoreGraphics
import MapKit
import OpenHikesData

nonisolated extension DirectionalPolylineRenderer {
    /// Paints `piece` with its gradient, clipped to the piece stroked as the
    /// line is: its width, its join, and the pattern's own cap and dashes.
    ///
    /// The flat stretches either side are already down beneath. A solid
    /// line's piece covers them exactly and ends in the colour it started
    /// over, so it is drawn straight over them; a dashed line's flat dashes
    /// fall at another phase from the piece's, so the piece's ground is
    /// cleared first or they would show in its gaps.
    ///
    /// The gradient runs straight from the piece's first point to its last.
    /// A piece is a few tens of metres, so a bend inside one shifts where the
    /// mix falls by a little and never colours it outside the two it joins.
    func drawBlend(_ piece: RouteShadeBlend.Piece, zoomScale: MKZoomScale, context: CGContext) {
        guard let start = piece.points.first, let end = piece.points.last else { return }
        let width = lineWidth * contentScaleFactor / zoomScale
        let dashes = pattern.dashLengths(forWidth: Double(lineWidth))
            .map { CGFloat($0) * contentScaleFactor / zoomScale }
        let path = CGMutablePath()
        path.addLines(between: piece.points.map(point(for:)))
        context.saveGState()
        context.setLineWidth(width)
        context.setLineJoin(.round)
        if !dashes.isEmpty {
            context.saveGState()
            context.setBlendMode(.clear)
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.butt)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
        context.setLineCap(pattern.lineCap)
        context.setLineDash(phase: 0, lengths: dashes)
        context.addPath(path)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            piece.gradient,
            start: point(for: start),
            end: point(for: end),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}
