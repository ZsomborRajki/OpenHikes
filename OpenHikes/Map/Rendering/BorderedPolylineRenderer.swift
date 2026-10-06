//
//  BorderedPolylineRenderer.swift
//  OpenHikes
//
//  A plain line with an outline: the trail being drawn in the maker, and the
//  red line of a recording. Both sit on the same basemaps a hike's own line
//  does, and a hike's line carries a black border by default — see
//  ``RouteStyle/defaultBorder`` — so these carry one too, or the line on top
//  of a green valley is the only one that disappears into it.
//
//  Drawn the way ``DirectionalPolylineRenderer`` draws a hike's border, and
//  from the same copy of the line, ``RouteBorderLine``: MapKit's own stroke,
//  wider, underneath, with the line's stroke cleared back out of it so a
//  translucent line shows the map through it rather than the border. Not that
//  renderer itself, because its dashes come from a ``RouteLinePattern`` and
//  these lines dash by what their state means — a leg being routed, a leg
//  that found no path, a recording's live tail — so the border here follows
//  the renderer's own `lineDashPattern`.
//

import MapKit
import OpenHikesData
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated final class BorderedPolylineRenderer: MKPolylineRenderer {
    /// The outline's colour, or `nil` — or a clear colour — for none.
    var borderColor: CGColor? {
        didSet { invalidateBorderLine() }
    }

    override var lineWidth: CGFloat {
        didSet { invalidateBorderLine() }
    }

    // MapKit's own type, overridden only to notice a change.
    // swiftlint:disable:next legacy_objc_type discouraged_optional_collection
    override var lineDashPattern: [NSNumber]? {
        didSet { invalidateBorderLine() }
    }

    override var lineCap: CGLineCap {
        didSet { invalidateBorderLine() }
    }

    /// The border's copy of the line, built by the first draw that needs it
    /// and never changed afterwards, for the reasons
    /// ``DirectionalPolylineRenderer``'s own copy gives.
    private let borderLine = OSAllocatedUnfairLock<(scale: CGFloat, line: MKPolylineRenderer)?>(
        uncheckedState: nil
    )

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if let borderColor, borderColor.alpha > 0 {
            context.saveGState()
            // MapKit can leave a dash on the context, which a copy drawn solid
            // would otherwise inherit.
            context.setLineDash(phase: 0, lengths: [])
            borderLine(forScale: contentScaleFactor, color: borderColor)
                .draw(mapRect, zoomScale: zoomScale, in: context)
            // The line's own stroke, clearing what it covers, so what is left
            // of the copy is a ring.
            context.setBlendMode(.clear)
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            context.restoreGState()
        }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }

    private func invalidateBorderLine() {
        borderLine.withLockUnchecked { $0 = nil }
    }

    private func borderLine(forScale scale: CGFloat, color: CGColor) -> MKPolylineRenderer {
        borderLine.withLockUnchecked { built in
            if let built, built.scale == scale { return built.line }
            let line = RouteBorderLine.make(
                for: polyline,
                lineWidth: Double(lineWidth),
                dashes: (lineDashPattern ?? []).map(\.doubleValue),
                cap: lineCap,
                color: color,
                scale: scale
            )
            built = (scale, line)
            return line
        }
    }
}

/// The border's copy of a line: MapKit's own polyline renderer, wider, in the
/// border colour, never added to a map — only drawn from inside another
/// renderer's draw, under the line it outlines.
///
/// MapKit's stroke rather than a path stroked by hand, because MapKit thins a
/// line's points to what the zoom can show before stroking it and nothing
/// outside it can — see ``RouteBorder`` for what the hand-stroked outline
/// cost. Sized by the outer renderer's `contentScaleFactor`, which is how
/// MapKit widens the line on top; the copy is never on a map, so its own
/// factor stays one and the factor goes into its width and dashes instead.
nonisolated enum RouteBorderLine {
    /// - Parameters:
    ///   - lineWidth: the outlined line's width, in points.
    ///   - dashes: the outlined line's dashes, in points; empty for solid.
    ///   - scale: the outer renderer's `contentScaleFactor`.
    static func make(
        for polyline: MKPolyline,
        lineWidth: Double,
        dashes: [Double],
        cap: CGLineCap,
        color: CGColor?,
        scale: CGFloat
    ) -> MKPolylineRenderer {
        let line = MKPolylineRenderer(polyline: polyline)
        let border = RouteBorder.width(forLineWidth: lineWidth)
        let outlined = RouteBorder.dashes(outlining: dashes, cap: cap, borderWidth: border)
        line.lineWidth = CGFloat(lineWidth + border * 2) * scale
        line.lineJoin = .round
        line.lineCap = cap
        // swiftlint:disable:next legacy_objc_type
        line.lineDashPattern = outlined.lengths.isEmpty ? nil : outlined.lengths.map { NSNumber(value: $0 * scale) }
        line.lineDashPhase = CGFloat(outlined.phase) * scale
        #if canImport(UIKit)
        line.strokeColor = color.map { UIColor(cgColor: $0) }
        #else
        line.strokeColor = color.flatMap { NSColor(cgColor: $0) }
        #endif
        return line
    }
}
