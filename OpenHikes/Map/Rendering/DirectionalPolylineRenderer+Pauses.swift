//
//  DirectionalPolylineRenderer+Pauses.swift
//  OpenHikes
//
//  The route line, cut where the walk was paused.
//
//  A paused leg — a Pause and Resume, or the jump between two GPX
//  `<trkseg>`s — is not trail (#962): `RouteProfile` gives it no length and
//  never matches onto it. The line used to be stroked straight across it in
//  the hike's own tint, border and chevrons, with the faint dotted pause laid
//  on top, so a 5 km drive read as 5 km of trail with dots on it. Now the
//  line is drawn walked run by walked run, and the dotted overlay
//  (`MapView.addPausedOverlays`) is all that crosses a pause, as on the watch
//  since #1011 (#1034).
//
//  Cut here rather than by adding each run to the map as an overlay of its
//  own, because the line is still *one route* to everything else that reads
//  it: the fit, the tap, the coloured stretches drawn into it, and the
//  chevron pass, whose ``RouteChevronField`` keeps an out-and-back from
//  stamping two opposed chevrons on every metre — across a pause too. So the
//  overlay stays the whole line, and only what is stroked changes: each run is
//  stroked by a copy of the line's own renderer, the way the border is (see
//  ``DirectionalPolylineRenderer``'s `borderLine`), and the chevrons skip the
//  paused legs. Cut rather than cleared, because clearing the paused leg out
//  of a drawn line would also cut a notch wherever a walked run crosses it.
//
//  The runs are still one line where they meet each other, though. An
//  out-and-back paused at the top is two runs along the same trail, and a
//  walk that resumes across its own path is two runs through one place, so
//  each pass — every border, then every clear, then every line — is put down
//  as one stroke of the whole line would put it: a translucent colour is
//  painted once where runs lie over each other, and no run's border shows
//  through another run's line.
//
//  A route with no pause takes none of this: its line is still MapKit's own
//  stroke of the whole overlay.
//

