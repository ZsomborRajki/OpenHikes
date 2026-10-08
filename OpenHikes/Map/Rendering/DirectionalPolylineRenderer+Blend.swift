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
    /// Paints `piece` with its gradient, clipped to the piece stroked solid
    /// at the line's width.
    ///
    /// The flat stretches either side are already down beneath. A solid
    /// line's piece covers them exactly and ends in the colour it started
    /// over, so it is drawn straight over them.
    ///
    /// A dashed or dotted line's piece is not drawn as dashes of its own.
    /// Its dashes would fall at another phase from the stretches', whose
    /// dashes and outlines are already down there — clearing them first
    /// left the stretches' borders standing round nothing, and slits cut
    /// through the piece's dashes where the borders' ends were cleared.
    /// Instead the gradient recolours the stretches' own dashes where they
    /// lie: `.sourceAtop`, clipped to the piece drawn solid, paints only
    /// where a dash already is, at that dash's alpha. It is drawn in the
    /// layer ``drawShades`` keeps the colours in, where the dashes are all
    /// there is to recolour; a dash reaching past the piece's end keeps the
    /// colour the gradient ends in there, which is its own.
    ///
    /// That recolouring paints the piece's gradient at full alpha. A
    /// translucent route's stretches carry its alpha, and `.sourceAtop`
    /// keeps as much of the dash under it as the source lets through — so
    /// the gradient at the stretches' own alpha came out mixed half and
    /// half with the flat colour beneath, and the change of colour half as
    /// gradual as on an opaque line.
    ///
    /// The gradient runs straight from the piece's first point to its last.
    /// A piece is a few tens of metres, so a bend inside one shifts where the
    /// mix falls by a little and never colours it outside the two it joins.
    func drawBlend(_ piece: RouteShadeBlend.Piece, zoomScale: MKZoomScale, context: CGContext) {
        guard let start = piece.points.first, let end = piece.points.last else { return }
        let width = lineWidth * contentScaleFactor / zoomScale
        let path = CGMutablePath()
        path.addLines(between: piece.points.map(point(for:)))
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: [])
        let gapped = !pattern.dashLengths(forWidth: Double(lineWidth)).isEmpty
        if !gapped {
            context.setLineWidth(width)
            context.setLineCap(pattern.lineCap)
        } else {
            // A little wider than the line, so the dashes' anti-aliased
            // edges are recoloured with them — see ``holeOverreach``.
            context.setLineWidth(width + Self.holeOverreach / zoomScale)
            context.setLineCap(.butt)
            context.setBlendMode(.sourceAtop)
        }
        context.addPath(path)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            gapped ? piece.opaqueGradient : piece.gradient,
            start: point(for: start),
            end: point(for: end),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}
