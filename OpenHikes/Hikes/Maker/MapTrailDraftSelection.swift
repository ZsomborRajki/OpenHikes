//
//  MapTrailDraftSelection.swift
//  OpenHikes
//
//  What a touch on the maker's map opens.
//
//  As in Apple Maps: **a press and hold drops a pin** and opens its card; a
//  *tap* opens the card of whatever it lands on — a stop, one of the trail's
//  places, one of the map's own labels — chooses a grey route, and on open
//  ground closes the card that is up. The dropped pin stays on the map when its
//  card closes, until *Remove Pin*, *Add Stop* or another press — see
//  ``TrailDraftController/droppedPin``. The card is a SwiftUI presentation
//  inside the maker's screen, so the map raises
//  ``TrailDraftController/selection`` and the screen presents it — see
//  ``TrailPlaceSheet``.
//
//  ## No callouts, and so no callout race
//
//  Phase 4 asked through MapKit's own callout, and MapKit closes a callout it
//  did not open itself 150–500 ms after this app's tap; a budgeted reopen
//  existed only to open it again. A sheet is not MapKit's to close, so the
//  race went with the callout. The maker's annotations show no callout and are
//  deselected the moment they are selected: a selection is only how a tap on
//  an annotation view reaches here, and one left standing would swallow the
//  next tap on the same pin.
//

import MapKit
import OpenHikesData
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The pin a press and hold drops. There is at most one, and it belongs to the
/// controller rather than to the draft — see
/// ``TrailDraftController/droppedPin``.
final class TrailDraftDroppedPin: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftDroppedPin"

    @objc dynamic let coordinate: CLLocationCoordinate2D

    /// What the place under the pin is called, for a pin dropped on one of the
    /// map's own labels, or empty for open map — see
    /// `MapTrailDraftFeatures.swift`.
    let placeName: String

    /// Both keys, because MapKit reads them by key-value coding once a second
    /// annotation is up — see `MapAnnotationKeyCodingTests`. The place's name,
    /// or *Dropped Pin* for a spot that has none — Apple Maps' own heading for
    /// both.
    @objc let title: String?
    @objc let subtitle: String? = nil

    init(coordinate: CLLocationCoordinate2D, placeName: String = "") {
        self.coordinate = coordinate
        self.placeName = placeName
        title = placeName.isEmpty ? String(localized: "Dropped Pin") : placeName
    }
}

extension MapView.Coordinator {
    /// A tap on the maker's canvas: a grey route is chosen, and anything else
    /// closes the card that is up — the dropped pin, if there is one, stays.
    /// Answers whether the maker took the tap.
    ///
    /// A tap that landed on a view is left alone — the map's own controls keep
    /// their claim, and an annotation's tap reaches
    /// ``selectTrailDraftAnnotation(_:on:)`` through MapKit's selection.
    @discardableResult func handleTrailDraftTap(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let controller = trailDraftController, controller.isEditing else { return false }
        guard !isTapClaimed(at: point, in: mapView) else { return false }
        if let alternative = trailDraftAlternative(at: point, in: mapView) {
            controller.chooseRoute(alternative.alternativeIndex, forLegAt: alternative.legIndex)
            HapticMoment.targetHit.play()
        } else if isNamedTrailDraftPin(near: point, in: mapView) {
            // The label under this touch was selected first and opened its
            // card — see `MapTrailDraftFeatures.swift`. Closing it again would
            // answer one tap twice.
        } else {
            controller.select(nil)
        }
        return true
    }

    /// A press and hold on the maker's canvas: drops the pin there and opens
    /// its card. Answers whether it did.
    ///
    /// Split from the recognizer for the reason the drag is: a recognizer's
    /// state cannot be driven by a suite, and this is the half worth asserting
    /// on. The leg under the press is asked on the glass, while the press is
    /// still where the thumb is — see ``TrailDraftDroppedPinSpot``.
    @discardableResult func dropTrailDraftPin(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let controller = trailDraftController, controller.isEditing else { return false }
        let leg = trailDraftLegIndex(at: point, in: mapView).flatMap { index in
            trailDraftLegs.indices.contains(index) ? trailDraftLegs[index].ends : nil
        }
        controller.dropPin(TrailDraftDroppedPinSpot(
            coordinate: mapView.convert(point, toCoordinateFrom: mapView),
            leg: leg
        ))
        HapticMoment.pinDropped.play()
        return true
    }

    /// A tap on one of the maker's own annotations, or on one of the map's own
    /// labels while drawing. Answers whether it was one.
    func selectTrailDraftAnnotation(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        // A label becomes the maker's dropped pin — see
        // `MapTrailDraftFeatures.swift`.
        if selectTrailDraftFeature(view.annotation, on: mapView) { return true }
        guard let controller = trailDraftController, controller.isEditing,
              let annotation = view.annotation else { return false }
        switch annotation {
        case let stop as TrailDraftWaypointAnnotation:
            controller.select(.stop(stop.waypointID))
        case let place as TrailPlaceAnnotation where place.belongsToDraft:
            controller.select(.place(place.place.id))
        case let time as TrailDraftTravelTimeAnnotation:
            guard let choice = time.choice else { break }
            controller.chooseRoute(choice.alternativeIndex, forLegAt: choice.legIndex)
        case is TrailDraftDroppedPin:
            // Its card again, which closing left the pin standing without.
            controller.select(.droppedPin)
        default:
            return false
        }
        mapView.deselectAnnotation(annotation, animated: false)
        HapticMoment.targetHit.play()
        return true
    }

