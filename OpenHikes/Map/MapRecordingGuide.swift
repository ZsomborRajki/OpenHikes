//
//  MapRecordingGuide.swift
//  OpenHikes
//
//  The trail shown under a recording, on the map.
//
//  ``RecordingGuide`` decides which trail it is and reads its line; this is the
//  half that draws it. One line in one overlay, drawn by the renderer the
//  library's lines are (`LibraryLinesRenderer.swift`), but at full strength
//  and a little wider: the trail's own colour outlined in the default black,
//  solid, under the recording's dashed red. Where the hiker is on the trail,
//  the red runs along inside it.
//
//  ## Where it goes
//
//  Over everything else of the hiker's own and of other people's — the
//  library's faded lines, the shared hikes' and the open preview's — and
//  under the selected route and the live line. The live line is added to the
//  top of the level as it grows, so it is over this without being asked; the
//  selected route is put over this by `MapView.updateRoute`.
//
//  ## What is left out
//
//  - **The trail's faded copy in the library**, for the reason the selected
//    hike's is left out there: it would show beside this wherever its outline
//    cut a corner.
//  - **This line, while its hike is the selected one**, which the map draws
//    properly: a hiker who has opened the trail's own screen mid-recording.
//  - **Everything while a trail is being drawn**, for the reason the library
//    is withdrawn then (``withdrawCommunityForDrawing(_:on:)``): the maker's
//    map is the trail being drawn.
//
//  Not tappable. It is under the live line, where a thumb on the hiker's own
//  track would land on it, and opening the trail would take them off the
//  recording — the reason the library's lines are not tappable during one.
//

import MapKit
import OpenHikesData
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the map has drawn of the trail shown under a recording — see
/// ``MapView/Coordinator/guideMap``.
struct RecordingGuideMapState {
    weak var guide: RecordingGuide?
    var isObserving = false
    /// The hike whose line is drawn, or `nil` when none is.
    var hikeID: UUID?
    /// Which projection of its line, and in which colour, so a pass that
    /// changes neither draws nothing again.
    var revision: Int?
    var tintHex: String?
    /// The line as the renderer draws it, kept for a renderer MapKit asks for
    /// after the overlay goes on.
    var line: LibraryLinesRenderer.Line?
    var overlay: LibraryLinesOverlay?
    weak var renderer: LibraryLinesRenderer?
}

extension MapView.Coordinator {
    /// Full strength, unlike the library's faded lines — see the file header.
    static let recordingGuideAlpha: CGFloat = 1
    /// A little wider than the selected route's default, so the recording's
    /// red reads inside it rather than covering it.
    static let recordingGuideWidth: CGFloat = 6

    /// Observes the guide and applies it imperatively, then re-registers —
    /// the arrangement ``observeLibraryLines(_:recording:on:)`` uses, and for
    /// its reason: choosing a trail, its line landing and the recording ending
    /// redraw MapKit and no SwiftUI view.
    ///
    /// Idempotent, like every other registration here.
    func observeRecordingGuide(_ guide: RecordingGuide, on mapView: MKMapView) {
        guard !guideMap.isObserving else { return }
        guideMap.isObserving = true
        guideMap.guide = guide
        trackRecordingGuide(guide, on: mapView)
    }

    private func trackRecordingGuide(_ guide: RecordingGuide, on mapView: MKMapView) {
        applyRecordingGuide(on: mapView)
        reobserving(self, mapView, guide) {
            _ = guide.shown
            _ = guide.line
        } onChange: { coordinator, map, model in
            coordinator.trackRecordingGuide(model, on: map)
        }
    }

