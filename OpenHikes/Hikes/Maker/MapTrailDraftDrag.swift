//
//  MapTrailDraftDrag.swift
//  OpenHikes
//
//  Moving a point that is already down.
//
//  The one edit that can only happen on the map. Deleting, reordering and
//  reversing are all things a list can express; *this point should be forty
//  metres further up the spur* is a place on the ground, and the only honest
//  way to say it is to put a finger on the pin and move it.
//
//  ## Our own recognizer rather than `MKAnnotationView.isDraggable`
//
//  MapKit's own dragging moves the view and reports two states — it started,
//  and it finished. Nothing arrives in between, so the two legs either side of
//  the point would stay where they were for the whole gesture and jump when
//  the finger lifted. What a hiker is actually aiming at while dragging is the
//  *line*, not the dot, so a drag that does not move the line is a drag done
//  blind.
//
//  It also keeps the two gestures independent of the tap rules, which changed
//  under it in Phase 4: a waypoint pin now *is* selectable and does show a
//  callout — see ``MapView/Coordinator/isTapClaimed(at:in:)``. Nothing here
//  had to move for that, because none of this is anything the annotation view
//  does with a touch.
//
//  ## Two kinds of pin, one recognizer
//
//  Since Phase 4 a marked place can be moved the same way, and it is the same
//  press — asked about first, because a place's balloon is drawn over the
//  line. What it costs is much less, and `MapTrailPlaceDrag.swift` says why.
//
//  ## What the gesture does to the map underneath it
//
//  A long press that lands on a pin turns the map's own scrolling off for as
//  long as the finger is down, and back on afterwards. That is the reliable
//  half of the arrangement: `shouldRecognizeSimultaneouslyWith` is a request
//  rather than a rule — MapKit's own pan recognizer has its own delegate, and
//  a "no" from ours does not bind it — so a drag that relied on it would
//  sometimes drag the point and pan the map at the same time.
//
//  A press that lands anywhere else never begins, because
//  ``MapView/Coordinator/gestureRecognizerShouldBegin(_:)`` refuses it. So
//  panning, zooming and the tap that puts a point down are all exactly what
//  they were, and nothing about this gesture is felt unless a pin is under it.
//
//  ## The offset, and why the pin does not jump
//
//  A thumb 6 points off a pin's centre would otherwise move the pin 6 points
//  the moment the drag began. The distance between the touch and the pin is
//  taken once, when the press is recognized, and carried for the rest of the
//  gesture — so the point travels exactly as far as the finger does.
//

import CoreLocation
import MapKit
import OpenHikesShared

#if canImport(UIKit)
import UIKit

extension MapView.Coordinator {
    /// How long a finger has to be still on a pin before it takes hold of it.
    ///
    /// Shorter than the system's default half-second, because this is not a
    /// menu press: the hiker has already decided to move the point and is
    /// waiting to be allowed to. Long enough that a pan started with a thumb
    /// that happens to begin over a pin is still a pan — a pan moves further
    /// than ``waypointGrabAllowableMovement`` well inside it.
    static let waypointGrabPressDuration: TimeInterval = 0.25

    /// How far the finger may drift before the press is abandoned as a pan.
    static let waypointGrabAllowableMovement: CGFloat = 10

