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
        let halfLen = max(3, lineW * 1.1) / z      // chevron reach along the path
        let halfWidth = max(3, lineW * 1.0) / z    // chevron spread across the path
        let strokeW = max(1.5, lineW * 0.55) / z
        let pad = (halfLen + halfWidth) * 2

        context.setLineWidth(CGFloat(strokeW))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(arrowColor())

        // Distance carried across segment boundaries so spacing is uniform along
        // the whole path rather than resetting at every vertex.
        var carry = spacing
        for i in 1..<count {
            let a = points[i - 1], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let segLength = (dx * dx + dy * dy).squareRoot()
            if segLength == 0 { continue }

            // Skip segments outside the visible rect, but keep the spacing carry
            // accurate so on-screen chevrons stay evenly placed.
            let segRect = MKMapRect(
                x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad,
                width: abs(dx) + 2 * pad, height: abs(dy) + 2 * pad
            )
            guard mapRect.intersects(segRect) else {
                var d = carry
                while d <= segLength { d += spacing }
                carry = d - segLength
                continue
            }

            let ux = dx / segLength, uy = dy / segLength   // unit direction
            let nx = -uy, ny = ux                          // unit normal
            var d = carry
            while d <= segLength {
                let cx = a.x + ux * d, cy = a.y + uy * d
                let tip = point(for: MKMapPoint(x: cx + ux * halfLen, y: cy + uy * halfLen))
                let left = point(for: MKMapPoint(
                    x: cx - ux * halfLen + nx * halfWidth, y: cy - uy * halfLen + ny * halfWidth))
                let right = point(for: MKMapPoint(
                    x: cx - ux * halfLen - nx * halfWidth, y: cy - uy * halfLen - ny * halfWidth))

                context.beginPath()
                context.move(to: left)
                context.addLine(to: tip)
                context.addLine(to: right)
                context.strokePath()

                d += spacing
            }
            carry = d - segLength
        }
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
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let shade: CGFloat = luminance > 0.6 ? 0.15 : 1.0
        return CGColor(gray: shade, alpha: 0.95)
    }
}