    /// Brings the drawn line up to the guide: its line, unless its hike is
    /// the selected one or a trail is being drawn, and nothing otherwise.
    ///
    /// Asked again when the guide changes, when the selection's route is
    /// drawn or taken away (`MapView.updateRoute`) and when the maker opens or
    /// closes. The library is asked again whenever the hike drawn here
    /// changes, because it leaves that hike out.
    func applyRecordingGuide(on mapView: MKMapView) {
        let guide = guideMap.guide
        let drawn: (trail: RecordingGuide.Trail, line: DisplayedRouteCoordinateCache.DrawnRoute)? =
            if !isDrawingTrail, let trail = guide?.shown, trail.hikeID != routeID,
               let line = guide?.line, line.coordinates.count > 1 {
                (trail, line)
            } else {
                nil
            }
        guard drawn?.trail.hikeID != guideMap.hikeID
            || drawn?.line.revision != guideMap.revision
            || drawn?.trail.tintHex != guideMap.tintHex else { return }
        let hikeChanged = drawn?.trail.hikeID != guideMap.hikeID
        guideMap.hikeID = drawn?.trail.hikeID
        guideMap.revision = drawn?.line.revision
        guideMap.tintHex = drawn?.trail.tintHex
        if hikeChanged { applyLibraryLines(on: mapView) }

        guard let drawn else {
            guideMap.line = nil
            if let overlay = guideMap.overlay {
                mapView.removeOverlay(overlay)
                guideMap.overlay = nil
                guideMap.renderer = nil
            }
            return
        }
        let line = Self.guideLine(drawn.line, tintHex: drawn.trail.tintHex)
        guideMap.line = line
        guideMap.renderer?.setLines([line])
        guard guideMap.overlay == nil else { return }
        let overlay = LibraryLinesOverlay()
        guideMap.overlay = overlay
        insertRecordingGuideOverlay(overlay, on: mapView)
    }

    /// The line as the renderer draws it: one polyline for each stretch
    /// walked between pauses, as the selected route is cut.
    static func guideLine(
        _ line: DisplayedRouteCoordinateCache.DrawnRoute,
        tintHex: String
    ) -> LibraryLinesRenderer.Line {
        let polylines = line.runs.walkedRuns.map { run in
            let coordinates = Array(line.coordinates[run])
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }
        // Opaque, as the library's are: the trail's own alpha belongs to its
        // selected line.
        let tint = (Color(hex: tintHex) ?? RouteStyle.defaultTint).opaque
        #if os(macOS)
        let color = NSColor(tint).cgColor
        #else
        let color = UIColor(tint).cgColor
        #endif
        return LibraryLinesRenderer.Line(
            polylines: polylines,
            boundingMapRect: polylines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) },
            color: color
        )
    }

    /// Puts the guide's overlay over the library, the shared hikes' lines and
    /// the open preview's, and under everything else.
    ///
    /// By index, for the reason ``insertLibraryOverlay(_:on:)`` gives: what it
    /// goes above is computed when it goes on, not assumed from what was added
    /// first. Inserted *just* above the topmost of them, so a selected route
    /// already on the map stays over it, and so does the live line.
    private func insertRecordingGuideOverlay(_ overlay: LibraryLinesOverlay, on mapView: MKMapView) {
        let drawn = mapView.overlays(in: .aboveLabels)
        let below: (any MKOverlay)? = communityRoutes.last(where: \.line.isPreviewed)?.polyline
            ?? libraryMap.overlay
            ?? communityRoutes.last?.polyline
            ?? groundOverlay
        let floor = below
            .flatMap { below in drawn.firstIndex { $0 === below } }
            .map { $0 + 1 } ?? 0
        mapView.insertOverlay(overlay, at: floor, level: .aboveLabels)
    }

    /// The renderer for an overlay of the type the library and the guide
    /// share: the guide's, when it is the guide's, and the library's
    /// otherwise.
    func linesRenderer(for overlay: LibraryLinesOverlay) -> LibraryLinesRenderer {
        overlay === guideMap.overlay ? recordingGuideRenderer(for: overlay) : libraryLinesRenderer(for: overlay)
    }

    /// The renderer for the guide's overlay, handed the line drawn now.
    private func recordingGuideRenderer(for overlay: LibraryLinesOverlay) -> LibraryLinesRenderer {
        let renderer = LibraryLinesRenderer(
            overlay: overlay,
            layerAlpha: Self.recordingGuideAlpha,
            lineWidth: Self.recordingGuideWidth,
            borderColor: Self.defaultBorderColor
        )
        renderer.setLines(guideMap.line.map { [$0] } ?? [])
        guideMap.renderer = renderer
        return renderer
    }
}
