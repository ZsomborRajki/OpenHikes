//
//  MapTrailDraftSelection.swift
//  OpenHikes
//
//  What a tap on the maker's map opens.
//
//  Every tap opens the place sheet, as it does in Apple Maps: open ground drops
//  a pin, a stop or a place opens its own card, and a grey route is chosen
//  outright. The sheet is a SwiftUI presentation inside the maker's screen, so
//  the map raises ``TrailDraftController/selection`` and the screen presents
//  it — see ``TrailPlaceSheet``.
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
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The pin a tap on open ground drops. There is at most one, and it belongs to
/// the selection rather than to the draft: it goes when the sheet does.
final class TrailDraftDroppedPin: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftDroppedPin"

    @objc dynamic let coordinate: CLLocationCoordinate2D

    /// Both keys, because MapKit reads them by key-value coding once a second
    /// annotation is up — see `MapAnnotationKeyCodingTests`.
    @objc let title: String? = String(localized: "Dropped Pin")
    @objc let subtitle: String? = nil

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

extension MapView.Coordinator {
    /// A tap on the maker's canvas: a grey route is chosen, anything else drops
    /// a pin and opens the sheet on it. Answers whether the maker took the tap.
    ///
    /// A tap that landed on a view is left alone — the map's own controls keep
    /// their claim, and an annotation's tap reaches
    /// ``selectTrailDraftAnnotation(_:on:)`` through MapKit's selection.
    @discardableResult func handleTrailDraftTap(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let controller = trailDraftController, controller.isEditing else { return false }
        guard !isTapClaimed(at: point, in: mapView) else { return false }
        if let alternative = trailDraftAlternative(at: point, in: mapView) {
            controller.chooseRoute(alternative.alternativeIndex, forLegAt: alternative.legIndex)
        } else {
            // The leg is asked on the glass, while the tap is still a tap —
            // see ``TrailDraftDroppedPinSpot``.
            controller.select(.droppedPin(TrailDraftDroppedPinSpot(
                coordinate: mapView.convert(point, toCoordinateFrom: mapView),
                legIndex: trailDraftLegIndex(at: point, in: mapView)
            )))
        }
        HapticMoment.targetHit.play()
        return true
    }

    /// A tap on one of the maker's own annotations. Answers whether it was one.
    func selectTrailDraftAnnotation(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        guard let controller = trailDraftController, controller.isEditing,
              let annotation = view.annotation else { return false }
        switch annotation {
        case let stop as TrailDraftWaypointAnnotation:
            controller.select(.stop(stop.waypointID))
        case let place as TrailPlaceAnnotation where place.belongsToDraft:
            controller.select(.place(place.place.id))
        case let time as TrailDraftTravelTimeAnnotation:
            guard let alternative = time.alternativeIndex else { break }
            controller.chooseRoute(alternative, forLegAt: time.legIndex)
        case is TrailDraftDroppedPin:
            break
        default:
            return false
        }
        mapView.deselectAnnotation(annotation, animated: false)
        HapticMoment.targetHit.play()
        return true
    }

    /// Puts the dropped pin where the selection says, or takes it away.
    func applyTrailDraftSelection(_ selection: TrailDraftSelection?, on mapView: MKMapView) {
        let spot: TrailDraftDroppedPinSpot? = if case .droppedPin(let spot) = selection { spot } else { nil }
        if let pin = trailDraftDroppedPin, let spot,
           pin.coordinate.latitude == spot.latitude, pin.coordinate.longitude == spot.longitude {
            return
        }
        if let pin = trailDraftDroppedPin {
            trailDraftDroppedPin = nil
            mapView.removeAnnotation(pin)
        }
        guard let spot else { return }
        let pin = TrailDraftDroppedPin(coordinate: spot.clCoordinate)
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
        let identifier = TrailDraftDroppedPin.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
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