    /// Adds the recognizer that moves a waypoint.
    ///
    /// Idempotent, like ``installRouteTap(on:)`` and for the same reason: a
    /// second recognizer would take hold of the same pin twice and answer the
    /// gesture with two drags.
    func installTrailDraftDrag(on mapView: MKMapView) {
        guard trailDraftDragRecognizer == nil else { return }
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleTrailDraftDrag(_:))
        )
        recognizer.minimumPressDuration = Self.waypointGrabPressDuration
        recognizer.allowableMovement = Self.waypointGrabAllowableMovement
        // The same delegate the route tap uses, which is what
        // `gestureRecognizerShouldBegin` discriminates on: this one begins
        // only over a pin, and that one begins over anything.
        recognizer.delegate = self
        trailDraftDragRecognizer = recognizer
        mapView.addGestureRecognizer(recognizer)
    }

    @objc func handleTrailDraftDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        switch recognizer.state {
        // A place pin is asked about first, because it is drawn over the line
        // and a press that landed on the balloon is a press on the balloon.
        // Each of the four below answers whether a place was the thing being
        // held, and the waypoint half is asked only when none was.
        case .began:
            if !beginTrailPlaceDrag(at: point, in: mapView) {
                beginTrailDraftDrag(at: point, in: mapView)
            }
        case .changed:
            if trailPlaceDrag != nil {
                moveTrailPlaceDrag(to: point, in: mapView)
            } else {
                moveTrailDraftDrag(to: point, in: mapView)
            }
        case .ended:
            if !endTrailPlaceDrag(on: mapView) { endTrailDraftDrag(on: mapView) }
        // A cancelled gesture is not a small edit: the finger was taken away
        // by something that is not the hiker — a call, a system gesture — so
        // the point goes back where it was.
        case .cancelled, .failed:
            if !cancelTrailPlaceDrag(on: mapView) { cancelTrailDraftDrag(on: mapView) }
        case .possible: break
        @unknown default:
            if !cancelTrailPlaceDrag(on: mapView) { cancelTrailDraftDrag(on: mapView) }
        }
    }

    /// Takes hold of whichever point is under `point`.
    ///
    /// - Returns: whether one was. Split from the handler above for the reason
    ///   ``addTrailDraftWaypoint(at:in:)`` is: a recognizer's state and
    ///   location are set by the touch system and cannot be driven by a suite,
    ///   so the half worth asserting on has to be reachable without one.
    @discardableResult func beginTrailDraftDrag(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let controller = trailDraftController,
              let index = trailDraftWaypointIndex(at: point, in: mapView),
              controller.beginDrag(ofWaypointAt: index) else { return false }
        let pin = mapView.convert(trailDraftCoordinates[index], toPointTo: mapView)
        trailDraftDragOffset = CGSize(width: pin.x - point.x, height: pin.y - point.y)
        // The map stops moving under the point for as long as the point is
        // moving over the map. Remembered rather than assumed, so a map that
        // was already not scrolling is handed back the way it was found.
        trailDraftDragPausedScrolling = mapView.isScrollEnabled
        mapView.isScrollEnabled = false
        // The same moment the drawn line answers a tap with: something that
        // could have been missed, and was not.
        HapticMoment.targetHit.play()
        return true
    }

    /// Moves the held point to where the finger is now, keeping the offset the
    /// press began with.
    func moveTrailDraftDrag(to point: CGPoint, in mapView: MKMapView) {
        guard let controller = trailDraftController,
              controller.draft.drag != nil else { return }
        let moved = CGPoint(
            x: point.x + trailDraftDragOffset.width,
            y: point.y + trailDraftDragOffset.height
        )
        controller.dragWaypoint(to: mapView.convert(moved, toCoordinateFrom: mapView))
    }

    /// Lets go. The drawing changes here and nowhere earlier in the gesture.
    func endTrailDraftDrag(on mapView: MKMapView) {
        let moved = trailDraftController?.endDrag() == true
        releaseTrailDraftDrag(on: mapView)
        // Only a point that actually went somewhere. A press held on a pin and
        // released without travelling is not an edit, and answering it would
        // buzz for nothing.
        if moved { HapticMoment.rowMoved.play() }
    }

    func cancelTrailDraftDrag(on mapView: MKMapView) {
        trailDraftController?.cancelDrag()
        releaseTrailDraftDrag(on: mapView)
    }

    /// Which waypoint is under `point`, if any.
    ///
    /// Measured against the pins the map is currently drawing rather than
    /// against the draft, which is the same list one observation pass later —
    /// and the pins are what the hiker aimed at. The nearest within a
    /// fingertip wins, so two points close together at a zoomed-out camera
    /// resolve to the one actually pressed rather than to the first in the
    /// list.
    ///
    /// The tolerance is ``lineTapTolerancePoints``, deliberately the same
    /// number the lines use: it is a number about thumbs rather than about
    /// what happens to be under one.
    func trailDraftWaypointIndex(at point: CGPoint, in mapView: MKMapView) -> Int? {
        guard trailDraftController?.isEditing == true,
              !trailDraftCoordinates.isEmpty else { return nil }
        let tolerance = Self.lineTapTolerancePoints
        var best: Int?
        var bestDistance = tolerance
        for (index, coordinate) in trailDraftCoordinates.enumerated() {
            let pin = mapView.convert(coordinate, toPointTo: mapView)
            let distance = hypot(point.x - pin.x, point.y - pin.y)
            guard distance <= bestDistance, best == nil || distance < bestDistance else { continue }
            best = index
            bestDistance = distance
        }
        return best
    }

    /// Hands the map back its own gestures, whichever way the drag ended.
    ///
    /// Shared with the place drag, which pauses scrolling the same way and has
    /// the same one thing to undo — see `MapTrailPlaceDrag.swift`.
    func releaseTrailDraftDrag(on mapView: MKMapView) {
        guard trailDraftDragPausedScrolling else { return }
        trailDraftDragPausedScrolling = false
        mapView.isScrollEnabled = true
    }
}
#endif