    /// Puts the dropped pin where the controller says, or takes it away.
    func applyTrailDraftDroppedPin(_ spot: TrailDraftDroppedPinSpot?, on mapView: MKMapView) {
        if let pin = trailDraftDroppedPin, let spot,
           pin.coordinate.latitude == spot.latitude, pin.coordinate.longitude == spot.longitude,
           pin.placeName == spot.name {
            return
        }
        if let pin = trailDraftDroppedPin {
            trailDraftDroppedPin = nil
            mapView.removeAnnotation(pin)
        }
        guard let spot else { return }
        let pin = TrailDraftDroppedPin(coordinate: spot.clCoordinate, placeName: spot.name)
        trailDraftDroppedPin = pin
        mapView.addAnnotation(pin)
    }

    /// The view for any of the maker's kinds, or `nil` for anything else.
    ///
    /// One question for `mapView(_:viewFor:)` to ask, so the delegate method
    /// does not grow a branch per kind.
    func makerAnnotationView(
        for annotation: any MKAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView? {
        switch annotation {
        case let waypoint as TrailDraftWaypointAnnotation:
            trailDraftAnnotationView(for: waypoint, on: mapView)
        case let place as TrailPlaceAnnotation:
            trailPlaceAnnotationView(for: place, on: mapView)
        case let time as TrailDraftTravelTimeAnnotation:
            trailDraftTravelTimeView(for: time, on: mapView)
        case let dropped as TrailDraftDroppedPin:
            trailDraftDroppedPinView(for: dropped, on: mapView)
        default:
            nil
        }
    }

    private func trailDraftDroppedPinView(
        for annotation: TrailDraftDroppedPin,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let view = mapView.reusableView(
            MKMarkerAnnotationView.self,
            for: annotation,
            reuseIdentifier: TrailDraftDroppedPin.reuseIdentifier
        )
        view.canShowCallout = false
        view.animatesWhenAdded = true
        #if os(iOS)
        view.markerTintColor = .systemRed
        #endif
        // A pin the hiker put there a moment ago. Letting MapKit declutter it
        // away would be the map answering a tap with nothing.
        view.displayPriority = .required
        view.accessibilityIdentifier = "trail-draft-dropped-pin"
        return view
    }
}

#if canImport(UIKit)
/// The press that drops a pin. Its own class so the map's delegate can tell it
/// from the press that drags a stop — and so the map can tell it has one —
/// with no stored property on the coordinator to hold it by.
final class TrailDraftPinDropRecognizer: UILongPressGestureRecognizer {}

extension MapView.Coordinator {
    /// How long a finger has to rest on open map before it drops a pin — the
    /// system's own long press, which is also what Apple Maps waits for.
    ///
    /// Longer than ``waypointGrabPressDuration`` on purpose: that one takes
    /// hold of a pin already there, and begins only over one; this begins only
    /// where there is none. The two never compete for the same touch.
    static let pinDropPressDuration: TimeInterval = 0.5

    /// Adds the press that drops a pin. Idempotent, like the other recognizers
    /// here: a second would drop two pins for one press.
    func installTrailDraftPinDrop(on mapView: MKMapView) {
        let installed = mapView.gestureRecognizers ?? []
        guard !installed.contains(where: { $0 is TrailDraftPinDropRecognizer }) else { return }
        let recognizer = TrailDraftPinDropRecognizer(
            target: self,
            action: #selector(handleTrailDraftPinDrop(_:))
        )
        recognizer.minimumPressDuration = Self.pinDropPressDuration
        // The same delegate the tap and the drag use, which is what decides
        // where each may begin — see `gestureRecognizerShouldBegin(_:)`.
        recognizer.delegate = self
        mapView.addGestureRecognizer(recognizer)
    }

    @objc func handleTrailDraftPinDrop(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        // Outside the maker the same press is *Places Around Trail*'s: a place
        // of the hiker's own, wherever they held — see ``TrailPlacesAround``.
        guard trailDraftController?.isEditing == true else {
            if placesAroundMap.around?.dropPin(at: mapView.convert(point, toCoordinateFrom: mapView)) == true {
                HapticMoment.pinDropped.play()
            }
            return
        }
        dropTrailDraftPin(at: point, in: mapView)
    }

    /// Whether a press at `point` may drop a pin: only while drawing or while
    /// *Places Around Trail* is up, never on one of the maker's stops — that
    /// press moves the stop — and never on a view that has its own claim, a
    /// control or another pin.
    func mayDropTrailDraftPin(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard trailDraftController?.isEditing == true || placesAroundMap.around?.isActive == true else { return false }
        return trailDraftWaypointIndex(at: point, in: mapView) == nil
            && !isTapClaimed(at: point, in: mapView)
    }
}
#endif