import MapKit
import OpenHikesData
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated extension DirectionalPolylineRenderer {
    /// The walked runs and the legs between them, and the copies built to
    /// stroke them.
    struct RunState {
        var runs: [MKPolyline] = []
        var pausedLegs: Set<Int> = []
        /// Built by the first draw that needs them, for the reason the border's
        /// copy is, and dropped by any change to how the line is stroked.
        var built: (scale: CGFloat, lines: [RunLine])?
    }

    /// One walked run's passes: its border, when the line has one, and the
    /// line itself.
    struct RunLine {
        let polyline: MKPolyline
        let line: MKPolylineRenderer
        let border: MKPolylineRenderer?
    }

    /// The walked runs the line is stroked as. Empty when it has no pause —
    /// and when every leg of it was paused, which ``pausedLegs`` tells apart.
    var runs: [MKPolyline] {
        runState.withLockUnchecked { $0.runs }
    }

    /// The legs a pause opened, each by the index of the point it leaves —
    /// ``TrailRuns/pausedLegs``. No line and no chevron is drawn along them.
    var pausedLegs: Set<Int> {
        runState.withLockUnchecked { $0.pausedLegs }
    }

    /// Whether the line was paused, and so is stroked run by run.
    var isCut: Bool {
        runState.withLockUnchecked { !$0.pausedLegs.isEmpty }
    }

    /// Cuts the line into `runs` across `pausedLegs` — or, with no paused
    /// legs, strokes it whole again.
    func setRuns(_ runs: [MKPolyline], pausedLegs: Set<Int>) {
        runState.withLockUnchecked { state in
            state.runs = pausedLegs.isEmpty ? [] : runs
            state.pausedLegs = pausedLegs
            state.built = nil
        }
    }

    /// Drops the runs' copies, for the next draw to rebuild from the style as
    /// it is now.
    func invalidateRunLines() {
        runState.withLockUnchecked { $0.built = nil }
    }

    /// The line's stroke: MapKit's own over the whole overlay, or the walked
    /// runs' copies when the line was paused, put down as one stroke of them
    /// all — see ``composite(_:alpha:in:zoomScale:context:_:)``.
    func strokeLine(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard isCut else {
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            return
        }
        let reached = runLines(reaching: mapRect, zoomScale: zoomScale)
        let lineAlpha = strokeColor?.cgColor.alpha ?? 0
        composite(reached, alpha: lineAlpha, in: mapRect, zoomScale: zoomScale, context: context) { run in
            run.line.draw(mapRect, zoomScale: zoomScale, in: context)
        }
    }

    /// The border under the line, with the line's own stroke cleared back out
    /// of it — see `drawBorder` — round every walked run when the line was
    /// paused. Returns `false` for a line with no pause, whose border is drawn
    /// whole.
    ///
    /// Every run's border goes down before any run's line is cleared out of
    /// it, as the whole line's border goes down before the whole line is.
    /// Outlined and cleared run by run, a later run's border landed inside
    /// the middle already cleared out of an earlier run it crossed or
    /// retraced, and showed through a translucent line there.
    func strokeRunBorders(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) -> Bool {
        guard isCut else { return false }
        let reached = runLines(reaching: mapRect, zoomScale: zoomScale)
        let borderAlpha = borderColor?.alpha ?? 0
        composite(reached, alpha: borderAlpha, in: mapRect, zoomScale: zoomScale, context: context) { run in
            run.border?.draw(mapRect, zoomScale: zoomScale, in: context)
        }
        context.saveGState()
        context.setBlendMode(.clear)
        for run in reached {
            drawInPlace(of: run.polyline, context: context) {
                run.line.draw(mapRect, zoomScale: zoomScale, in: context)
            }
        }
        context.restoreGState()
        return true
    }

    /// One pass over `runs`, each run's share of it drawn by `pass` once the
    /// context is moved to that run, composited as one stroke of them all
    /// would be: where runs lie over each other, a translucent colour is
    /// painted once. An out-and-back paused at the top is two runs along the
    /// same trail, and laid one over the other its line came out darker
    /// there than the alpha the hiker chose — darker than MapKit, which
    /// strokes the whole line as one path, ever drew it.
    ///
    /// So each run replaces what the runs before it put down rather than
    /// being laid over it, `.copy` as the coloured stretches are, inside a
    /// layer of their own so that it replaces nothing of the map's (see
    /// `isolationBounds`), and the layer is laid over the map as one. Only
    /// for a translucent pass with two runs or more within reach: an opaque
    /// one paints the same either way, and the layer is a bitmap made on
    /// every draw, so it is bounded by the runs it holds.
    ///
    /// Not one `MKMultiPolylineRenderer` holding every run, which composites
    /// the same way by itself: it costs what the border's copy is MapKit's
    /// own line to avoid (see ``borderLine``). Measured on a simulator, a
    /// 20,000-point walk in two runs seen whole on a 512-pixel tile took it
    /// 14.2 ms against 1.3 ms for the copies; cut and translucent, layer and
    /// all, the line drew no slower than it does whole.
    private func composite(
        _ runs: [RunLine],
        alpha: CGFloat,
        in mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        context: CGContext,
        _ pass: (RunLine) -> Void
    ) {
        let layer = layerBounds(of: runs, alpha: alpha, in: mapRect, zoomScale: zoomScale)
        if let layer {
            context.beginTransparencyLayer(in: layer, auxiliaryInfo: nil)
            context.saveGState()
            context.setBlendMode(.copy)
        }
        for run in runs {
            drawInPlace(of: run.polyline, context: context) { pass(run) }
        }
        if layer != nil {
            context.restoreGState()
            context.endTransparencyLayer()
        }
    }

    /// Where ``composite(_:alpha:in:zoomScale:context:_:)`` puts a pass's
    /// layer, or `nil` where the pass needs none.
    private func layerBounds(
        of runs: [RunLine],
        alpha: CGFloat,
        in mapRect: MKMapRect,
        zoomScale: MKZoomScale
    ) -> CGRect? {
        guard runs.count > 1, alpha > 0, alpha < 1 else { return nil }
        let reach = runReach(zoomScale: zoomScale)
        let bounds = runs.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
            .insetBy(dx: -reach, dy: -reach)
            .intersection(mapRect)
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        return rect(for: bounds)
    }

    /// The runs' copies whose strokes can reach into `mapRect`, leaving out
    /// the runs that are nowhere near it.
    private func runLines(reaching mapRect: MKMapRect, zoomScale: MKZoomScale) -> [RunLine] {
        let reach = runReach(zoomScale: zoomScale)
        let near = mapRect.insetBy(dx: -reach, dy: -reach)
        return runLines(forScale: contentScaleFactor).filter { $0.polyline.boundingMapRect.intersects(near) }
    }

    /// How far the widest thing a run strokes, its border, reaches, in map
    /// points at `zoomScale`.
    private func runReach(zoomScale: MKZoomScale) -> Double {
        let width = Double(lineWidth)
        return (width + RouteBorder.width(forLineWidth: width) * 2) * Double(contentScaleFactor / zoomScale)
    }

    /// The runs' copies for a renderer at `scale` — none for a line that
    /// was never cut.
    ///
    /// Each copy is the line's own stroke — colour, width, cap, join and
    /// dashes — scaled by `contentScaleFactor` for the reason the border's
    /// copy is: it is never on a map, so its own factor stays one.
    private func runLines(forScale scale: CGFloat) -> [RunLine] {
        runState.withLockUnchecked { state in
            if let built = state.built, built.scale == scale { return built.lines }
            let bordered = (borderColor?.alpha ?? 0) > 0
            let lines = state.runs.map { run in
                let line = MKPolylineRenderer(polyline: run)
                line.strokeColor = strokeColor
                line.lineWidth = lineWidth * scale
                line.lineJoin = lineJoin
                line.lineCap = lineCap
                // swiftlint:disable:next legacy_objc_type
                line.lineDashPattern = lineDashPattern?.map { NSNumber(value: $0.doubleValue * Double(scale)) }
                line.lineDashPhase = lineDashPhase * scale
                return RunLine(
                    polyline: run,
                    line: line,
                    border: bordered ? makeBorderLine(for: run, scale: scale) : nil
                )
            }
            state.built = (scale, lines)
            return lines
        }
    }
}
