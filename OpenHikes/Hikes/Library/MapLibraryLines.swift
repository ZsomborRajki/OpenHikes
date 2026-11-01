//
//  MapLibraryLines.swift
//  OpenHikes
//
//  The hiker's own hikes, every one of them, on the map.
//
//  ``LibraryLines`` reads the lines; this is the half that draws them and
//  answers a tap on one. See `LibraryLinesRenderer.swift` for how a library of
//  hundreds is drawn in one overlay.
//
//  ## Faded, as the shared hikes are, and a little less
//
//  Each line is drawn the way the *Community* tab draws a shared hike — its
//  own colour, outlined in the black a hike's line wears until its owner picks
//  one (``RouteStyle/defaultBorder``), line and outline faded together — so
//  the selected route stays the one thing on the map at full strength. But a
//  little stronger than the shared ones, ``libraryLineAlpha`` against
//  ``communityRouteAlpha``, and drawn over them: a hike in the library,
//  imported from the *Community* tab or not, is the hiker's own, and where it
//  crosses somebody else's suggestion it is theirs that reads first. The
//  shared lines no longer have the map to themselves either — both are drawn
//  in both tabs.
//
//  The order within the one level everything here is drawn at is the ground,
//  the shared hikes' faded lines, these, the open preview's own line, then the
//  selected route and everything drawn over it. The preview's line is over
//  these for the reason the selected route is: it is drawn at full strength
//  because it is what the hiker is looking at, and a faded hike laid over it
//  would fade it too wherever the two follow the same path.
//
//  ## What is left out
//
//  - **The selected hike**, which the map draws properly. Its faded copy
//    under the real line would show through a dashed or translucent route,
//    and beside it wherever the outline cut a corner.
//  - **Everything while a trail is being drawn**, for the reason the shared
//    hikes are withdrawn then (``withdrawCommunityForDrawing(_:on:)``): the
//    maker's map is the trail being drawn.
//
//  ## A tap
//
//  Opens the hike, as its row does: selected, drawn properly, its screen
//  pushed — through ``HikeOpenRequests``, so there is one way in for a widget,
//  Siri and this. The selected route is asked first, then the open preview's
//  line, then these, then the other shared hikes' lines: the order they are
//  drawn in, top down. See `MapCoordinator+RouteTap.swift`.
//
//  **Not while a recording is under way.** The live line cannot be tapped and
//  is drawn over these, and a hiker walking a trail they have walked before
//  has its faded copy right under it — so a thumb on their own track would
//  land here, and the jump to that hike would take them off the recording.
//  The lines stay drawn, and the list still opens any of them.
//

import Algorithms
import MapKit
import OpenHikesData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One hike's line as the map holds it: the polylines MapKit draws, and the
/// points a tap is measured against.
struct LibraryLineDrawing {
    let line: LibraryLine
    let rendered: LibraryLinesRenderer.Line

    init(line: LibraryLine) {
        self.line = line
        let polylines = line.runs.map { MKPolyline(coordinates: $0, count: $0.count) }
        // Opaque, as the hike's row circle is: the layer the lines are drawn
        // in fades them, and a hike's own alpha belongs to its selected line.
        let tint = (Color(hex: line.tintHex) ?? RouteStyle.defaultTint).opaque
        #if os(macOS)
        let color = NSColor(tint).cgColor
        #else
        let color = UIColor(tint).cgColor
        #endif
        rendered = LibraryLinesRenderer.Line(
            polylines: polylines,
            boundingMapRect: polylines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) },
            color: color
        )
    }
}

/// What the map has drawn of the library — see ``MapView/Coordinator/libraryMap``.
struct LibraryLinesMapState {
    weak var library: LibraryLines?
    /// Whether a recording is under way, which takes the lines' taps away —
    /// see the file header.
    weak var recording: RecordingEntry?
    var isObserving = false
    /// One per hike drawn, newest first.
    var drawings: [LibraryLineDrawing] = []
    var overlay: LibraryLinesOverlay?
    weak var renderer: LibraryLinesRenderer?
}

extension MapView.Coordinator {
    /// A little stronger than a shared hike's line — see the file header.
    static let libraryLineAlpha: CGFloat = 0.6
    /// A shared hike's width, for the reason the fade is a shared hike's.
    static let libraryLineWidth: CGFloat = 3.5

    /// Observes the library's lines and applies them imperatively, then
    /// re-registers — the same arrangement ``observeCommunityRoutes(_:on:)``
    /// uses, and for the same reason: a line landing redraws MapKit and no
    /// SwiftUI view.
    ///
    /// Idempotent, like every other registration here.
    func observeLibraryLines(_ library: LibraryLines, recording: RecordingEntry, on mapView: MKMapView) {
        guard !libraryMap.isObserving else { return }
        libraryMap.isObserving = true
        libraryMap.library = library
        libraryMap.recording = recording
        trackLibraryLines(library, on: mapView)
    }

