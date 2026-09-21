//
//  MapTrailPlaceDrag.swift
//  OpenHikes
//
//  Moving a place that is already marked.
//
//  The same gesture that moves a waypoint — see `MapTrailDraftDrag.swift`,
//  which owns the recognizer, the press duration, the offset and the argument
//  for all three — pointed at a different kind of pin. What it does is much
//  smaller: a place is not on the line, so nothing re-routes, no leg is bent
//  and there is no rubber band. One annotation's `coordinate` follows the
//  finger, MapKit moves its view, and the draft learns where it ended up when
//  the finger lifts.
//
//  **Which is why there is no untracked channel here.** ``TrailDraft/drag``
//  exists because a moving waypoint reshapes two polylines, and a published
//  write per frame would be a body pass per frame for everything that reads
//  the line. A moving place writes nothing at all until it is dropped: the
//  annotation is a reference type MapKit already owns, and assigning its
//  coordinate is the whole of the frame's work.
//
//  A place is found by hit-testing the view rather than by measuring to the
//  coordinate, unlike a waypoint. A waypoint's pin is a dot centred on its
//  point, so the two are the same question; a place's is a balloon whose tip
//  is on the ground and whose body is forty points above it, and a hiker
//  presses the balloon.
//

import CoreLocation
import MapKit
import OpenHikesShared

#if canImport(UIKit)
import UIKit

extension MapView.Coordinator {
    /// Takes hold of whichever place pin is under `point`.
    ///
    /// - Returns: whether there was one. Asked *before* the waypoints in
    ///   ``handleTrailDraftDrag(_:)``, because a place pin is drawn over the
    ///   line and a press that landed on the balloon is a press on the
    ///   balloon.
    @discardableResult func beginTrailPlaceDrag(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard trailDraftController?.isEditing == true,
              let annotation = trailPlace(at: point, in: mapView),
              annotation.isEditable else { return false }
        let pin = mapView.convert(annotation.coordinate, toPointTo: mapView)
        trailPlaceDrag = annotation
        trailDraftDragOffset = CGSize(width: pin.x - point.x, height: pin.y - point.y)
        // Remembered rather than assumed, so a map that was already not
        // scrolling is handed back the way it was found.
        trailDraftDragPausedScrolling = mapView.isScrollEnabled
        mapView.isScrollEnabled = false
        // A callout standing over a pin that is about to move would be drawn
        // somewhere the pin no longer is for the whole gesture.
        mapView.deselectAnnotation(annotation, animated: false)
        HapticMoment.targetHit.play()
        return true
    }

    /// Moves the held place to where the finger is now, keeping the offset the
    /// press began with.
    ///
    /// The annotation is written directly and the draft is not told, which is
    /// the whole of what this costs per frame — see the file header.
    func moveTrailPlaceDrag(to point: CGPoint, in mapView: MKMapView) {
        guard let annotation = trailPlaceDrag else { return }
        let moved = CGPoint(
            x: point.x + trailDraftDragOffset.width,
            y: point.y + trailDraftDragOffset.height
        )
        annotation.coordinate = mapView.convert(moved, toCoordinateFrom: mapView)
    }

    /// Lets go. The drawing changes here and nowhere earlier in the gesture.
    ///
    /// - Returns: whether a place was being held, so the caller knows this
    ///   gesture was not a waypoint's.
    @discardableResult func endTrailPlaceDrag(on mapView: MKMapView) -> Bool {
        guard let annotation = trailPlaceDrag else { return false }
        trailPlaceDrag = nil
        releaseTrailDraftDrag(on: mapView)
        let settled = annotation.coordinate
        // The pin is where the finger left it; the draft is told, and the
        // rebuild that follows replaces this annotation with one built from
        // the committed coordinate. A place that did not travel commits
        // nothing — ``TrailDraft/movePlace(id:to:)`` compares first — so a
        // press held and released is not an edit and does not buzz.
        let before = trailDraftController?.draft.place(id: annotation.place.id)
        trailDraftController?.movePlace(id: annotation.place.id, to: settled)
        let after = trailDraftController?.draft.place(id: annotation.place.id)
        if before != after { HapticMoment.rowMoved.play() }
        return true
    }

    /// Lets go and puts the pin back where the draft still says it is. What a
    /// cancelled gesture comes to.
    @discardableResult func cancelTrailPlaceDrag(on mapView: MKMapView) -> Bool {
        guard let annotation = trailPlaceDrag else { return false }
        trailPlaceDrag = nil
        releaseTrailDraftDrag(on: mapView)
        annotation.coordinate = annotation.place.clCoordinate
        return true
    }

    /// The place pin under `point`, if any.
    ///
    /// Hit-tested rather than measured, for the reason the file header gives.
    /// The walk up the hierarchy is ``isTapClaimed(at:in:)``'s, and for the
    /// same reason: what a touch lands on is a label inside a button inside an
    /// annotation view.
    private func trailPlace(at point: CGPoint, in mapView: MKMapView) -> TrailPlaceAnnotation? {
        var view = mapView.hitTest(point, with: nil)
        while let current = view, current !== mapView {
            if let annotationView = current as? MKAnnotationView {
                return annotationView.annotation as? TrailPlaceAnnotation
            }
            view = current.superview
        }
        return nil
    }
}
#endif
