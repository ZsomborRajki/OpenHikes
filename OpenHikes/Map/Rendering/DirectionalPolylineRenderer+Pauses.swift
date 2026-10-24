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

    /// The line's stroke: MapKit's own over the whole overlay, or each walked
    /// run's copy when the line was paused.
    func strokeLine(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard isCut else {
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            return
        }
        let reach = reachRect(mapRect, zoomScale: zoomScale)
        for run in runLines(forScale: contentScaleFactor) where run.polyline.boundingMapRect.intersects(reach) {
            drawInPlace(of: run.polyline, context: context) {
                run.line.draw(mapRect, zoomScale: zoomScale, in: context)
            }
        }
    }

    /// The border under the line, with the line's own stroke cleared back out
    /// of it — see `drawBorder` — run by run when the line was paused.
    /// Returns `false` for a line with no pause, whose border is drawn whole.
    func strokeRunBorders(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) -> Bool {
        guard isCut else { return false }
        let reach = reachRect(mapRect, zoomScale: zoomScale)
        for run in runLines(forScale: contentScaleFactor) where run.polyline.boundingMapRect.intersects(reach) {
            drawInPlace(of: run.polyline, context: context) {
                run.border?.draw(mapRect, zoomScale: zoomScale, in: context)
                context.saveGState()
                context.setBlendMode(.clear)
                run.line.draw(mapRect, zoomScale: zoomScale, in: context)
                context.restoreGState()
            }
        }
        return true
    }

    /// `mapRect` grown by the widest thing a run strokes, its border, so a run
    /// whose edge reaches into the rect is not skipped with the runs that
    /// are nowhere near it.
    private func reachRect(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> MKMapRect {
        let width = Double(lineWidth)
        let reach = (width + RouteBorder.width(forLineWidth: width) * 2) * Double(contentScaleFactor / zoomScale)
        return mapRect.insetBy(dx: -reach, dy: -reach)
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
