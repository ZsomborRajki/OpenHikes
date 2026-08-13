//
//  DirectionalPolylineRenderer.swift
//  OpenTrails
//
//  Draws the route line and overlays evenly-spaced chevrons pointing in the
//  direction of travel. The chevrons are drawn in the same pass as the line and
//  only where the segment intersects the visible map rect — no annotations, no
//  timers, no per-frame animation — so they add no idle cost and stay glued to
//  the path under zoom and rotation.
//

import MapKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated final class DirectionalPolylineRenderer: MKPolylineRenderer {
    private static let chevronReachMultiplier: Double = 1.1
    private static let chevronSpreadMultiplier: Double = 1.0
    private static let chevronStrokeMultiplier: Double = 0.55
    private static let luminanceRedWeight: Double = 0.299
    private static let luminanceGreenWeight: Double = 0.587
    private static let luminanceBlueWeight: Double = 0.114
    private static let luminanceDarkThreshold: CGFloat = 0.6
    private static let chevronDarkShade: CGFloat = 0.15
    private static let chevronLightShade: CGFloat = 1.0
    private static let chevronAlpha: CGFloat = 0.95
    private static let chevronMinSize: Double = 3
    private static let chevronMinStroke: Double = 1.5

    /// Gap between chevrons, in screen points (kept constant across zoom levels).
    var arrowSpacing: Double = 55

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)

        guard let polyline = overlay as? MKPolyline, polyline.pointCount > 1 else { return }
        let count = polyline.pointCount
        let points = polyline.points()

        // Convert screen-point sizes into map-point space for this zoom level.
        let z = Double(zoomScale)
        guard z > 0 else { return }
        let spacing = arrowSpacing / z
        guard spacing > 0 else { return }
        let lineW = Double(lineWidth)
        // chevron reach along the path
        let halfLen = max(Self.chevronMinSize, lineW * Self.chevronReachMultiplier) / z
        // chevron spread across the path
        let halfWidth = max(Self.chevronMinSize, lineW * Self.chevronSpreadMultiplier) / z
        let strokeW = max(Self.chevronMinStroke, lineW * Self.chevronStrokeMultiplier) / z
        let pad = (halfLen + halfWidth) * 2

        context.setLineWidth(CGFloat(strokeW))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(arrowColor())

        // Distance carried across segment boundaries so spacing is uniform along
        // the whole path rather than resetting at every vertex.
        var carry = spacing
        for i in 1..<count {
            drawChevrons(
                from: points[i - 1],
                to: points[i],
                halfLen: halfLen,
                halfWidth: halfWidth,
                spacing: spacing,
                pad: pad,
                mapRect: mapRect,
                context: context,
                carry: &carry
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func drawChevrons(
        from a: MKMapPoint,
        to b: MKMapPoint,
        halfLen: Double,
        halfWidth: Double,
        spacing: Double,
        pad: Double,
        mapRect: MKMapRect,
        context: CGContext,
        carry: inout Double
    ) {
        let dx = b.x - a.x, dy = b.y - a.y
        let segLength = (dx * dx + dy * dy).squareRoot()
        if segLength == 0 { return }

        // Skip segments outside the visible rect, but keep the spacing carry
        // accurate so on-screen chevrons stay evenly placed.
        let segRect = MKMapRect(
            x: min(a.x, b.x) - pad,
            y: min(a.y, b.y) - pad,
            width: abs(dx) + 2 * pad,
            height: abs(dy) + 2 * pad
        )
        guard mapRect.intersects(segRect) else {
            // Closed-form version of the on-screen loop below (advance `d` by
            // `spacing` until it passes `segLength`). An off-screen segment
            // isn't bounded by screen size, so at deep zoom (tiny `spacing`)
            // a single long segment could otherwise mean millions of
            // iterations just to keep the chevron spacing carry accurate.
            let steps = max(0, Int(((segLength - carry) / spacing).rounded(.down)) + 1)
            carry = carry + Double(steps) * spacing - segLength
            return
        }

        let ux = dx / segLength, uy = dy / segLength   // unit direction
        let nx = -uy, ny = ux                          // unit normal
        var d = carry
        while d <= segLength {
            let cx = a.x + ux * d, cy = a.y + uy * d
            let tip = point(for: MKMapPoint(x: cx + ux * halfLen, y: cy + uy * halfLen))
            let left = point(
                for: MKMapPoint(
                    x: cx - ux * halfLen + nx * halfWidth,
                    y: cy - uy * halfLen + ny * halfWidth
                )
            )
            let right = point(
                for: MKMapPoint(
                    x: cx - ux * halfLen - nx * halfWidth,
                    y: cy - uy * halfLen - ny * halfWidth
                )
            )

            context.beginPath()
            context.move(to: left)
            context.addLine(to: tip)
            context.addLine(to: right)
            context.strokePath()

            d += spacing
        }
        carry = d - segLength
    }

    /// A grey shade that contrasts with the line color (near-white on dark lines,
    /// near-black on light ones), kept opaque so chevrons read even on a
    /// translucent route.
    private func arrowColor() -> CGColor {
        #if canImport(UIKit)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        (strokeColor ?? .white).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let c = (strokeColor ?? .white).usingColorSpace(.sRGB) ?? .white
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        #endif
        let luminance = Self.luminanceRedWeight * r + Self.luminanceGreenWeight * g + Self.luminanceBlueWeight * b
        let shade: CGFloat = luminance > Self.luminanceDarkThreshold ? Self.chevronDarkShade : Self.chevronLightShade
        return CGColor(gray: shade, alpha: Self.chevronAlpha)
    }
}
