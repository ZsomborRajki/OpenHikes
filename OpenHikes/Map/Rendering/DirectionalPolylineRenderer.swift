//
//  DirectionalPolylineRenderer.swift
//  OpenHikes
//
//  Draws the route line and overlays evenly-spaced chevrons pointing in the
//  direction of travel. The chevrons are drawn in the same pass as the line and
//  only where the segment intersects the visible map rect — no annotations, no
//  timers, no per-frame animation — so they add no idle cost and stay glued to
//  the path under zoom and rotation.
//
//  Which of the two halves runs — the stroke, the chevrons, or both — is the
//  hike's ``RouteLinePattern``. Dashing is left to `MKPolylineRenderer`'s own
//  stroke properties; only the chevrons are drawn here.
//
//  A border colour, when the hike has one, is drawn first and underneath: a
//  ring round the line's own stroke and the chevrons again, widened, so the
//  outline follows every mark the pattern makes. See ``RouteBorder``.
//
//  A chevron is offered to ``RouteChevronField`` before it is drawn, which is
//  what keeps a route that comes home the way it went out from stamping two
//  opposed chevrons on every metre of it. That file carries the reasoning.
//

import MapKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated final class DirectionalPolylineRenderer: MKPolylineRenderer {
    /// The hike's chosen line pattern. Set by the map coordinator alongside the
    /// stroke colour and width, so a pattern change restyles the live renderer
    /// rather than rebuilding the overlay.
    var pattern: RouteLinePattern = .default

    /// The hike's border colour, set alongside ``pattern``. A `CGColor`
    /// rather than the platform colour because that is all drawing needs; an
    /// alpha of zero — every hike that never picked one — draws nothing.
    var borderColor: CGColor?

    /// The chevron geometry for one draw pass, in the map points the renderer
    /// draws in rather than the screen points the pattern states it in. The
    /// conversion happens once here instead of at every chevron.
    private struct ChevronPlan {
        let spacing: Double
        let halfLength: Double
        let halfWidth: Double
        let strokeWidth: Double
        /// How far a segment's bounding box grows before it is tested against
        /// the visible rect, so a chevron reaching over the edge is not
        /// skipped along with the segment it rides.
        let pad: Double
        let retraceClearance: Double
        let overlapClearance: Double

        /// `nil` at a zoom scale that leaves nothing to place — zero, negative
        /// or large enough to divide the spacing away to nothing.
        init?(metrics: RouteChevronMetrics, zoomScale: Double) {
            guard zoomScale > 0 else { return nil }
            spacing = metrics.spacing / zoomScale
            guard spacing > 0, spacing.isFinite else { return nil }
            halfLength = metrics.halfLength / zoomScale
            halfWidth = metrics.halfWidth / zoomScale
            strokeWidth = metrics.strokeWidth / zoomScale
            pad = (halfLength + halfWidth) * 2
            retraceClearance = metrics.retraceClearance / zoomScale
            overlapClearance = metrics.overlapClearance / zoomScale
        }

        /// The bucket size for the pass's field: the widest clearance it will
        /// ask about, so a conflicting chevron is always in one of the nine
        /// cells around the candidate.
        var cellSize: Double { max(retraceClearance, overlapClearance) }
    }

    /// What one chevron pass carries from segment to segment: how far along
    /// the next chevron is, and the ground the drawn ones already cover.
    private struct ChevronPass {
        let plan: ChevronPlan
        let mapRect: MKMapRect
        /// Distance carried across segment boundaries so spacing is uniform
        /// along the whole path rather than resetting at every vertex.
        var carry: Double
        var placed: RouteChevronField

        init(plan: ChevronPlan, mapRect: MKMapRect) {
            self.plan = plan
            self.mapRect = mapRect
            carry = plan.spacing
            placed = RouteChevronField(cellSize: plan.cellSize)
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if let borderColor, borderColor.alpha > 0 {
            drawBorder(borderColor, in: mapRect, zoomScale: zoomScale, context: context)
        }
        // The dash pattern (and the cap that makes a dotted line round) are
        // ordinary stroke properties, so the inherited draw already honours
        // them; only `arrowheads`, which has no line at all, opts out.
        if pattern.drawsLine {
            super.draw(mapRect, zoomScale: zoomScale, in: context)
        }
        strokeChevrons(in: mapRect, zoomScale: zoomScale, context: context, color: arrowColor(), widenedBy: 0)
    }

    /// The border, drawn under the marks it outlines: a ring round the line's
    /// own stroke, and each chevron again, widened.
    ///
    /// The line's ring is traced round the shape MapKit is about to stroke —
    /// its width, its dashes, its caps, straight from `applyStrokeProperties`
    /// — rather than round a stroke rebuilt here from the same numbers. That
    /// rebuild is what the first version of this did, and on a map it was
    /// invisible: MapKit scales a line by the renderer's `contentScaleFactor`
    /// as well as by the zoom, so the "wider" copy came out a third of the
    /// width of the line on top of it. A unit test cannot see that, because a
    /// renderer drawn outside a map has a factor of one.
    ///
    /// The border's own thickness is scaled the same way, so it stays a third
    /// of the line on screen whatever MapKit's factor is.
    private func drawBorder(
        _ color: CGColor,
        in mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        context: CGContext
    ) {
        let border = CGFloat(RouteBorder.width(forLineWidth: Double(lineWidth))) * contentScaleFactor / zoomScale
        if pattern.drawsLine {
            if path == nil { createPath() }
            if let path {
                context.saveGState()
                context.addPath(path)
                applyStrokeProperties(to: context, atZoomScale: zoomScale)
                context.replacePathWithStrokedPath()
                // Centred on the outline, so half of it is under the line.
                context.setLineWidth(border * 2)
                context.setLineDash(phase: 0, lengths: [])
                context.setLineJoin(.round)
                context.setStrokeColor(color)
                context.strokePath()
                context.restoreGState()
            }
        }
        strokeChevrons(in: mapRect, zoomScale: zoomScale, context: context, color: color, widenedBy: border * 2)
    }

    /// One pass of chevrons along the whole line, in `color` — `widenedBy` map
    /// points wider for the pass that draws their outline. A chevron's caps
    /// and joins are round, so its wider stroke is exactly its outline.
    ///
    /// Both passes place exactly the same chevrons: placement depends only on
    /// the line and the zoom, never on the colour or the width drawn.
    private func strokeChevrons(
        in mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        context: CGContext,
        color: CGColor,
        widenedBy extraWidth: CGFloat
    ) {
        guard let metrics = pattern.chevronMetrics(forWidth: Double(lineWidth)) else { return }
        guard let polyline = overlay as? MKPolyline, polyline.pointCount > 1 else { return }
        let count = polyline.pointCount
        let points = polyline.points()

        // Convert screen-point sizes into map-point space for this zoom level.
        guard let plan = ChevronPlan(metrics: metrics, zoomScale: Double(zoomScale)) else { return }

        context.setLineWidth(CGFloat(plan.strokeWidth) + extraWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // The stroke above may have left a dash pattern on the context; a
        // chevron is a solid glyph whatever the line it rides is drawn as.
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(color)

        var pass = ChevronPass(plan: plan, mapRect: mapRect)
        for i in 1..<count {
            drawChevrons(from: points[i - 1], to: points[i], context: context, pass: &pass)
        }
    }

    private func drawChevrons(
        from a: MKMapPoint,
        to b: MKMapPoint,
        context: CGContext,
        pass: inout ChevronPass
    ) {
        let plan = pass.plan
        let dx = b.x - a.x, dy = b.y - a.y
        let segLength = (dx * dx + dy * dy).squareRoot()
        if segLength == 0 { return }

        // Skip segments outside the visible rect, but keep the spacing carry
        // accurate so on-screen chevrons stay evenly placed.
        let segRect = MKMapRect(
            x: min(a.x, b.x) - plan.pad,
            y: min(a.y, b.y) - plan.pad,
            width: abs(dx) + 2 * plan.pad,
            height: abs(dy) + 2 * plan.pad
        )
        guard pass.mapRect.intersects(segRect) else {
            // Closed-form version of the on-screen loop below (advance `d` by
            // `spacing` until it passes `segLength`). An off-screen segment
            // isn't bounded by screen size, so at deep zoom (tiny `spacing`)
            // a single long segment could otherwise mean millions of
            // iterations just to keep the chevron spacing carry accurate.
            let steps = max(0, Int(((segLength - pass.carry) / plan.spacing).rounded(.down)) + 1)
            pass.carry = pass.carry + Double(steps) * plan.spacing - segLength
            return
        }

        let ux = dx / segLength, uy = dy / segLength   // unit direction
        var d = pass.carry
        while d <= segLength {
            let chevron = RouteChevron(x: a.x + ux * d, y: a.y + uy * d, ux: ux, uy: uy)
            // Ground an earlier chevron already covers: the way home over the
            // way out, a second lap, a switchback tighter than the spacing.
            let clear = pass.placed.claim(
                chevron,
                retrace: plan.retraceClearance,
                crossing: plan.overlapClearance
            )
            if clear { stroke(chevron, plan: plan, in: context) }
            d += plan.spacing
        }
        pass.carry = d - segLength
    }

    /// One chevron: from its left tail to its tip and on to its right tail.
    private func stroke(_ chevron: RouteChevron, plan: ChevronPlan, in context: CGContext) {
        let ux = chevron.ux, uy = chevron.uy
        let nx = -uy, ny = ux                          // unit normal
        let tip = point(
            for: MKMapPoint(
                x: chevron.x + ux * plan.halfLength,
                y: chevron.y + uy * plan.halfLength
            )
        )
        let left = point(
            for: MKMapPoint(
                x: chevron.x - ux * plan.halfLength + nx * plan.halfWidth,
                y: chevron.y - uy * plan.halfLength + ny * plan.halfWidth
            )
        )
        let right = point(
            for: MKMapPoint(
                x: chevron.x - ux * plan.halfLength - nx * plan.halfWidth,
                y: chevron.y - uy * plan.halfLength - ny * plan.halfWidth
            )
        )

        context.beginPath()
        context.move(to: left)
        context.addLine(to: tip)
        context.addLine(to: right)
        context.strokePath()
    }

    /// A grey shade that contrasts with the line color (near-white on dark lines,
    /// near-black on light ones), kept opaque so chevrons read even on a
    /// translucent route.
    ///
    /// With no line to contrast against — ``RouteLinePattern/arrowheads`` — the
    /// chevrons take the route's own colour instead: they are the route, and
    /// drawing them grey would discard the colour the user picked.
    private func arrowColor() -> CGColor {
        let stroke = strokeColor ?? .white
        if pattern.chevronsUseRouteTint { return stroke.cgColor }
        #if canImport(UIKit)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        stroke.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let c = stroke.usingColorSpace(.sRGB) ?? .white
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        #endif
        let luminance = RouteChevronShade.luminance(red: r, green: g, blue: b)
        return CGColor(
            gray: CGFloat(RouteChevronShade.gray(forLuminance: luminance)),
            alpha: CGFloat(RouteChevronShade.alpha)
        )
    }
}