    private func trackLibraryLines(_ library: LibraryLines, on mapView: MKMapView) {
        applyLibraryLines(on: mapView)
        reobserving(self, mapView, library) {
            _ = library.lines
        } onChange: { coordinator, map, model in
            coordinator.trackLibraryLines(model, on: map)
        }
    }

    /// Brings the drawn lines up to the library: every line but the selected
    /// hike's, and none while a trail is being drawn.
    ///
    /// Asked again when a line lands, when the selection's route is drawn or
    /// taken away (`MapView.updateRoute`) and when the maker opens or closes.
    /// The guard keeps a republish of the same lines from redrawing the map,
    /// and a line that did not change keeps its polylines, so the renderer
    /// keeps its strokes.
    func applyLibraryLines(on mapView: MKMapView) {
        let shown = isDrawingTrail ? [] : (libraryMap.library?.lines ?? []).filter { $0.hikeID != routeID }
        guard shown != libraryMap.drawings.map(\.line) else { return }
        let kept = libraryMap.drawings.keyed(by: \.line.hikeID)
        libraryMap.drawings = shown.map { line in
            if let drawing = kept[line.hikeID], drawing.line == line { return drawing }
            return LibraryLineDrawing(line: line)
        }
        guard !shown.isEmpty else {
            if let overlay = libraryMap.overlay {
                mapView.removeOverlay(overlay)
                libraryMap.overlay = nil
                libraryMap.renderer = nil
            }
            return
        }
        // Oldest first, so the newest is drawn on top.
        libraryMap.renderer?.setLines(libraryMap.drawings.reversed().map(\.rendered))
        guard libraryMap.overlay == nil else { return }
        let overlay = LibraryLinesOverlay()
        libraryMap.overlay = overlay
        insertLibraryOverlay(overlay, on: mapView)
    }

    /// Puts the library's overlay over the ground and the shared hikes' faded
    /// lines, and under everything else, the open preview's line included.
    ///
    /// By index, for the reason ``addCommunityOverlays(_:on:)`` gives: what it
    /// goes above is computed when it goes on, not assumed from what was
    /// added first. The faded shared lines go on just above the ground, which
    /// is beneath this, and the preview's line just above this, however they
    /// arrive.
    private func insertLibraryOverlay(_ overlay: LibraryLinesOverlay, on mapView: MKMapView) {
        let drawn = mapView.overlays(in: .aboveLabels)
        let below: (any MKOverlay)? = communityRoutes.last { !$0.line.isPreviewed }?.polyline ?? groundOverlay
        let floor = below
            .flatMap { below in drawn.firstIndex { $0 === below } }
            .map { $0 + 1 } ?? 0
        mapView.insertOverlay(overlay, at: floor, level: .aboveLabels)
    }

    /// The renderer for the library's overlay, handed what is drawn now.
    func libraryLinesRenderer(for overlay: LibraryLinesOverlay) -> LibraryLinesRenderer {
        let renderer = LibraryLinesRenderer(
            overlay: overlay,
            layerAlpha: Self.libraryLineAlpha,
            lineWidth: Self.libraryLineWidth,
            borderColor: Self.defaultBorderColor
        )
        renderer.setLines(libraryMap.drawings.reversed().map(\.rendered))
        libraryMap.renderer = renderer
        return renderer
    }
}

// MARK: - Tapping one

#if canImport(UIKit)
extension MapView.Coordinator {
    /// The hike whose line a tap at `point` landed on, if any.
    ///
    /// Asked by ``routeTapTarget(at:in:)``, which owns the recognizer and the
    /// order — see `MapCoordinator+RouteTap.swift`.
    ///
    /// Each run's bounding rectangle first, for the reason
    /// ``isTapOnDrawnRoute(at:in:)`` asks the route's: most of a library is
    /// nowhere near a thumb, and a run that is costs its own points and no
    /// more — at most ``LibraryLineOutline/maximumPoints`` a hike. Nearest
    /// wins, so a thumb between two trails opens the one under it.
    ///
    /// Nothing while a recording is under way — see the file header.
    func libraryHikeID(forTapAt point: CGPoint, in mapView: MKMapView) -> UUID? {
        guard !libraryMap.drawings.isEmpty, libraryMap.recording?.isRecording != true else { return nil }
        let tolerance = Self.lineTapTolerancePoints
        var hikes: [UUID] = []
        var projected: [[CGPoint]] = []
        for drawing in libraryMap.drawings {
            for (polyline, run) in zip(drawing.rendered.polylines, drawing.line.runs) {
                let bounds = mapView
                    .convert(MKCoordinateRegion(polyline.boundingMapRect), toRectTo: mapView)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                guard bounds.contains(point) else { continue }
                hikes.append(drawing.line.hikeID)
                projected.append(run.map { mapView.convert($0, toPointTo: mapView) })
            }
        }
        return RouteHitTest.nearest(to: point, among: projected, tolerance: tolerance).map { hikes[$0] }
    }
}
#endif
